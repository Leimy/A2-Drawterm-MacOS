MODULE NativeTrigRegression;
(** Portable inverse trigonometry, including the southern latitudes used by RadioGlobe. *)
IMPORT Commands, Math32, Math64;

PROCEDURE Run*(context: Commands.Context);
VAR i: SIGNED32; x, a, previous: FLOAT64; s: FLOAT32;
BEGIN
	ASSERT(ABS(Math64.arctan(-2) + 1.1071487177940904) < 0.000001, 101);
	ASSERT(ABS(Math32.arctan(-2) + 1.1071487) < 0.00001, 102);
	ASSERT(ABS(Math64.arctan2(-2, -1) + 2.0344439357957027) < 0.000001, 103);
	ASSERT(ABS(Math64.arctan2(2, -1) - 2.0344439357957027) < 0.000001, 104);
	previous := -Math64.pi;
	FOR i := -1000 TO 1000 DO
		x := i / 1000; a := Math64.arcsin(x);
		ASSERT((a >= -Math64.pi / 2) & (a <= Math64.pi / 2), 105);
		ASSERT(a >= previous, 106); previous := a;
		ASSERT(ABS(Math64.sin(a) - x) < 0.000001, 107);
		ASSERT(ABS(a + Math64.arcsin(-x)) < 0.000001, 108);
		s := SHORT(x);
		ASSERT(ABS(Math32.sin(Math32.arcsin(s)) - s) < 0.00001, 109)
	END;
	context.out.String("Portable inverse trigonometry passed (2001 latitudes, both precisions)"); context.out.Ln
END Run;
END NativeTrigRegression.
