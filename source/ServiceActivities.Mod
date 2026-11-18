MODULE ServiceActivities;
(** Run a service body using an ordinary A2 active object. The caller signals
    the service to stop before joining it. Join reports a normal return. *)

TYPE
	DetachedObject* = OBJECT END DetachedObject;

	Body* = PROCEDURE {DELEGATE};

	Service* = OBJECT
	VAR body: Body; finished, returned: BOOLEAN;

		PROCEDURE &Init(run: Body);
		BEGIN body := run END Init;

		PROCEDURE Join*(): BOOLEAN;
		BEGIN {EXCLUSIVE} AWAIT(finished); RETURN returned END Join;

	BEGIN {ACTIVE}
		body(); returned := TRUE
	FINALLY
		BEGIN {EXCLUSIVE} body := NIL; finished := TRUE END
	END Service;

PROCEDURE Start*(body: Body): Service;
VAR service: Service;
BEGIN ASSERT(body # NIL); NEW(service, body); RETURN service END Start;

END ServiceActivities.
