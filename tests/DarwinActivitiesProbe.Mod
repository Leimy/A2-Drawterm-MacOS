MODULE DarwinActivitiesProbe;
IMPORT A := DarwinActivities, Commands, Kernel, Unix, Objects, Modules, ConcurrentSieve, CSPDemo, CSP, DarwinCommandWorkers;

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

TYPE
	Exchange = OBJECT
	VAR scheduler: A.Scheduler; worker: Unix.Thread_t; value, consumed: SIZE;

		PROCEDURE Put(n: SIZE);
		BEGIN {EXCLUSIVE}
			AWAIT(value = 0); value := n
		END Put;

		PROCEDURE Take(expected: SIZE);
		BEGIN {EXCLUSIVE}
			IF expected = 1 THEN scheduler.YieldCurrent END; (* producer contends for this lock *)
			AWAIT(value = expected); (* predicate uses this call's stack frame *)
			ASSERT(Unix.ThrThis() = worker); ASSERT(Objects.ActiveObject() = SELF);
			value := 0; INC(consumed)
		END Take;

	VAR i: SIZE;
	BEGIN {ACTIVE}
		FOR i := 1 TO 1000 DO Take(i) END
	END Exchange;

	Producer = OBJECT
	VAR exchange: Exchange; i: SIZE;
	BEGIN {ACTIVE}
		FOR i := 1 TO 1000 DO
			ASSERT(Objects.ActiveObject() = SELF); ASSERT(Unix.ThrThis() = exchange.worker);
			exchange.Put(i)
		END
	END Producer;

PROCEDURE CheckMonitors(context: Commands.Context);
VAR scheduler: A.Scheduler; exchange: Exchange; producer: Producer;
BEGIN
	NEW(scheduler);
	scheduler.NextActive; NEW(exchange); exchange.scheduler := scheduler; exchange.worker := Unix.ThrThis();
	scheduler.NextActive; NEW(producer); producer.exchange := exchange;
	ASSERT(scheduler.Dispatch()); (* consumer yields holding the monitor *)
	ASSERT(scheduler.Dispatch()); (* producer parks entering Put *)
	ASSERT(scheduler.Dispatch()); (* consumer awaits, admitting producer *)
	ASSERT((exchange.consumed = 0) & (scheduler.live = 2));
	Kernel.GC;
	WHILE scheduler.Dispatch() DO END;
	ASSERT((scheduler.live = 0) & (exchange.consumed = 1000) & (exchange.value = 0)); scheduler.Close;
	context.out.String("PASS two ACTIVE bodies, contended EXCLUSIVE and 1000 AWAIT exchanges on one pthread"); context.out.Ln
END CheckMonitors;

TYPE
	SieveCommand = OBJECT(A.Activity)
	VAR context: Commands.Context; channels, finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN
			IF channels THEN CSPDemo.Run(context) ELSE ConcurrentSieve.Run(context) END;
			finished := TRUE
		END Run;
	END SieveCommand;

PROCEDURE RunTree(context: Commands.Context; channels: BOOLEAN);
VAR scheduler: A.Scheduler; command: SieveCommand; module: Modules.Module; channel: CSP.Channel;
	res: INTEGER; msg: ARRAY 128 OF CHAR;
BEGIN
	IF channels THEN module := Modules.ThisModule("CSP", res, msg)
	ELSE module := Modules.ThisModule("ConcurrentSieve", res, msg) END;
	ASSERT(module # NIL);
	NEW(scheduler); scheduler.BindModule(module);
	NEW(command); command.context := context; command.channels := channels; scheduler.StartTree(command);
	WHILE scheduler.Dispatch() DO END;
	ASSERT(command.finished & (scheduler.live = 0)); scheduler.Close;
	IF channels THEN
		NEW(channel, 0); ASSERT(channel.Close()); ASSERT(channel.IsClosed()) (* back on the host *)
	END;
	context.out.String("Joined lightweight filter bodies: "); context.out.Int(scheduler.adopted, 0); context.out.Ln
END RunTree;

PROCEDURE Mailboxes*(context: Commands.Context);
BEGIN RunTree(context, FALSE) END Mailboxes;

PROCEDURE Channels*(context: Commands.Context);
BEGIN RunTree(context, TRUE) END Channels;

TYPE
	Compute = OBJECT
	VAR steps: SIZE; cooperative: BOOLEAN;
	BEGIN {ACTIVE}
		WHILE steps < 4 * A.CheckpointInterval DO
			INC(steps);
			IF cooperative THEN A.Checkpoint END
		END
	END Compute;

PROCEDURE CheckFairness(context: Commands.Context);
VAR scheduler: A.Scheduler; first, second, solo: Compute; turn: SIZE;
BEGIN
	NEW(scheduler);
	scheduler.NextActive; NEW(first); scheduler.NextActive; NEW(second);
	ASSERT(scheduler.Dispatch());
	ASSERT((first.steps = 4 * A.CheckpointInterval) & (second.steps = 0));
	ASSERT(scheduler.Dispatch()); ASSERT(scheduler.live = 0);

	scheduler.NextActive; NEW(first); first.cooperative := TRUE;
	scheduler.NextActive; NEW(second); second.cooperative := TRUE;
	FOR turn := 1 TO 4 DO
		ASSERT(scheduler.Dispatch());
		ASSERT((first.steps = turn * A.CheckpointInterval) & (second.steps = (turn-1) * A.CheckpointInterval));
		ASSERT(scheduler.Dispatch()); ASSERT(second.steps = first.steps)
	END;
	WHILE scheduler.Dispatch() DO END;
	scheduler.NextActive; NEW(solo); solo.cooperative := TRUE;
	ASSERT(scheduler.Dispatch()); ASSERT((solo.steps = 4 * A.CheckpointInterval) & (scheduler.live = 0));
	scheduler.Close;
	context.out.String("PASS cooperative CPU loops alternate every 256 checkpoints; unchecked loop occupies one turn"); context.out.Ln
END CheckFairness;

TYPE
	Pinned = OBJECT(A.Activity)
	VAR worker: Unix.Thread_t; id: SIZE; finished: BOOLEAN;
		PROCEDURE Run*;
		VAR token: Token;
		BEGIN
			ASSERT(Unix.ThrThis() = worker);
			NEW(token); token.value := id; Park;
			ASSERT((Unix.ThrThis() = worker) & (token.value = id)); finished := TRUE
		END Run;
	END Pinned;

	TestWorker = OBJECT
	VAR tid: Unix.Thread_t; parked, released, finished: BOOLEAN;
		PROCEDURE WaitParked(): Unix.Thread_t;
		BEGIN {EXCLUSIVE} AWAIT(parked); RETURN tid END WaitParked;
		PROCEDURE Release;
		BEGIN {EXCLUSIVE} released := TRUE END Release;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(finished) END Join;

	VAR scheduler: A.Scheduler; tasks: ARRAY 64 OF Pinned; i: SIZE;
	BEGIN {ACTIVE}
		NEW(scheduler); tid := Unix.ThrThis();
		FOR i := 0 TO LEN(tasks)-1 DO
			NEW(tasks[i]); tasks[i].worker := tid; tasks[i].id := i; scheduler.Start(tasks[i])
		END;
		WHILE scheduler.Dispatch() DO END;
		ASSERT(scheduler.live = LEN(tasks));
		BEGIN {EXCLUSIVE} parked := TRUE; AWAIT(released) END;
		FOR i := 0 TO LEN(tasks)-1 DO tasks[i].Wake END;
		WHILE scheduler.Dispatch() DO END;
		FOR i := 0 TO LEN(tasks)-1 DO ASSERT(tasks[i].finished) END;
		scheduler.Close;
		BEGIN {EXCLUSIVE} finished := TRUE END
	END TestWorker;

PROCEDURE CheckWorkers(context: Commands.Context);
VAR first, second: TestWorker; t1, t2: Unix.Thread_t;
BEGIN
	NEW(first); NEW(second);
	t1 := first.WaitParked(); t2 := second.WaitParked(); ASSERT(t1 # t2);
	Kernel.GC;
	second.Release; second.Join; (* first is still blocked on its native monitor *)
	first.Release; first.Join;
	context.out.String("PASS 128 lightweight activities on two distinct pthreads, parked GC and independent progress"); context.out.Ln
END CheckWorkers;

VAR entered, released: BOOLEAN; blockedThread, previousWorker: Unix.Thread_t; visits: SIZE;

PROCEDURE BlockWorker*(context: Commands.Context);
BEGIN {EXCLUSIVE}
	ASSERT(Objects.CurrentProcess().checkpointDue # NIL);
	blockedThread := Unix.ThrThis(); entered := TRUE; AWAIT(released)
END BlockWorker;

PROCEDURE ReleaseWorker*(context: Commands.Context);
BEGIN {EXCLUSIVE}
	AWAIT(entered); ASSERT(Objects.CurrentProcess().checkpointDue # NIL);
	ASSERT(Unix.ThrThis() # blockedThread); ASSERT(DarwinCommandWorkers.PoolSize() = 2); released := TRUE
END ReleaseWorker;

PROCEDURE CheckRouting*(context: Commands.Context);
VAR res: INTEGER; msg: Modules.Name;
BEGIN
	ASSERT(DarwinCommandWorkers.PoolSize() = 0);
	Commands.Activate("DarwinActivitiesProbe.BlockWorker", NIL, {}, res, msg); ASSERT(res = Commands.Ok);
	Commands.Activate("DarwinActivitiesProbe.ReleaseWorker", NIL, {Commands.Wait}, res, msg); ASSERT(res = Commands.Ok);
	WHILE DarwinCommandWorkers.PoolSize() # 1 DO Objects.Sleep(1) END;
	context.out.String("PASS demand scaling from zero to two workers and back to one"); context.out.Ln;
	context.out.String("PASS ordinary commands on two automatically assigned worker pthreads"); context.out.Ln
END CheckRouting;

PROCEDURE RecordWorker*(context: Commands.Context);
BEGIN
	ASSERT((Objects.CurrentProcess().checkpointDue # NIL) & (Commands.GetContext() = context));
	IF visits = 0 THEN previousWorker := Unix.ThrThis() ELSE ASSERT(previousWorker = Unix.ThrThis()) END;
	INC(visits); context.result := 71
END RecordWorker;

PROCEDURE TrapWorker*(context: Commands.Context);
BEGIN
	ASSERT(Objects.CurrentProcess().checkpointDue # NIL);
	previousWorker := Unix.ThrThis(); HALT(73)
END TrapWorker;

VAR cleanups, siblingCleanups, escaped: SIZE;
TYPE
	FailingChild = OBJECT
	VAR done, armed: BOOLEAN;
		PROCEDURE Arm;
		BEGIN {EXCLUSIVE} armed := TRUE END Arm;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE}
			AWAIT(done)
		END Join;
	BEGIN {ACTIVE}
		BEGIN {EXCLUSIVE} AWAIT(armed) END; HALT(73)
	END FailingChild;

	WaitingSibling = OBJECT
	VAR child: FailingChild;
		PROCEDURE &Init(c: FailingChild);
		BEGIN child := c END Init;
	BEGIN {ACTIVE}
		child.Arm; child.Join; INC(escaped)
	FINALLY
		INC(siblingCleanups)
	END WaitingSibling;

PROCEDURE ChildTrap*(context: Commands.Context);
VAR c: FailingChild; sibling: WaitingSibling;
BEGIN
	previousWorker := Unix.ThrThis(); NEW(c); NEW(sibling, c); c.Join; INC(escaped)
FINALLY
	INC(cleanups)
END ChildTrap;

PROCEDURE CheckChildRecovery*(context: Commands.Context);
VAR res: INTEGER; msg: Modules.Name;
BEGIN
	Commands.Activate("DarwinActivitiesProbe.ChildTrap", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & (cleanups = 1) & (siblingCleanups = 1) & (escaped = 0));
	visits := 1; Kernel.GC;
	Commands.Activate("DarwinActivitiesProbe.RecordWorker", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = 71) & (visits = 2));
	context.out.String("PASS child trap unwound parent FINALLY and preserved worker"); context.out.Ln
END CheckChildRecovery;

PROCEDURE CheckRecovery*(context: Commands.Context);
VAR res: INTEGER; pass: SIZE; msg: Modules.Name;
BEGIN
	FOR pass := 1 TO 2 DO
		Commands.Activate("DarwinActivitiesProbe.TrapWorker", NIL, {Commands.Wait}, res, msg);
		ASSERT((res = Commands.CommandTrapped) & (msg = "Exception during command execution"));
		visits := 1; (* RecordWorker now requires the pthread that ran TrapWorker. *)
		Kernel.GC;
		Commands.Activate("DarwinActivitiesProbe.RecordWorker", NIL, {Commands.Wait}, res, msg);
		ASSERT((res = 71) & (visits = 2))
	END;
	context.out.String("PASS pooled HALT returned CommandTrapped and the same worker ran the next command"); context.out.Ln
END CheckRecovery;

PROCEDURE CheckReuse*(context: Commands.Context);
VAR i: SIZE; res: INTEGER; msg: Modules.Name;
BEGIN
	FOR i := 1 TO 2 DO
		Commands.Activate("DarwinActivitiesProbe.RecordWorker", NIL, {Commands.Wait}, res, msg);
		ASSERT(res = 71)
	END;
	ASSERT(visits = 2);
	context.out.String("PASS one worker reused across commands with context and result preserved"); context.out.Ln
END CheckReuse;

TYPE
	MixedProducer = OBJECT
	VAR started, finished: BOOLEAN; sent, acknowledged: SIZE; producerThread: Unix.Thread_t;
		PROCEDURE Start;
		BEGIN {EXCLUSIVE} started := TRUE END Start;
		PROCEDURE Receive(sequence: SIZE);
		BEGIN {EXCLUSIVE}
			AWAIT(sent = sequence); ASSERT(Unix.ThrThis() # producerThread); acknowledged := sequence
		END Receive;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(finished) END Join;
	VAR n: SIZE;
	BEGIN {ACTIVE}
		BEGIN {EXCLUSIVE} AWAIT(started) END;
		Kernel.GC;
		FOR n := 1 TO 1000 DO
			BEGIN {EXCLUSIVE}
				producerThread := Unix.ThrThis(); sent := n; AWAIT(acknowledged = n)
			END
		END;
		BEGIN {EXCLUSIVE} finished := TRUE END
	END MixedProducer;

	MixedConsumer = OBJECT(A.Activity)
	VAR producer: MixedProducer; received: SIZE; ownerThread: Unix.Thread_t;
		PROCEDURE Run*;
		VAR n: SIZE;
		BEGIN
			FOR n := 1 TO 1000 DO
				producer.Receive(n); ASSERT(Unix.ThrThis() = ownerThread); INC(received)
			END
		END Run;
	END MixedConsumer;

	MixedStarter = OBJECT(A.Activity)
	VAR producer: MixedProducer; ran: BOOLEAN;
		PROCEDURE Run*;
		BEGIN ran := TRUE; producer.Start END Run;
	END MixedStarter;

PROCEDURE CheckMixed(context: Commands.Context);
VAR s: A.Scheduler; p: MixedProducer; reader: MixedConsumer; starter: MixedStarter;
BEGIN
	NEW(p); NEW(s); NEW(reader); reader.producer := p; reader.ownerThread := Unix.ThrThis();
	NEW(starter); starter.producer := p; s.Start(reader); s.Start(starter);
	ASSERT(s.Dispatch()); ASSERT((reader.received = 0) & ~starter.ran);
	ASSERT(s.Dispatch()); ASSERT(starter.ran);
	s.Drain; ASSERT((s.live = 0) & (reader.received = 1000)); s.Close; p.Join;
	context.out.String("PASS 1000 native/fiber AWAIT exchanges on one monitor, peer progress and parked GC"); context.out.Ln
END CheckMixed;

TYPE
	Slot = OBJECT
	VAR item: SIZE;
		PROCEDURE Take(): SIZE;
		VAR n: SIZE;
		BEGIN {EXCLUSIVE} AWAIT(item # 0); n := item; item := 0; RETURN n END Take;
		PROCEDURE Put(n: SIZE);
		BEGIN {EXCLUSIVE} ASSERT(item = 0); item := n END Put;
	END Slot;

	Taker = OBJECT(A.Activity)
	VAR slot: Slot; got: SIZE;
		PROCEDURE Run*;
		BEGIN got := slot.Take() END Run;
	END Taker;

PROCEDURE CheckStaleWake(context: Commands.Context);
VAR s: A.Scheduler; slot: Slot; a, b: Taker;
BEGIN
	NEW(s); NEW(slot); NEW(a); NEW(b); a.slot := slot; b.slot := slot;
	s.Start(a); s.Start(b); WHILE s.Dispatch() DO END; ASSERT(s.live = 2);
	slot.Put(7); WHILE s.Dispatch() DO END;
	ASSERT((s.live = 1) & (a.got + b.got = 7));
	slot.Put(9); s.Drain; s.Close; ASSERT(a.got + b.got = 16);
	context.out.String("PASS competing native-monitor waiters rechecked the consumed item"); context.out.Ln
END CheckStaleWake;

VAR cancelledSlot: Slot; cleanedNative: SIZE;
TYPE
	TrapOnEntry = OBJECT
	BEGIN {ACTIVE} HALT(73)
	END TrapOnEntry;

PROCEDURE NativeWaitTrap*(context: Commands.Context);
VAR child: TrapOnEntry; n: SIZE;
BEGIN
	NEW(cancelledSlot); previousWorker := Unix.ThrThis(); NEW(child); n := cancelledSlot.Take(); INC(escaped)
FINALLY
	INC(cleanedNative)
END NativeWaitTrap;

PROCEDURE CheckNativeRecovery*(context: Commands.Context);
VAR res: INTEGER; msg: Modules.Name;
BEGIN
	Commands.Activate("DarwinActivitiesProbe.NativeWaitTrap", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & (cleanedNative = 1) & (escaped = 0));
	Kernel.GC; cancelledSlot.Put(42); ASSERT(cancelledSlot.Take() = 42);
	visits := 1;
	Commands.Activate("DarwinActivitiesProbe.RecordWorker", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = 71) & (visits = 2));
	context.out.String("PASS cancelled native-monitor wait ran FINALLY and released its registration"); context.out.Ln
END CheckNativeRecovery;

PROCEDURE Run*(context: Commands.Context);
VAR trial: Trial; first: Filter; probe: GCProbe; limit: SIGNED32; value, factor, expected: SIZE; composite: POINTER TO ARRAY OF BOOLEAN;
BEGIN
	CheckStaleWake(context); CheckMixed(context); CheckWorkers(context); CheckFairness(context); CheckMonitors(context);
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
