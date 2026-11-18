MODULE DarwinDesktopServiceProbe;
IMPORT Commands, Events, DarwinServices, Objects, Unix, Kernel;

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

PROCEDURE Run*(context: Commands.Context);
VAR probe: Probe; timer: DarwinServices.Service;
BEGIN
	NEW(probe); probe.caller := Unix.ThrThis(); Events.Register(probe);
	timer := DarwinServices.Start(probe.Timer); probe.WaitStarted;
	Events.AddEvent("ActivityProbe", Events.Information, 0, 0, 1, "one", FALSE);
	Events.AddEvent("ActivityProbe", Events.Information, 0, 0, 2, "two", FALSE);
	probe.WaitDelivered; ASSERT(timer.Join());
	Events.Unregister(probe);
	context.out.String("PASS native producer and lightweight event dispatcher delivered two events while a sibling slept on the same pthread"); context.out.Ln
END Run;
END DarwinDesktopServiceProbe.
