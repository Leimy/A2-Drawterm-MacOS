MODULE NativeBuildHello;
(** Small compile/load/run check for the native macOS toolchain. *)
IMPORT Commands;

PROCEDURE Answer*(): SIGNED32;
VAR n, sum: SIGNED32;
BEGIN
 sum := 0;
 FOR n := 1 TO 6 DO INC(sum, n) END;
 RETURN 2 * sum
END Answer;

PROCEDURE Run*(context: Commands.Context);
BEGIN
 ASSERT(Answer() = 42);
 context.out.String("Native Mac build: answer = ");
 context.out.Int(Answer(), 0); context.out.Ln
END Run;

END NativeBuildHello.
