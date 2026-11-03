MODULE A64ComplexRegression;
(** Compile and dynamically load native complex-number operators. *)
IMPORT Commands;

PROCEDURE Run*(context: Commands.Context);
VAR a, b, sum: COMPLEX32;
BEGIN
	RE(a) := 3; IM(a) := 4;
	RE(b) := 1; IM(b) := -2;
	sum := a + b;
	ASSERT(RE(sum) = 4);
	ASSERT(IM(sum) = 2);
	ASSERT(ABS(a) = 5);
	context.out.String("AArch64 complex operators passed"); context.out.Ln
END Run;

END A64ComplexRegression.
