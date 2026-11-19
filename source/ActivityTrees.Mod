MODULE ActivityTrees;
(** Shared implementation of the ActivityTrees library introduced by this fork. *)
IMPORT A := ActivityScheduler, Objects;

CONST MaxWorkers* = 64;

TYPE
	Body* = PROCEDURE {DELEGATE};
	Job = OBJECT(A.Activity)
	VAR tree: Tree; root: Body; body: Objects.ActivityBody; obj: Objects.ActivitySelf;
		callerContext: ANY; sibling: Job; lane: SIZE;
		PROCEDURE Run*;
		VAR returned: BOOLEAN;
		BEGIN
			returned := FALSE; INC(tree.lanes[lane].bodies); Objects.SetContext(callerContext);
			IF root # NIL THEN root() ELSE body(obj) END;
			returned := TRUE
		FINALLY tree.Done(returned)
		END Run;
	END Job;

	Lane = RECORD first, last: Job; worker: Objects.Process; bodies: SIZE END;
	Tree = OBJECT
	VAR lanes: POINTER TO ARRAY OF Lane; next, live, stopped: SIZE; failed: BOOLEAN;

		PROCEDURE Submit(j: Job);
		BEGIN {EXCLUSIVE}
			j.tree := SELF; j.lane := next; j.sharedChild := Adopt; j.callerContext := Objects.CurrentContext();
			IF lanes[next].last = NIL THEN lanes[next].first := j ELSE lanes[next].last.sibling := j END;
			lanes[next].last := j; next := (next+1) MOD LEN(lanes); INC(live)
		END Submit;

		PROCEDURE Adopt(body: Objects.ActivityBody; obj: Objects.ActivitySelf);
		VAR j: Job;
		BEGIN NEW(j); j.body := body; j.obj := obj; Submit(j) END Adopt;

		PROCEDURE Done(returned: BOOLEAN);
		BEGIN {EXCLUSIVE} IF ~returned THEN failed := TRUE END; DEC(live) END Done;

		PROCEDURE Take(id: SIZE): Job;
		VAR j: Job;
		BEGIN {EXCLUSIVE}
			AWAIT((lanes[id].first # NIL) OR (live = 0) OR failed);
			IF failed THEN RETURN NIL END;
			j := lanes[id].first;
			IF j # NIL THEN
				lanes[id].first := j.sibling; j.sibling := NIL;
				IF lanes[id].first = NIL THEN lanes[id].last := NIL END
			END;
			RETURN j
		END Take;

		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} INC(stopped) END Stop;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(stopped = LEN(lanes)) END Join;
	END Tree;

	Dispatcher = OBJECT(A.Activity)
	VAR tree: Tree; id: SIZE; scheduler: A.Scheduler;
		PROCEDURE Run*;
		VAR j: Job;
		BEGIN
			LOOP
				j := tree.Take(id); IF j = NIL THEN EXIT END;
				scheduler.StartObject(j, j.obj)
			END;
			IF tree.failed THEN scheduler.Fail END
		END Run;
	END Dispatcher;

	Host = OBJECT
	VAR d: Dispatcher;
		PROCEDURE &Init(tree: Tree; id: SIZE);
		BEGIN NEW(d); d.tree := tree; d.id := id END Init;
	BEGIN {ACTIVE}
		d.tree.lanes[d.id].worker := Objects.CurrentProcess();
		NEW(d.scheduler); d.scheduler.Start(d); d.scheduler.Drain;
		d.scheduler.Close; d.tree.Stop
	END Host;

(** From a native process, run body and join its ordinary active descendants.
    workers requests 1..MaxWorkers workers in addition to the waiting caller.
    used counts distinct workers that ran a body, including the root.
    Return TRUE on normal completion or FALSE after a body traps and the workers stop. *)
PROCEDURE Run*(body: Body; workers: SIZE; VAR used: SIZE): BOOLEAN;
VAR tree: Tree; root: Job; host: Host; i, k: SIZE; p: Objects.Process;
BEGIN
	ASSERT((workers >= 1) & (workers <= MaxWorkers) & (body # NIL));
	p := Objects.CurrentProcess(); ASSERT((p.stackScanner = NIL) & (p.nextActivity = NIL));
	NEW(tree); NEW(tree.lanes, workers); NEW(root); root.root := body; tree.Submit(root);
	FOR i := 0 TO workers-1 DO NEW(host, tree, i) END;
	tree.Join; used := 0;
	FOR i := 0 TO workers-1 DO
		IF tree.lanes[i].bodies > 0 THEN
			k := 0; WHILE (k < i) & ((tree.lanes[k].bodies = 0) OR (tree.lanes[k].worker # tree.lanes[i].worker)) DO INC(k) END;
			IF k = i THEN INC(used) END
		END
	END;
	RETURN ~tree.failed
END Run;

END ActivityTrees.
