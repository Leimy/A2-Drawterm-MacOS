MODULE NativeReleaseUnload;
IMPORT Modules, Heaps;
VAR called: BOOLEAN; values: POINTER TO ARRAY OF SIGNED32;
PROCEDURE Run*;
BEGIN
	ASSERT(~called); called := TRUE; NEW(values, 1024); values[1023] := 123456;
	Heaps.InvokeGC; ASSERT(values[1023] = 123456)
END Run;
PROCEDURE Cleanup;
BEGIN ASSERT(called); ASSERT(values[1023] = 123456) END Cleanup;
BEGIN Modules.InstallTermHandler(Cleanup)
END NativeReleaseUnload.
