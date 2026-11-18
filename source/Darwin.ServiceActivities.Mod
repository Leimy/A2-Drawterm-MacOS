MODULE ServiceActivities;
(** The lightweight desktop selects this implementation in its build recipe. *)
IMPORT DarwinServices, Objects;

TYPE
	DetachedObject* = OBJECT(Objects.DetachedObject)
		PROCEDURE ScheduleBody*(body: Objects.ActivityBody; self: Objects.ActivitySelf);
		BEGIN DarwinServices.StartObject(body, self) END ScheduleBody;
	END DetachedObject;

	Body* = PROCEDURE {DELEGATE};

	Service* = OBJECT
	VAR activity: DarwinServices.Service;

		PROCEDURE Join*(): BOOLEAN;
		BEGIN RETURN activity.Join() END Join;
	END Service;

PROCEDURE Start*(body: Body): Service;
VAR service: Service;
BEGIN NEW(service); service.activity := DarwinServices.Start(body); RETURN service END Start;

END ServiceActivities.
