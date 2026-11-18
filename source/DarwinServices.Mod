MODULE DarwinServices;
(** Run desktop service procedures as independent activities on a shared pthread.
    A service owns its stop protocol. Join waits until its procedure has exited. *)
IMPORT A := DarwinActivities, Objects, Modules;

TYPE
	Body* = PROCEDURE {DELEGATE};
	Service* = OBJECT(A.Activity)
	VAR body: Body; objectBody: Objects.ActivityBody; object: Objects.ActivitySelf; queuedNext: Service; finished, returned: BOOLEAN;
		PROCEDURE Complete;
		BEGIN {EXCLUSIVE} body := NIL; objectBody := NIL; object := NIL; finished := TRUE END Complete;
		PROCEDURE Join*(): BOOLEAN;
		BEGIN {EXCLUSIVE} AWAIT(finished); RETURN returned END Join;
		PROCEDURE Run*;
		BEGIN IF objectBody # NIL THEN objectBody(object) ELSE body() END; returned := TRUE
		FINALLY Complete; broker.Done
		END Run;
	END Service;

	HostEntry = POINTER TO RECORD process: Objects.Process; next: HostEntry END;

	Broker = OBJECT
	VAR first, last: Service; live: SIZE; running: BOOLEAN; hosts: HostEntry;
		PROCEDURE Reap;
		VAR entry, previous: HostEntry;
		BEGIN
			entry := hosts;
			WHILE entry # NIL DO
				IF (entry.process # NIL) & (entry.process.mode = Objects.Terminated) THEN
					IF previous = NIL THEN hosts := entry.next ELSE previous.next := entry.next END
				ELSE previous := entry END;
				entry := entry.next
			END
		END Reap;
		PROCEDURE Active(): BOOLEAN;
		BEGIN {EXCLUSIVE} Reap; RETURN hosts # NIL END Active;
		PROCEDURE Attach(entry: HostEntry);
		BEGIN {EXCLUSIVE} entry.process := Objects.CurrentProcess() END Attach;
		PROCEDURE Put(service: Service);
		VAR host: Host; entry: HostEntry; p: Objects.Process; children, one: Objects.ActivityStart;
		BEGIN {EXCLUSIVE}
			IF last = NIL THEN first := service ELSE last.queuedNext := service END;
			last := service; INC(live);
			IF ~running THEN
				Reap; NEW(entry); entry.next := hosts; hosts := entry;
				running := TRUE; p := Objects.CurrentProcess();
				children := p.childActivity; one := p.nextActivity;
				p.childActivity := NIL; p.nextActivity := NIL; NEW(host, entry);
				p.childActivity := children; p.nextActivity := one
			END
		END Put;
		PROCEDURE Take(): Service;
		VAR service: Service;
		BEGIN {EXCLUSIVE}
			AWAIT((first # NIL) OR (live = 0));
			service := first;
			IF service = NIL THEN running := FALSE
			ELSE first := service.queuedNext; service.queuedNext := NIL; IF first = NIL THEN last := NIL END
			END;
			RETURN service
		END Take;
		PROCEDURE Done;
		BEGIN {EXCLUSIVE} DEC(live) END Done;
	END Broker;

	Dispatcher = OBJECT(A.Activity)
	VAR scheduler: A.Scheduler;
		PROCEDURE Run*;
		VAR service: Service;
		BEGIN
			LOOP service := broker.Take(); IF service = NIL THEN EXIT END; scheduler.StartObject(service, service.object) END
		END Run;
	END Dispatcher;

	Host = OBJECT
	VAR scheduler: A.Scheduler; dispatcher: Dispatcher; entry: HostEntry;
		PROCEDURE &Init(e: HostEntry); BEGIN entry := e END Init;
	BEGIN {ACTIVE}
		broker.Attach(entry); NEW(scheduler); NEW(dispatcher); dispatcher.scheduler := scheduler;
		scheduler.Start(dispatcher); scheduler.Drain; scheduler.Close
	END Host;

VAR broker: Broker;

PROCEDURE Start*(body: Body): Service;
VAR service: Service;
BEGIN
	ASSERT(body # NIL); NEW(service); service.body := body; broker.Put(service); RETURN service
END Start;

PROCEDURE StartObject*(body: Objects.ActivityBody; obj: Objects.ActivitySelf);
VAR service: Service;
BEGIN NEW(service); service.objectBody := body; service.object := obj; broker.Put(service) END StartObject;

PROCEDURE Cleanup;
BEGIN WHILE broker.Active() DO Objects.Sleep(1) END END Cleanup;

BEGIN NEW(broker); Modules.InstallTermHandler(Cleanup)
END DarwinServices.
