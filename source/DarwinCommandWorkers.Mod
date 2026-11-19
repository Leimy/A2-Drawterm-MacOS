MODULE DarwinCommandWorkers;
(** Isolated headless runtime. ActivityCommands lists command:monitor entries
    separated by commas. A dash means the command needs no bound module.
    Commands sharing a configured module are serialized by the queue.
    Its monitor remains available to other native clients. *)
IMPORT A := DarwinActivities, Commands, Modules, Machine, Objects;

TYPE
	Job = OBJECT(A.Activity)
	VAR nextJob: Job; monitor: Modules.Module; context: Commands.Context;
		proc: PROCEDURE(context: Commands.Context); finished, returned: BOOLEAN; scheduler: A.Scheduler;
		PROCEDURE Run*;
		BEGIN
			Objects.SetContext(context); proc(context); context.out.Update; context.error.Update; returned := TRUE
		FINALLY
			IF ~returned THEN scheduler.Fail; context.result := Commands.CommandTrapped END
		END Run;
		PROCEDURE Complete;
		BEGIN {EXCLUSIVE} finished := TRUE END Complete;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(finished) END Join;
	END Job;

	Queue = OBJECT
	VAR first, last: Job; slots: POINTER TO ARRAY OF RECORD used: BOOLEAN; monitor: Modules.Module; inbox: Job END;
		idle: SIZE; (* -1, or the one warm worker waiting for an assignment *)
		PROCEDURE Eligible(): Job;
		VAR j: Job; i: SIZE;
		BEGIN
			j := first;
			WHILE j # NIL DO
				IF j.monitor = NIL THEN RETURN j END;
				i := 0;
				WHILE (i < LEN(slots)) & (slots[i].monitor # j.monitor) DO INC(i) END;
				IF i = LEN(slots) THEN RETURN j END;
				j := j.nextJob
			END;
			RETURN NIL
		END Eligible;
		PROCEDURE Assign(id: SIZE; j: Job);
		VAR prev: Job;
		BEGIN
			IF first = j THEN first := j.nextJob
			ELSE prev := first; WHILE prev.nextJob # j DO prev := prev.nextJob END; prev.nextJob := j.nextJob END;
			IF last = j THEN last := prev END;
			j.nextJob := NIL; slots[id].monitor := j.monitor; slots[id].inbox := j
		END Assign;

		PROCEDURE Put(j: Job);
		VAR id: SIZE; w: Worker; p: Objects.Process; children, one: Objects.ActivityStart; shared: Objects.SharedStart;
		BEGIN {EXCLUSIVE}
			IF last = NIL THEN first := j ELSE last.nextJob := j END; last := j;
			j := Eligible(); IF j = NIL THEN RETURN END;
			IF idle >= 0 THEN id := idle; idle := -1; Assign(id, j)
			ELSE
				id := 0; WHILE (id < LEN(slots)) & slots[id].used DO INC(id) END;
				IF id < LEN(slots) THEN
					slots[id].used := TRUE; Assign(id, j);
					(* Async submissions can arrive from inside a lightweight tree. *)
					p := Objects.CurrentProcess(); children := p.childActivity; one := p.nextActivity;
					shared := p.sharedChild; p.sharedChild := NIL; p.childActivity := NIL; p.nextActivity := NIL; NEW(w, id, SELF);
					p.sharedChild := shared; p.childActivity := children; p.nextActivity := one
				END
			END
		END Put;

		PROCEDURE Size(): SIZE;
		VAR i, n: SIZE;
		BEGIN {EXCLUSIVE}
			n := 0; FOR i := 0 TO LEN(slots)-1 DO IF slots[i].used THEN INC(n) END END; RETURN n
		END Size;

		PROCEDURE Take(id: SIZE): Job;
		VAR j: Job;
		BEGIN {EXCLUSIVE}
			IF slots[id].inbox = NIL THEN
				slots[id].monitor := NIL; j := Eligible();
				IF j # NIL THEN Assign(id, j)
				ELSIF idle >= 0 THEN slots[id].used := FALSE; RETURN NIL
				ELSE idle := id; AWAIT(slots[id].inbox # NIL) END
			END;
			j := slots[id].inbox; slots[id].inbox := NIL; RETURN j
		END Take;
	END Queue;

	Worker = OBJECT
	VAR id: SIZE; queue: Queue;
		PROCEDURE &Init(id: SIZE; queue: Queue);
		BEGIN SELF.id := id; SELF.queue := queue END Init;
	VAR j: Job; s: A.Scheduler;
	BEGIN {ACTIVE}
		LOOP
			j := queue.Take(id); IF j = NIL THEN EXIT END; NEW(s); j.scheduler := s;
			s.StartTree(j);
			s.Drain;
			ASSERT(s.live = 0); s.Close;
			IF s.failed THEN j.context.result := Commands.CommandTrapped END;
			j.scheduler := NIL; j.Complete; j := NIL
		END
	END Worker;

VAR queue: Queue; routes: ARRAY 1024 OF CHAR; count: SIGNED32;

PROCEDURE Lookup(CONST cmd: ARRAY OF CHAR; VAR monitor: Modules.Name): BOOLEAN;
VAR i, k: SIZE;
BEGIN
	i := 0;
	WHILE routes[i] # 0X DO
		k := 0; WHILE (cmd[k] # 0X) & (routes[i] = cmd[k]) DO INC(i); INC(k) END;
		IF (cmd[k] = 0X) & (routes[i] = ":") THEN
			INC(i); k := 0;
			WHILE (routes[i] # 0X) & (routes[i] # ",") DO
				IF k >= LEN(monitor)-1 THEN RETURN FALSE END;
				monitor[k] := routes[i]; INC(k); INC(i)
			END;
			monitor[k] := 0X; RETURN k > 0
		END;
		WHILE (routes[i] # 0X) & (routes[i] # ",") DO INC(i) END;
		IF routes[i] = "," THEN INC(i) END
	END;
	RETURN FALSE
END Lookup;

PROCEDURE Start;
BEGIN {EXCLUSIVE}
	IF queue = NIL THEN
		NEW(queue); NEW(queue.slots, count); queue.idle := -1
	END
END Start;

PROCEDURE PoolSize*(): SIZE;
BEGIN IF count <= 0 THEN RETURN 0 END; Start; RETURN queue.Size() END PoolSize;

PROCEDURE Route*(CONST cmd: ARRAY OF CHAR; context: Commands.Context; flags: SET; VAR res: INTEGER; VAR msg: ARRAY OF CHAR): BOOLEAN;
VAR j: Job; mod, name, monitor: Modules.Name; m: Modules.Module;
BEGIN
	IF ~Lookup(cmd, monitor) THEN RETURN FALSE END;
	res := Commands.CommandError;
	IF count <= 0 THEN COPY("ActivityWorkers must be a decimal integer from 1 to 64", msg); RETURN TRUE END;
	IF (Objects.CurrentProcess().checkpointDue # NIL) & (Commands.Wait IN flags) THEN
		COPY("Nested synchronous worker command unsupported", msg); RETURN TRUE
	END;
	Commands.Split(cmd, mod, name, res, msg); IF res # 0 THEN RETURN TRUE END;
	m := Modules.ThisModule(mod, res, msg); IF m = NIL THEN RETURN TRUE END;
	NEW(j); GETPROCEDURE(mod, name, j.proc);
	IF j.proc = NIL THEN res := Commands.CommandNotFound; COPY("Worker command must take a Commands.Context", msg); RETURN TRUE END;
	IF monitor # "-" THEN
		j.monitor := Modules.ThisModule(monitor, res, msg); IF j.monitor = NIL THEN RETURN TRUE END
	END;
	IF context = NIL THEN NEW(context, NIL, NIL, NIL, NIL, NIL) END; j.context := context;
	Start; queue.Put(j); res := Commands.Ok; msg := "";
	IF Commands.Wait IN flags THEN
		j.Join; res := context.result; IF res = Commands.CommandTrapped THEN COPY("Exception during command execution", msg)
		ELSIF res # 0 THEN COPY("Command not successful", msg) END
	END;
	RETURN TRUE
END Route;

VAR n: ARRAY 16 OF CHAR; pos: SIZE;
BEGIN
	Machine.GetConfig("ActivityCommands", routes); Machine.GetConfig("ActivityWorkers", n);
	pos := 0; count := 0;
	WHILE (n[pos] >= "0") & (n[pos] <= "9") & (count <= 64) DO
		count := count*10 + ORD(n[pos])-ORD("0"); INC(pos)
	END;
	IF (n[pos] # 0X) OR (count > 64) THEN count := 0 END;
	Commands.workerRoute := Route
END DarwinCommandWorkers.
