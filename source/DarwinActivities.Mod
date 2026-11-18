MODULE DarwinActivities;
(** Branch experiment. A scheduler and its activities are confined to the
    A2 process that constructs them. Park and Yield can be called at depth. *)
IMPORT SYSTEM, Glue, Unix, Objects, Heaps, Machine, Modules;

TYPE
	Activity* = OBJECT
	VAR owner: Scheduler; next: Activity; fiber: ADDRESS; queued: BOOLEAN;
		waitNext: Activity; guard: Objects.ActivityCondition; frame: ADDRESS;
		children: BOOLEAN; context: ANY; subject: Objects.ActivitySelf;

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

	BodyActivity = OBJECT(Activity)
	VAR body: Objects.ActivityBody;
		PROCEDURE Run*;
		BEGIN body(subject) END Run;
	END BodyActivity;

	WaitQueue = RECORD first, last: Activity END;

	Monitor = OBJECT
	VAR bound: Modules.Module; nextBound: Monitor; scheduler: Scheduler; holder: Activity; guards, entrants: WaitQueue;

		PROCEDURE Append(VAR q: WaitQueue; a: Activity);
		BEGIN
			IF q.last = NIL THEN q.first := a ELSE q.last.waitNext := a END;
			q.last := a
		END Append;

		PROCEDURE HandOff;
		VAR a, prev: Activity;
		BEGIN
			holder := NIL; prev := NIL; a := guards.first;
			WHILE a # NIL DO
				IF a.guard(a.frame) THEN
					IF prev = NIL THEN guards.first := a.waitNext ELSE prev.waitNext := a.waitNext END;
					IF guards.last = a THEN guards.last := prev END;
					a.waitNext := NIL; a.guard := NIL; a.frame := 0;
					holder := a; a.Wake; RETURN
				END;
				prev := a; a := a.waitNext
			END;
			a := entrants.first;
			IF a # NIL THEN
				entrants.first := a.waitNext; IF entrants.first = NIL THEN entrants.last := NIL END;
				a.waitNext := NIL; holder := a; a.Wake
			END
		END HandOff;

		PROCEDURE Call(op: INTEGER; cond: Objects.ActivityCondition; frame: ADDRESS);
		VAR a: Activity;
		BEGIN
			ASSERT(Objects.CurrentProcess() = scheduler.worker);
			a := scheduler.running; ASSERT(a # NIL);
			CASE op OF
			| 0: IF holder = NIL THEN holder := a; RETURN END; Append(entrants, a)
			| 1: ASSERT(holder = a); HandOff; a.guard := cond; a.frame := frame; Append(guards, a)
			| 2: ASSERT(holder = a); HandOff; RETURN
			END;
			a.Park; ASSERT(holder = a)
		END Call;
	END Monitor;

	Scheduler* = OBJECT
	VAR worker: Objects.Process; pool: ADDRESS; head, tail, running: Activity; live-, adopted-: SIZE; bindings: Monitor;

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
			ASSERT(a.fiber # 0); a.owner := SELF; a.context := Objects.CurrentContext(); INC(live); a.Wake
		END Start;

		(* Run a command and recursively enroll ordinary NEW active bodies during
		   its dispatches. Unrelated work on the host still uses native threads. *)
		PROCEDURE StartTree*(a: Activity);
		BEGIN a.children := TRUE; Start(a) END StartTree;

		(* Use this only when the workload owns all calls to this module monitor
		   until Close restores ordinary locking. *)
		PROCEDURE BindModule*(obj: Modules.Module);
		VAR m: Monitor;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (running = NIL) & (pool # 0) & (obj # NIL));
			NEW(m); m.scheduler := SELF; m.bound := obj;
			Objects.BindActivityMonitor(obj, m.Call, TRUE);
			m.nextBound := bindings; bindings := m
		END BindModule;

		(* The next ordinary active object constructed on this worker is enrolled.
		   Its monitor may only be entered by activities dispatched by this scheduler. *)
		PROCEDURE NextActive*;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (pool # 0) & (worker.nextActivity = NIL));
			worker.nextActivity := Adopt
		END NextActive;

		PROCEDURE Adopt(body: Objects.ActivityBody; obj: Objects.ActivitySelf): Objects.MonitorCall;
		VAR a: BodyActivity; m: Monitor;
		BEGIN
			NEW(m); m.scheduler := SELF; NEW(a); a.subject := obj; a.body := body;
			a.children := (running # NIL) & running.children; Start(a); INC(adopted); RETURN m.Call
		END Adopt;

		PROCEDURE YieldCurrent*;
		BEGIN ASSERT(worker = Objects.CurrentProcess()); running.Yield END YieldCurrent;

		PROCEDURE Dispatch*(): BOOLEAN;
		VAR a: Activity; hostContext: ANY; done: BOOLEAN;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (running = NIL));
			a := head; IF a = NIL THEN RETURN FALSE END;
			head := a.next; IF head = NIL THEN tail := NIL END;
			a.next := NIL; a.queued := FALSE; running := a;
			hostContext := Objects.CurrentContext(); Objects.SetContext(a.context); worker.activitySelf := a.subject;
			IF a.children THEN worker.childActivity := Adopt END;
			done := resume(a.fiber) # 0; worker.childActivity := NIL;
			worker.activitySelf := NIL; a.context := Objects.CurrentContext(); Objects.SetContext(hostContext);
			IF done THEN
				ASSERT(~a.queued);
				Machine.Acquire(Machine.Heaps); drop(a.fiber); Machine.Release(Machine.Heaps);
				a.fiber := 0; a.owner := NIL; DEC(live)
			END;
			running := NIL; RETURN TRUE
		END Dispatch;

		PROCEDURE Close*;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (live = 0) & (pool # 0) & (worker.nextActivity = NIL));
			WHILE bindings # NIL DO
				Objects.BindActivityMonitor(bindings.bound, bindings.Call, FALSE); bindings := bindings.nextBound
			END;
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
