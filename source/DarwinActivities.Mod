MODULE DarwinActivities;
(** Branch experiment. A scheduler and its activities are confined to the
    A2 process that constructs them. Park and Yield can be called at depth. *)
IMPORT SYSTEM, Glue, Unix, Objects, Heaps, Machine, Modules;

CONST CheckpointInterval* = 256; (* work checkpoints per turn *)

TYPE
	Activity* = OBJECT
	VAR owner: Scheduler; next: Activity; fiber: ADDRESS; queued: BOOLEAN;
		externalNext: Activity; posted: BOOLEAN; waitNext: Activity; guard: Objects.ActivityCondition; frame: ADDRESS;
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

		(* The producer may run on another pthread. Only the owner touches its
		   ready queue; the producer latches a notification under a native mutex. *)
		PROCEDURE Post;
		BEGIN
			Unix.MtxLock(owner.inboxLock); posted := TRUE; Unix.CondSignal(owner.changed); Unix.MtxUnlock(owner.inboxLock)
		END Post;

		PROCEDURE Park*;
		BEGIN
			ASSERT((owner # NIL) & (owner.worker = Objects.CurrentProcess()) & (owner.running = SELF));
			park(fiber)
		END Park;

		PROCEDURE Yield*;
		BEGIN Wake; Park END Yield;
	END Activity;

	BodyActivity = OBJECT(Activity)
	VAR body: Objects.ActivityBody; returned: BOOLEAN;
		PROCEDURE Run*;
		BEGIN body(subject); returned := TRUE
		FINALLY IF ~returned THEN owner.Fail END
		END Run;
	END BodyActivity;

	WaitQueue = RECORD first, last: Activity END;

	Monitor = OBJECT
	VAR bound: Modules.Module; nextBound, prevGuarded, nextGuarded: Monitor; scheduler: Scheduler; holder: Activity; guards, entrants: WaitQueue;

		PROCEDURE Append(VAR q: WaitQueue; a: Activity);
		BEGIN
			IF q.last = NIL THEN q.first := a ELSE q.last.waitNext := a END;
			q.last := a
		END Append;

		(* Track only monitors that have guards waiting. Completed objects can
		   be collected while a long-lived scheduler is still running. *)
		PROCEDURE TrackGuards;
		BEGIN
			nextGuarded := scheduler.guarded;
			IF nextGuarded # NIL THEN nextGuarded.prevGuarded := SELF END;
			scheduler.guarded := SELF
		END TrackGuards;

		PROCEDURE UntrackGuards;
		BEGIN
			IF prevGuarded = NIL THEN scheduler.guarded := nextGuarded ELSE prevGuarded.nextGuarded := nextGuarded END;
			IF nextGuarded # NIL THEN nextGuarded.prevGuarded := prevGuarded END;
			prevGuarded := NIL; nextGuarded := NIL
		END UntrackGuards;

		PROCEDURE HandOff;
		VAR a, prev: Activity;
		BEGIN
			holder := NIL; prev := NIL; a := guards.first;
			WHILE a # NIL DO
				IF scheduler.failed OR a.guard(a.frame) THEN
					IF prev = NIL THEN guards.first := a.waitNext ELSE prev.waitNext := a.waitNext END;
					IF guards.last = a THEN guards.last := prev END;
					IF guards.first = NIL THEN UntrackGuards END;
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
			| 1: ASSERT(holder = a); IF scheduler.failed THEN HALT(Objects.ActivityTreeCancelled) END;
				HandOff; a.guard := cond; a.frame := frame;
				IF guards.first = NIL THEN TrackGuards END; Append(guards, a)
			| 2: ASSERT(holder = a); HandOff; RETURN
			END;
			a.Park; ASSERT(holder = a);
			(* Resume with ownership so the compiler can unwind the EXCLUSIVE block. *)
			IF (op = 1) & scheduler.failed THEN HALT(Objects.ActivityTreeCancelled) END
		END Call;
	END Monitor;

	Scheduler* = OBJECT
	VAR worker: Objects.Process; pool: ADDRESS; inboxLock, changed: ADDRESS; external: Activity; head, tail, running: Activity; live-, adopted-: SIZE; bindings, guarded: Monitor; failed-: BOOLEAN;

		PROCEDURE &Init*;
		BEGIN
			worker := Objects.CurrentProcess(); ASSERT(worker.stackScanner = NIL);
			pool := newPool(); ASSERT(pool # 0);
			Machine.Acquire(Machine.Heaps); worker.stackScanner := Scan; worker.stackLimit := Limit; Machine.Release(Machine.Heaps)
		END Init;

		PROCEDURE Limit(sp: ADDRESS): ADDRESS;
		BEGIN RETURN stackLimit(pool, sp) END Limit;

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

		PROCEDURE Fail*;
		VAR m, next: Monitor;
		BEGIN
			IF failed THEN RETURN END;
			failed := TRUE; m := guarded;
			WHILE m # NIL DO
				next := m.nextGuarded; IF m.holder = NIL THEN m.HandOff END; m := next
			END
		END Fail;

		(* The workload owns all calls to this monitor until Close. *)
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

		PROCEDURE BudgetExpired;
		BEGIN
			worker.checkpointBudget := CheckpointInterval;
			IF head # NIL THEN running.Yield END
		END BudgetExpired;

		PROCEDURE PrepareWait(): Objects.EventHandler;
		BEGIN
			IF inboxLock = 0 THEN inboxLock := Unix.NewMtx(); changed := Unix.NewCond() END;
			running.posted := FALSE; RETURN running.Post
		END PrepareWait;

		PROCEDURE WaitExternal(): BOOLEAN;
		BEGIN
			IF ~failed THEN
				running.externalNext := external; external := running; running.Park
			END;
			RETURN failed
		END WaitExternal;

		PROCEDURE PollExternal(wait: BOOLEAN);
		VAR a, next, prev: Activity;
		BEGIN
			IF external = NIL THEN RETURN END;
			Unix.MtxLock(inboxLock);
			LOOP
				prev := NIL; a := external;
				WHILE a # NIL DO
					next := a.externalNext;
					IF a.posted OR failed THEN
						IF prev = NIL THEN external := next ELSE prev.externalNext := next END;
						a.externalNext := NIL; a.Wake
					ELSE prev := a END;
					a := next
				END;
				IF ~wait OR (head # NIL) THEN EXIT END;
				Unix.CondWait(changed, inboxLock)
			END;
			Unix.MtxUnlock(inboxLock)
		END PollExternal;

		(* Command workers may sleep when the only remaining progress must come
		   from another pthread. Dispatch remains nonblocking for manual drivers. *)
		PROCEDURE Drain*;
		BEGIN
			LOOP
				IF ~Dispatch() THEN
					IF external = NIL THEN RETURN END; PollExternal(TRUE)
				END
			END
		END Drain;

		PROCEDURE Dispatch*(): BOOLEAN;
		VAR a: Activity; hostContext: ANY; done: BOOLEAN;
		BEGIN
			ASSERT((worker = Objects.CurrentProcess()) & (running = NIL));
			IF external # NIL THEN PollExternal(FALSE) END;
			a := head; IF a = NIL THEN RETURN FALSE END;
			head := a.next; IF head = NIL THEN tail := NIL END;
			a.next := NIL; a.queued := FALSE; running := a;
			hostContext := Objects.CurrentContext(); Objects.SetContext(a.context); worker.activitySelf := a.subject;
			IF a.children THEN worker.childActivity := Adopt END;
			worker.checkpointBudget := CheckpointInterval; worker.checkpointDue := BudgetExpired;
			worker.prepareWait := PrepareWait; worker.waitExternal := WaitExternal;
			done := resume(a.fiber) # 0; worker.prepareWait := NIL; worker.waitExternal := NIL;
			worker.checkpointDue := NIL; worker.childActivity := NIL;
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
			ASSERT((guarded = NIL) & (external = NIL));
			IF inboxLock # 0 THEN
				Unix.CondDestroy(changed); Unix.free(changed); Unix.MtxDestroy(inboxLock); Unix.free(inboxLock)
			END;
			WHILE bindings # NIL DO
				Objects.BindActivityMonitor(bindings.bound, bindings.Call, FALSE); bindings := bindings.nextBound
			END;
			Machine.Acquire(Machine.Heaps); worker.stackScanner := NIL; worker.stackLimit := NIL; close(pool); pool := 0; Machine.Release(Machine.Heaps)
		END Close;
	END Scheduler;

VAR library: ADDRESS;
	stackLimit: PROCEDURE {C}(pool, sp: ADDRESS): ADDRESS;
	newPool: PROCEDURE {C}(): ADDRESS;
	newFiber: PROCEDURE {C}(pool: ADDRESS; entry: PROCEDURE {C}(arg: ADDRESS); arg: ADDRESS): ADDRESS;
	resume: PROCEDURE {C}(fiber: ADDRESS): SIGNED32;
	park, drop, close: PROCEDURE {C}(handle: ADDRESS);
	roots: PROCEDURE {C}(pool, sp, bottom: ADDRESS; visit: PROCEDURE {C}(adr: ADDRESS; size: SIZE));

(* Call between bounded chunks of CPU work, outside locks and AWAIT predicates.
   A native caller or a host between dispatches has no cooperative budget. *)
PROCEDURE Checkpoint*;
BEGIN Objects.ActivityCheckpoint END Checkpoint;

PROCEDURE {C} Enter(arg: ADDRESS);
VAR a: Activity;
BEGIN a := SYSTEM.VAL(Activity,arg); a.Run END Enter;

PROCEDURE {C} Candidates(adr: ADDRESS; size: SIZE);
BEGIN Heaps.RegisterCandidates(adr, size) END Candidates;

BEGIN
	library := Glue.dlopen(ADDRESSOF("@executable_path/libA2Activities.dylib"), 2); ASSERT(library # 0);
	Unix.Dlsym(library, "activity_stack_limit", ADDRESSOF(stackLimit));
	Unix.Dlsym(library, "activity_pool", ADDRESSOF(newPool));
	Unix.Dlsym(library, "activity_new", ADDRESSOF(newFiber));
	Unix.Dlsym(library, "activity_resume", ADDRESSOF(resume));
	Unix.Dlsym(library, "activity_park", ADDRESSOF(park));
	Unix.Dlsym(library, "activity_drop", ADDRESSOF(drop));
	Unix.Dlsym(library, "activity_close", ADDRESSOF(close));
	Unix.Dlsym(library, "activity_roots", ADDRESSOF(roots))
END DarwinActivities.
