MODULE NativeReleaseSoak;
IMPORT Commands, Heaps, Kernel, KernelLog;
TYPE
	Node = OBJECT
	VAR next: Node; value: SIGNED32; bytes: POINTER TO ARRAY OF CHAR;
	END Node;
	Group = OBJECT
	VAR count, sum: SIGNED32;
		PROCEDURE Done(id: SIGNED32);
		BEGIN {EXCLUSIVE} INC(count); INC(sum, id) END Done;
		PROCEDURE Wait;
		BEGIN {EXCLUSIVE} AWAIT(count = 8); ASSERT(sum = 36) END Wait;
	END Group;
	Worker = OBJECT
	VAR group: Group; id: SIGNED32; head, node: Node; i: SIGNED32;
		PROCEDURE &Init(owner: Group; number: SIGNED32);
		BEGIN group := owner; id := number END Init;
	BEGIN {ACTIVE}
		FOR i := 0 TO 511 DO
			NEW(node); node.next := head; node.value := id * 512 + i;
			NEW(node.bytes, 64); node.bytes[0] := CHR(id); node.bytes[63] := CHR(i MOD 256); head := node
		END;
		i := 511;
		WHILE head # NIL DO
			ASSERT(head.value = id * 512 + i);
			ASSERT((head.bytes[0] = CHR(id)) & (head.bytes[63] = CHR(i MOD 256)));
			head := head.next; DEC(i)
		END;
		ASSERT(i = -1); group.Done(id)
	END Worker;

PROCEDURE Run*(context: Commands.Context);
VAR seconds, started, rounds, i: SIGNED32; group: Group; worker: Worker;
BEGIN
	seconds := 60;
	IF context.arg.GetInteger(seconds, FALSE) THEN END;
	ASSERT((seconds >= 1) & (seconds <= 3600));
	started := Kernel.GetTicks(); rounds := 0;
	REPEAT
		NEW(group);
		FOR i := 1 TO 8 DO NEW(worker, group, i) END;
		Heaps.InvokeGC; group.Wait; Heaps.InvokeGC; INC(rounds)
	UNTIL Kernel.GetTicks() - started >= seconds * 1000;
	KernelLog.String("SOAK PASS concurrent allocation and GC: rounds="); KernelLog.Int(rounds, 0);
	KernelLog.String(" workers="); KernelLog.Int(rounds * 8, 0); KernelLog.Ln
END Run;
END NativeReleaseSoak.
