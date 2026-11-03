MODULE NativeClockGCRegression;
(** Exercise the macOS libc clock pointer across native GC cycles. *)
IMPORT Clock, Heaps, Commands;

PROCEDURE Run*(context: Commands.Context);
VAR i, time, date: SIGNED32;
BEGIN
	FOR i := 0 TO 255 DO
		Clock.Get(time, date);
		ASSERT(date # 0);
		IF i MOD 16 = 0 THEN Heaps.InvokeGC END
	END;
	context.out.String("Native clock/GC: 256 reads, 16 collections OK"); context.out.Ln
END Run;

END NativeClockGCRegression.
