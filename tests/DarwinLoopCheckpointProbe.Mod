MODULE DarwinLoopCheckpointProbe;
IMPORT A := DarwinActivities, Commands, Objects, Kernel;

CONST Limit = 3 * A.CheckpointInterval;
TYPE
	Compute = OBJECT
	VAR kind, steps, i: SIZE;
	BEGIN {ACTIVE}
		CASE kind OF
		| 0: WHILE steps < Limit DO INC(steps) END
		| 1: REPEAT INC(steps) UNTIL steps = Limit
		| 2: FOR i := 1 TO Limit DO INC(steps) END
		| 3: LOOP INC(steps); IF steps = Limit THEN EXIT END END
		| 4: BEGIN {EXCLUSIVE} WHILE steps < Limit DO INC(steps) END END
		| 5: BEGIN {UNCOOPERATIVE} WHILE steps < Limit DO INC(steps) END END;
			WHILE steps < 2 * Limit DO INC(steps) END
		END
	END Compute;

PROCEDURE Check(enabled: BOOLEAN);
VAR s: A.Scheduler; a, b: Compute; kind, firstTurn, total: SIZE;
BEGIN
	NEW(s);
	FOR kind := 0 TO 5 DO
		total := Limit; firstTurn := A.CheckpointInterval;
		IF kind = 5 THEN total := 2 * Limit; firstTurn := Limit + A.CheckpointInterval END;
		s.NextActive; NEW(a); a.kind := kind;
		s.NextActive; NEW(b); b.kind := kind;
		ASSERT(s.Dispatch());
		IF enabled & (kind # 4) THEN
			ASSERT((a.steps = firstTurn) & (b.steps = 0));
			ASSERT(s.Dispatch()); ASSERT(b.steps = a.steps)
		ELSE ASSERT((a.steps = total) & (b.steps = 0)) END;
		WHILE s.Dispatch() DO END;
		ASSERT((a.steps = total) & (b.steps = total) & (s.live = 0))
	END;
	s.Close
END Check;

TYPE
	Gate = OBJECT
	VAR posted: BOOLEAN;
		PROCEDURE Wait;
		BEGIN {EXCLUSIVE} AWAIT(posted) END Wait;
		PROCEDURE Post;
		BEGIN {EXCLUSIVE} posted := TRUE END Post;
	END Gate;

	Waiting = OBJECT
	VAR gate: Gate; woke: BOOLEAN;
	BEGIN {ACTIVE}
		IF gate = NIL THEN Objects.Sleep(20) ELSE gate.Wait END;
		woke := TRUE
	END Waiting;

	Busy = OBJECT
	VAR peer: Waiting; start: SIGNED32; sawWake: BOOLEAN;
	BEGIN {ACTIVE}
		IF peer.gate # NIL THEN peer.gate.Post END;
		start := Kernel.GetTicks();
		WHILE ~peer.woke & (Kernel.GetTicks() - start < 2000) DO END;
		sawWake := peer.woke
	END Busy;

PROCEDURE CheckExternalWake(timer: BOOLEAN);
VAR s: A.Scheduler; peer: Waiting; busy: Busy;
BEGIN
	NEW(s); s.NextActive; NEW(peer);
	IF ~timer THEN NEW(peer.gate) END;
	s.NextActive; NEW(busy); busy.peer := peer;
	ASSERT(s.Dispatch()); ASSERT(~peer.woke);
	s.Drain; s.Close; ASSERT(busy.sawWake)
END CheckExternalWake;

PROCEDURE Run*(context: Commands.Context);
BEGIN Check(TRUE); CheckExternalWake(TRUE); CheckExternalWake(FALSE);
	context.out.String("PASS sleeping and notified peers wake during a busy checkpointed loop on one worker"); context.out.Ln;
	context.out.String("PASS compiler checkpoints in WHILE, REPEAT, FOR and LOOP; EXCLUSIVE and UNCOOPERATIVE respected"); context.out.Ln END Run;

PROCEDURE Control*(context: Commands.Context);
BEGIN Check(FALSE); context.out.String("PASS default compilation leaves loops uninterrupted"); context.out.Ln END Control;
END DarwinLoopCheckpointProbe.
