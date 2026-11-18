MODULE DarwinDesktopServiceProbe;
IMPORT Commands, Events, ServiceActivities, Objects, Unix, Kernel, Modules;

TYPE
	Probe = OBJECT(Events.Sink)
	VAR caller, worker: Unix.Thread_t; count: SIZE; started: BOOLEAN;
		PROCEDURE Handle*(event: Events.Event);
		BEGIN {EXCLUSIVE}
			IF event.originator = "ActivityProbe" THEN
				ASSERT(Objects.CurrentProcess().sleepActivity # NIL);
				ASSERT((Unix.ThrThis() = worker) & (worker # caller));
				INC(count); ASSERT(event.code = count)
			END
		END Handle;
		PROCEDURE Started;
		BEGIN {EXCLUSIVE} worker := Unix.ThrThis(); started := TRUE END Started;
		PROCEDURE WaitStarted;
		BEGIN {EXCLUSIVE} AWAIT(started) END WaitStarted;
		PROCEDURE WaitDelivered;
		BEGIN {EXCLUSIVE} AWAIT(count = 2) END WaitDelivered;
		PROCEDURE Timer;
		VAR start: SIGNED32; delivered: BOOLEAN;
		BEGIN
			Started;
			REPEAT
				start := Kernel.GetTicks(); Objects.Sleep(20);
				ASSERT(Kernel.GetTicks() - start >= 19);
				BEGIN {EXCLUSIVE} delivered := count = 2 END
			UNTIL delivered
		END Timer;
	END Probe;

TYPE
	Watcher = OBJECT(ServiceActivities.DetachedObject)
	VAR started, stop, finished: BOOLEAN; worker: Unix.Thread_t;
		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} stop := TRUE END Stop;
		PROCEDURE WaitStarted;
		BEGIN {EXCLUSIVE} AWAIT(started) END WaitStarted;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(finished) END Join;
	BEGIN {ACTIVE}
		ASSERT(Objects.ActiveObject() = SELF);
		ASSERT(Objects.CurrentProcess().sleepActivity # NIL);
		BEGIN {EXCLUSIVE} worker := Unix.ThrThis(); started := TRUE; AWAIT(stop) END;
		ASSERT(Objects.ActiveObject() = SELF)
	FINALLY
		BEGIN {EXCLUSIVE} finished := TRUE END
	END Watcher;

VAR watcher: Watcher; creator: Unix.Thread_t;

PROCEDURE OpenWatcher*(context: Commands.Context);
BEGIN
	ASSERT(Objects.CurrentProcess().childActivity # NIL);
	creator := Unix.ThrThis(); NEW(watcher); watcher.WaitStarted
END OpenWatcher;

PROCEDURE Detached*(context: Commands.Context);
VAR res: INTEGER; msg: Modules.Name;
BEGIN
	Commands.Activate("DarwinDesktopServiceProbe.OpenWatcher", NIL, {Commands.Wait}, res, msg);
	ASSERT(res = 0); ASSERT((watcher.worker # creator) & (watcher.worker # Unix.ThrThis()));
	Kernel.GC; watcher.Stop; watcher.Join; watcher := NIL;
	context.out.String("PASS detached ACTIVE survived its command tree, parked, and stopped from a native caller"); context.out.Ln
END Detached;

PROCEDURE Run*(context: Commands.Context);
VAR probe: Probe; timer: ServiceActivities.Service;
BEGIN
	NEW(probe); probe.caller := Unix.ThrThis(); Events.Register(probe);
	timer := ServiceActivities.Start(probe.Timer); probe.WaitStarted;
	Events.AddEvent("ActivityProbe", Events.Information, 0, 0, 1, "one", FALSE);
	Events.AddEvent("ActivityProbe", Events.Information, 0, 0, 2, "two", FALSE);
	probe.WaitDelivered; ASSERT(timer.Join());
	Events.Unregister(probe);
	context.out.String("PASS native producer and lightweight event dispatcher delivered two events while a sibling slept on the same pthread"); context.out.Ln
END Run;
END DarwinDesktopServiceProbe.
