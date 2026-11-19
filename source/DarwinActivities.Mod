MODULE DarwinActivities;
(** Compatibility for clients of the original Darwin scheduler. *)
IMPORT A := ActivityScheduler;
CONST CheckpointInterval* = A.CheckpointInterval;
TYPE Activity* = A.Activity; Scheduler* = A.Scheduler;
PROCEDURE AwaitReadable*(fd: SIGNED32): BOOLEAN;
BEGIN RETURN A.AwaitReadable(fd) END AwaitReadable;
PROCEDURE Checkpoint*;
BEGIN A.Checkpoint END Checkpoint;
END DarwinActivities.
