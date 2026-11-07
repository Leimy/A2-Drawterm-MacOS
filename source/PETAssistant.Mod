MODULE PETAssistant;
(** Export the current PET text selection for a read-only host assistant. *)
IMPORT Commands, Files, Texts, TextUtilities;

CONST SelectionFile = "PETAssistant.Selection.txt";

PROCEDURE Prepare*(context: Commands.Context);
VAR text: Texts.Text; from, to: Texts.TextPosition;
    start, finish: SIZE; file: Files.File; writer: Files.Writer;
BEGIN
    IF ~Texts.GetLastSelection(text, from, to) OR (from = NIL) OR (to = NIL) THEN
        context.error.String("Select code in PET first."); context.error.Ln; RETURN
    END;
    start := MIN(from.GetPosition(), to.GetPosition());
    finish := MAX(from.GetPosition(), to.GetPosition());
    IF start = finish THEN
        context.error.String("Select at least one character in PET."); context.error.Ln; RETURN
    END;
    file := Files.New(SelectionFile);
    IF file = NIL THEN
        context.error.String("Cannot create PETAssistant.Selection.txt."); context.error.Ln; RETURN
    END;
    writer := file.NewWriter();
    text.AcquireRead;
    TextUtilities.SubTextToStream(text, start, finish - start, writer);
    text.ReleaseRead;
    writer.Update;
    IF writer.res # 0 THEN
        context.error.String("Could not write the PET selection."); context.error.Ln; RETURN
    END;
    Files.Register(file);
    context.out.String("Saved selected code to PETAssistant.Selection.txt. ");
    context.out.String("Run scripts/pet-assist.sh from the launch directory, then ");
    context.out.String("PET.Open PETAssistant.Response.txt"); context.out.Ln
END Prepare;

END PETAssistant.
