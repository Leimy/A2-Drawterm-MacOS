MODULE DarwinLoopCheckpointProbe;
IMPORT A := DarwinActivities, Commands;

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

PROCEDURE Run*(context: Commands.Context);
BEGIN Check(TRUE); context.out.String("PASS compiler checkpoints in WHILE, REPEAT, FOR and LOOP; EXCLUSIVE and UNCOOPERATIVE respected"); context.out.Ln END Run;

PROCEDURE Control*(context: Commands.Context);
BEGIN Check(FALSE); context.out.String("PASS default compilation leaves loops uninterrupted"); context.out.Ln END Control;
END DarwinLoopCheckpointProbe.
