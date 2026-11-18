MODULE DarwinCommandWorkers;
(** Isolated headless runtime. ActivityCommands lists command:monitor entries
    separated by commas. A dash means the command needs no bound module.
    A bound monitor must be private to routed workloads for the duration. *)
IMPORT A := DarwinActivities, Commands, Modules, Machine, Objects;

TYPE
	Job = OBJECT(A.Activity)
	VAR nextJob: Job; monitor: Modules.Module; context: Commands.Context;
		proc: PROCEDURE(context: Commands.Context); finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN
			Objects.SetContext(context); proc(context); context.out.Update; context.error.Update
		END Run;
		PROCEDURE Complete;
		BEGIN {EXCLUSIVE} finished := TRUE END Complete;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(finished) END Join;
	END Job;

	Queue = OBJECT
	VAR first, last: Job; busy: POINTER TO ARRAY OF Modules.Module;
		PROCEDURE Eligible(): Job;
		VAR j: Job; i: SIZE;
		BEGIN
			j := first;
			WHILE j # NIL DO
				IF j.monitor = NIL THEN RETURN j END;
				i := 0;
				WHILE (i < LEN(busy)) & (busy[i] # j.monitor) DO INC(i) END;
				IF i = LEN(busy) THEN RETURN j END;
				j := j.nextJob
			END;
			RETURN NIL
		END Eligible;
		PROCEDURE Put(j: Job);
		BEGIN {EXCLUSIVE}
			IF last = NIL THEN first := j ELSE last.nextJob := j END; last := j
		END Put;
		PROCEDURE Take(id: SIZE): Job;
		VAR j, prev: Job;
		BEGIN {EXCLUSIVE}
			AWAIT(Eligible() # NIL); j := Eligible();
			IF first = j THEN first := j.nextJob
			ELSE prev := first; WHILE prev.nextJob # j DO prev := prev.nextJob END; prev.nextJob := j.nextJob END;
			IF last = j THEN last := prev END;
			j.nextJob := NIL; busy[id] := j.monitor; RETURN j
		END Take;
		PROCEDURE Release(id: SIZE);
		BEGIN {EXCLUSIVE} busy[id] := NIL END Release;
	END Queue;

	Worker = OBJECT
	VAR id: SIZE; queue: Queue;
		PROCEDURE &Init(id: SIZE; queue: Queue);
		BEGIN SELF.id := id; SELF.queue := queue END Init;
	VAR j: Job; s: A.Scheduler;
	BEGIN {ACTIVE}
		LOOP
			j := queue.Take(id); NEW(s);
			IF j.monitor # NIL THEN s.BindModule(j.monitor) END;
			s.StartTree(j);
			WHILE s.Dispatch() DO END;
			ASSERT(s.live = 0); s.Close; queue.Release(id); j.Complete; j := NIL
		END
	END Worker;

VAR queue: Queue; routes: ARRAY 1024 OF CHAR; count: SIGNED32;

PROCEDURE Lookup(CONST cmd: ARRAY OF CHAR; VAR monitor: Modules.Name): BOOLEAN;
VAR i, k: SIZE;
BEGIN
	i := 0;
	WHILE routes[i] # 0X DO
		k := 0; WHILE (cmd[k] # 0X) & (routes[i] = cmd[k]) DO INC(i); INC(k) END;
		IF (cmd[k] = 0X) & (routes[i] = ":") THEN
			INC(i); k := 0;
			WHILE (routes[i] # 0X) & (routes[i] # ",") DO
				IF k >= LEN(monitor)-1 THEN RETURN FALSE END;
				monitor[k] := routes[i]; INC(k); INC(i)
			END;
			monitor[k] := 0X; RETURN k > 0
		END;
		WHILE (routes[i] # 0X) & (routes[i] # ",") DO INC(i) END;
		IF routes[i] = "," THEN INC(i) END
	END;
	RETURN FALSE
END Lookup;

PROCEDURE Start;
VAR i: SIZE; w: Worker;
BEGIN {EXCLUSIVE}
	IF queue = NIL THEN
		NEW(queue); NEW(queue.busy, count);
		FOR i := 0 TO count-1 DO NEW(w, i, queue) END
	END
END Start;

PROCEDURE Route*(CONST cmd: ARRAY OF CHAR; context: Commands.Context; flags: SET; VAR res: INTEGER; VAR msg: ARRAY OF CHAR): BOOLEAN;
VAR j: Job; mod, name, monitor: Modules.Name; m: Modules.Module;
BEGIN
	IF ~Lookup(cmd, monitor) THEN RETURN FALSE END;
	res := Commands.CommandError;
	IF count <= 0 THEN COPY("ActivityWorkers must be a decimal integer from 1 to 64", msg); RETURN TRUE END;
	IF (Objects.CurrentProcess().checkpointDue # NIL) & (Commands.Wait IN flags) THEN
		COPY("Nested synchronous worker command unsupported", msg); RETURN TRUE
	END;
	Commands.Split(cmd, mod, name, res, msg); IF res # 0 THEN RETURN TRUE END;
	m := Modules.ThisModule(mod, res, msg); IF m = NIL THEN RETURN TRUE END;
	NEW(j); GETPROCEDURE(mod, name, j.proc);
	IF j.proc = NIL THEN res := Commands.CommandNotFound; COPY("Worker command must take a Commands.Context", msg); RETURN TRUE END;
	IF monitor # "-" THEN
		j.monitor := Modules.ThisModule(monitor, res, msg); IF j.monitor = NIL THEN RETURN TRUE END
	END;
	IF context = NIL THEN NEW(context, NIL, NIL, NIL, NIL, NIL) END; j.context := context;
	Start; queue.Put(j); res := Commands.Ok; msg := "";
	IF Commands.Wait IN flags THEN
		j.Join; res := context.result; IF res # 0 THEN COPY("Command not successful", msg) END
	END;
	RETURN TRUE
END Route;

VAR n: ARRAY 16 OF CHAR; pos: SIZE;
BEGIN
	Machine.GetConfig("ActivityCommands", routes); Machine.GetConfig("ActivityWorkers", n);
	pos := 0; count := 0;
	WHILE (n[pos] >= "0") & (n[pos] <= "9") & (count <= 64) DO
		count := count*10 + ORD(n[pos])-ORD("0"); INC(pos)
	END;
	IF (n[pos] # 0X) OR (count > 64) THEN count := 0 END;
	Commands.workerRoute := Route
END DarwinCommandWorkers.
