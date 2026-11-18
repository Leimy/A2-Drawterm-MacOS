MODULE DarwinActivitiesProbe;
IMPORT A := DarwinActivities, Commands, Kernel, Unix;

CONST BatchSize = 256;
TYPE
	Token = POINTER TO RECORD value: SIZE END;
	Trial = OBJECT
	VAR scheduler: A.Scheduler; worker: Unix.Thread_t;
		batch: ARRAY BatchSize OF SIZE; used, count, finished, switches: SIZE;
		stopping: BOOLEAN; primes: POINTER TO ARRAY OF SIZE;
	END Trial;

	Filter = OBJECT(A.Activity)
	VAR trial: Trial; prime: SIZE; next: Filter;

		PROCEDURE Wait(token: Token);
		VAR expected: SIZE;
		BEGIN
			expected := token.value;
			Park;
			ASSERT(Unix.ThrThis() = trial.worker);
			ASSERT((token.value = expected) & (expected = prime*17+3))
		END Wait;

		PROCEDURE Run*;
		VAR i, kept: SIZE; token: Token;
		BEGIN
			ASSERT(Unix.ThrThis() = trial.worker);
			NEW(token); token.value := prime*17+3;
			trial.primes[trial.count] := prime; INC(trial.count);
			LOOP
				kept := 0;
				FOR i := 0 TO trial.used-1 DO
					IF trial.batch[i] MOD prime # 0 THEN
						trial.batch[kept] := trial.batch[i]; INC(kept)
					END
				END;
				trial.used := kept;
				IF kept > 0 THEN
					IF next = NIL THEN
						NEW(next); next.trial := trial; next.prime := trial.batch[0]; trial.scheduler.Start(next)
					ELSE next.Wake END
				END;
				INC(trial.switches); Wait(token);
				IF trial.stopping THEN EXIT END
			END;
			IF next # NIL THEN next.Wake END;
			INC(trial.finished)
		END Run;
	END Filter;

TYPE
	Collector = OBJECT
	VAR start, finished: BOOLEAN;
		PROCEDURE Start;
		BEGIN {EXCLUSIVE} start := TRUE END Start;
		PROCEDURE Done(): BOOLEAN;
		BEGIN {EXCLUSIVE} RETURN finished END Done;
	BEGIN {ACTIVE}
		BEGIN {EXCLUSIVE} AWAIT(start) END;
		Kernel.GC;
		BEGIN {EXCLUSIVE} finished := TRUE END
	END Collector;

	GCProbe = OBJECT(A.Activity)
	VAR collector: Collector; trace: SIZE;
		PROCEDURE Run*;
		VAR token: Token;
		BEGIN
			NEW(token); token.value := 7351;
			Kernel.GC; (* collect on the alternate stack *)
			collector.Start;
			WHILE ~collector.Done() DO END; (* collect from a different pthread *)
			ASSERT(token.value = 7351);
			trace := 1; Yield; ASSERT(trace = 2); trace := 3
		END Run;
	END GCProbe;

PROCEDURE Run*(context: Commands.Context);
VAR trial: Trial; first: Filter; probe: GCProbe; limit: SIGNED32; value, factor, expected: SIZE; composite: POINTER TO ARRAY OF BOOLEAN;
BEGIN
	limit := 100000;
	context.arg.SkipWhitespace; IF context.arg.Peek() > " " THEN context.arg.Int(limit,FALSE) END;
	ASSERT((limit >= 2) & (limit <= 100000));
	NEW(trial); NEW(trial.primes,limit); NEW(trial.scheduler); trial.worker := Unix.ThrThis();
	NEW(probe); NEW(probe.collector); trial.scheduler.Start(probe);
	ASSERT(trial.scheduler.Dispatch()); ASSERT(probe.trace = 1); probe.trace := 2;
	ASSERT(trial.scheduler.Dispatch()); ASSERT(probe.trace = 3);
	NEW(first); first.trial := trial; first.prime := 2; trial.scheduler.Start(first);
	value := 3;
	LOOP
		trial.used := 0;
		WHILE (value <= limit) & (trial.used < BatchSize) DO
			trial.batch[trial.used] := value; INC(trial.used); INC(value,2)
		END;
		WHILE trial.scheduler.Dispatch() DO END;
		ASSERT(trial.used = 0);
		IF value > limit THEN EXIT END;
		first.Wake
	END;
	ASSERT(trial.scheduler.live = trial.count);
	Kernel.GC; (* Every filter is parked inside a nested call with a private heap reference. *)
	trial.stopping := TRUE; first.Wake;
	WHILE trial.scheduler.Dispatch() DO END;
	ASSERT((trial.finished = trial.count) & (trial.scheduler.live = 0)); trial.scheduler.Close;
	NEW(composite,limit+1); expected := 0;
	FOR value := 2 TO limit DO
		IF ~composite[value] THEN
			ASSERT((expected < trial.count) & (trial.primes[expected] = value)); INC(expected);
			factor := value+value; WHILE factor <= limit DO composite[factor] := TRUE; INC(factor,value) END
		END
	END;
	ASSERT(expected = trial.count);
	context.out.String("PASS single worker, parked GC and exact sieve through "); context.out.Int(limit,0);
	context.out.String(": "); context.out.Int(expected,0); context.out.String(" activities, ");
	context.out.Int(trial.switches,0); context.out.String(" parks"); context.out.Ln
END Run;
END DarwinActivitiesProbe.
