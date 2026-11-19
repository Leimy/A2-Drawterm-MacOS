MODULE DarwinActivityTreeProbe;
IMPORT Commands, Kernel, ConcurrentSieve, Trees := DarwinActivityTrees;
TYPE
	Sieve = OBJECT
	VAR context: Commands.Context;
		PROCEDURE Run;
		BEGIN ConcurrentSieve.Run(context) END Run;
	END Sieve;
	Gate = OBJECT
	VAR waiting, cleaned: BOOLEAN;
		PROCEDURE Wait;
		BEGIN {EXCLUSIVE} waiting := TRUE; AWAIT(~waiting)
		FINALLY cleaned := TRUE
		END Wait;
		PROCEDURE Ready;
		BEGIN {EXCLUSIVE} AWAIT(waiting) END Ready;
	END Gate;
	Waiter = OBJECT
	VAR gate: Gate;
		PROCEDURE &Init(g: Gate); BEGIN gate := g END Init;
	BEGIN {ACTIVE} gate.Wait
	END Waiter;
	Crash = OBJECT
	VAR gate: Gate;
		PROCEDURE Run;
		VAR w: Waiter;
		BEGIN NEW(w, gate); gate.Ready; Kernel.GC; HALT(99) END Run;
	END Crash;

PROCEDURE Cancel*(context: Commands.Context);
VAR c: Crash; used: SIZE;
BEGIN
	NEW(c); NEW(c.gate); ASSERT(~Trees.Run(c.Run, 2, used));
	ASSERT(c.gate.cleaned & (used = 2));
	context.out.String("PASS cross-worker cancellation"); context.out.Ln
END Cancel;

PROCEDURE Run*(context: Commands.Context);
VAR n: SIGNED32; used: SIZE; sieve: Sieve;
BEGIN
	context.arg.Int(n, FALSE); NEW(sieve); sieve.context := context;
	ASSERT(Trees.Run(sieve.Run, n, used));
	context.out.String("Sieve workers used: "); context.out.Int(used,0); context.out.Ln;
END Run;
END DarwinActivityTreeProbe.
