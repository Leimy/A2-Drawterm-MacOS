MODULE DarwinActivities;
(** Branch experiment. A scheduler and its activities are confined to the
    A2 process that constructs them. Park and Yield can be called at depth. *)
IMPORT SYSTEM, Glue, Unix, Objects, Heaps, Machine;

TYPE
	Activity* = OBJECT
	VAR owner: Scheduler; next: Activity; fiber: ADDRESS; queued: BOOLEAN;

		PROCEDURE Run*;
		BEGIN HALT(101) END Run;

		PROCEDURE Wake*;
		BEGIN
			ASSERT((owner # NIL) & (owner.worker = Objects.CurrentProcess()));
			IF ~queued THEN
				IF owner.tail = NIL THEN owner.head := SELF ELSE owner.tail.next := SELF END;
				owner.tail := SELF; queued := TRUE
			END
		END Wake;

		PROCEDURE Park*;
		BEGIN
			ASSERT((owner # NIL) & (owner.worker = Objects.CurrentProcess()) & (owner.running = SELF));
			park(fiber)
		END Park;

		PROCEDURE Yield*;
		BEGIN Wake; Park END Yield;
	END Activity;

	Scheduler* = OBJECT
	VAR worker: Objects.Process; pool: ADDRESS; head, tail, running: Activity; live-: SIZE;

		PROCEDURE &Init*;
		BEGIN
			worker := Objects.CurrentProcess(); ASSERT(worker.stackScanner = NIL);
			pool := newPool(); ASSERT(pool # 0);
			Machine.Acquire(Machine.Heaps); worker.stackScanner := Scan; Machine.Release(Machine.Heaps)
		END Init;

		PROCEDURE Scan(sp, bottom: ADDRESS);
		BEGIN roots(pool, sp, bottom, Candidates) END Scan;

		PROCEDURE Start*(a: Activity);
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (pool # 0) & (a.owner = NIL));
			Machine.Acquire(Machine.Heaps);
			a.fiber := newFiber(pool, Enter, SYSTEM.VAL(ADDRESS,a));
			Machine.Release(Machine.Heaps);
			ASSERT(a.fiber # 0); a.owner := SELF; INC(live); a.Wake
		END Start;

		PROCEDURE Dispatch*(): BOOLEAN;
		VAR a: Activity;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (running = NIL));
			a := head; IF a = NIL THEN RETURN FALSE END;
			head := a.next; IF head = NIL THEN tail := NIL END;
			a.next := NIL; a.queued := FALSE; running := a;
			IF resume(a.fiber) # 0 THEN
				ASSERT(~a.queued);
				Machine.Acquire(Machine.Heaps); drop(a.fiber); Machine.Release(Machine.Heaps);
				a.fiber := 0; a.owner := NIL; DEC(live)
			END;
			running := NIL; RETURN TRUE
		END Dispatch;

		PROCEDURE Close*;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (live = 0) & (pool # 0));
			Machine.Acquire(Machine.Heaps); worker.stackScanner := NIL; close(pool); pool := 0; Machine.Release(Machine.Heaps)
		END Close;
	END Scheduler;

VAR library: ADDRESS;
	newPool: PROCEDURE {C}(): ADDRESS;
	newFiber: PROCEDURE {C}(pool: ADDRESS; entry: PROCEDURE {C}(arg: ADDRESS); arg: ADDRESS): ADDRESS;
	resume: PROCEDURE {C}(fiber: ADDRESS): SIGNED32;
	park, drop, close: PROCEDURE {C}(handle: ADDRESS);
	roots: PROCEDURE {C}(pool, sp, bottom: ADDRESS; visit: PROCEDURE {C}(adr: ADDRESS; size: SIZE));

PROCEDURE {C} Enter(arg: ADDRESS);
VAR a: Activity;
BEGIN a := SYSTEM.VAL(Activity,arg); a.Run END Enter;

PROCEDURE {C} Candidates(adr: ADDRESS; size: SIZE);
BEGIN Heaps.RegisterCandidates(adr, size) END Candidates;

BEGIN
	library := Glue.dlopen(ADDRESSOF("@executable_path/libA2Activities.dylib"), 2); ASSERT(library # 0);
	Unix.Dlsym(library, "activity_pool", ADDRESSOF(newPool));
	Unix.Dlsym(library, "activity_new", ADDRESSOF(newFiber));
	Unix.Dlsym(library, "activity_resume", ADDRESSOF(resume));
	Unix.Dlsym(library, "activity_park", ADDRESSOF(park));
	Unix.Dlsym(library, "activity_drop", ADDRESSOF(drop));
	Unix.Dlsym(library, "activity_close", ADDRESSOF(close));
	Unix.Dlsym(library, "activity_roots", ADDRESSOF(roots))
END DarwinActivities.
