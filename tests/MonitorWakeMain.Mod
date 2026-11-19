MODULE MonitorWakeMain;
IMPORT A := ActivityScheduler, Objects, Heaps, Unix, StdIO;

CONST ColdCount = 128; Rounds = 64;

TYPE
	Mailbox = OBJECT
	VAR full: BOOLEAN;
		PROCEDURE Put;
		BEGIN {EXCLUSIVE} ASSERT(~full); full := TRUE END Put;
		PROCEDURE Take;
		BEGIN {EXCLUSIVE} AWAIT(full); full := FALSE END Take;
	END Mailbox;

	Sleeper = OBJECT(A.Activity)
	VAR box: Mailbox; done: BOOLEAN;
		PROCEDURE Run;
		BEGIN box.Take; done := TRUE END Run;
	END Sleeper;

	Handshake = OBJECT
	VAR mutex, changed: ADDRESS; request, posted: SIZE; box: Mailbox;
		PROCEDURE &Init;
		BEGIN mutex := Unix.NewMtx(); changed := Unix.NewCond(); NEW(box) END Init;
	END Handshake;

	Producer = OBJECT
	VAR h: Handshake;
		PROCEDURE &Init(h: Handshake);
		BEGIN SELF.h := h END Init;
	VAR i: SIZE;
	BEGIN {ACTIVE}
		FOR i := 1 TO Rounds DO
			Unix.MtxLock(h.mutex);
			WHILE h.request < i DO Unix.CondWait(h.changed, h.mutex) END;
			h.box.Put; h.posted := i; Unix.CondSignal(h.changed); Unix.MtxUnlock(h.mutex)
		END
	END Producer;

	Consumer = OBJECT(A.Activity)
	VAR h: Handshake; park: PROCEDURE {DELEGATE}(): BOOLEAN; allocations: SIZE;
		(* Objects.AwaitExternal invokes this after releasing the mailbox.
		   Block the owner pthread here until the independent producer has
		   returned from Put, including the synchronous Post callback. *)
		PROCEDURE PostBeforePark(): BOOLEAN;
		BEGIN
			Unix.MtxLock(h.mutex); INC(h.request); Unix.CondSignal(h.changed);
			WHILE h.posted < h.request DO Unix.CondWait(h.changed, h.mutex) END;
			Unix.MtxUnlock(h.mutex); RETURN park()
		END PostBeforePark;

		PROCEDURE Run;
		VAR i, baseline: SIZE; p: Objects.Process;
		BEGIN
			p := Objects.CurrentProcess();
			FOR i := 1 TO Rounds DO
				park := p.waitExternal; p.waitExternal := PostBeforePark;
				h.box.Take;
				IF i = 1 THEN baseline := Heaps.Nnew END
			END;
			allocations := Heaps.Nnew - baseline
		END Run;
	END Consumer;

VAR s: A.Scheduler; cold: ARRAY ColdCount OF Sleeper; h: Handshake;
    c: Consumer; producer: Producer; i, before: SIZE;
BEGIN
	NEW(s);
	FOR i := 0 TO ColdCount-1 DO
		NEW(cold[i]); NEW(cold[i].box); s.Start(cold[i]); ASSERT(s.Dispatch())
	END;
	NEW(h); NEW(producer, h); NEW(c); c.h := h; s.Start(c);
	before := s.pollVisits;
	FOR i := 0 TO Rounds DO ASSERT(s.Dispatch()) END;
	ASSERT(h.posted = Rounds);
	ASSERT(s.pollVisits - before = Rounds);
	(* Process-wide heap counter; allow incidental runtime allocation, but
	   allocating a guard per wait would add at least Rounds-1 records. *)
	ASSERT(c.allocations < Rounds DIV 4);
	FOR i := 0 TO ColdCount-1 DO cold[i].box.Put END;
	s.Drain; s.Close;
	FOR i := 0 TO ColdCount-1 DO ASSERT(cold[i].done) END;
	Unix.CondDestroy(h.changed); Unix.free(h.changed); Unix.MtxDestroy(h.mutex); Unix.free(h.mutex);
	StdIO.env.out.String("PASS 64 posts before park with 128 idle waiters; heap allocations after warmup: ");
	StdIO.env.out.Int(c.allocations,0); StdIO.env.out.Ln; StdIO.env.out.Update
END MonitorWakeMain.
