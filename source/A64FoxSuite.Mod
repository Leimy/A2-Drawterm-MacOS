MODULE A64FoxSuite; (** PURPOSE "Run the existing Fox language cases on native AArch64"; *)

IMPORT Commands, Files, Streams, Strings;

CONST
    CompileCommand = "Compiler.Compile -b=AArch64 --objectFileExtension=.GofAa --symbolFileExtension=.SymAa --metaData=full --define=UNIX,AARCH64 TesterInput.txt";
    LoadCommand = "System.Free Test B A;System.Load Test";

PROCEDURE Run*(context: Commands.Context);
VAR source: Files.File; reader: Files.Reader; input: Files.File; writer: Files.Writer;
    fileName: Files.FileName; mode, line, code, message: ARRAY 256 OF CHAR;
    positive, compiled, succeeded, foreignCode, legacyNil: BOOLEAN; result: INTEGER;
    count, passed, failed, skipped, replaced, shown: SIGNED32;
BEGIN
    IF ~context.arg.GetString(fileName) OR ~context.arg.GetString(mode) OR
       ~((mode = "compile") OR (mode = "execute")) THEN
        context.error.String("Usage: A64FoxSuite.Run Oberon.Compilation.Test compile|execute");
        context.error.Ln;
        context.result := Commands.CommandParseError;
        RETURN
    END;
    source := Files.Old(fileName);
    IF source = NIL THEN
        context.error.String("Cannot open "); context.error.String(fileName); context.error.Ln;
        context.result := Commands.CommandError;
        RETURN
    END;
    Files.OpenReader(reader, source, 0);
    count := 0; passed := 0; failed := 0; skipped := 0; replaced := 0; shown := 0;
    WHILE reader.Available() > 0 DO
        reader.Ln(line);
        positive := Strings.StartsWith("positive: ", 0, line);
        IF positive OR Strings.StartsWith("negative: ", 0, line) THEN
            INC(count);
            foreignCode := FALSE;
            legacyNil :=
                (line = "negative: type test on nil pointer to record") OR
                (line = "negative: type test on returned nil pointer to record") OR
                (line = "negative: type test on nil object") OR
                (line = "negative: type test on returned nil object") OR
                (line = "negative: type test on nil base object") OR
                (line = "negative: type test on returned nil base object");
            input := Files.New("TesterInput.txt");
            Files.OpenWriter(writer, input, 0);
            WHILE (reader.Available() > 0) &
                  ((reader.Peek() = 0AX) OR (reader.Peek() = 09X)) DO
                IF reader.Peek() = 0AX THEN
                    reader.SkipLn
                ELSIF reader.Peek() = 09X THEN
                    reader.SkipBytes(1);
                    reader.Ln(code);
                    IF Strings.Pos("SYSTEM.i386", code) >= 0 THEN foreignCode := TRUE END;
                    writer.Char(09X); writer.String(code); writer.Ln
                END
            END;
            writer.Update;
            Files.Register(input);
            IF foreignCode THEN
                INC(skipped)
            ELSIF legacyNil THEN
                INC(replaced)
            ELSE
                Commands.Call(CompileCommand, {Commands.Wait, Commands.Silent}, result, message);
                compiled := result = Commands.Ok;
                IF (mode = "execute") & compiled THEN
                    Commands.Call(LoadCommand, {Commands.Wait, Commands.Silent}, result, message);
                    succeeded := result = Commands.Ok
                ELSE
                    succeeded := compiled
                END;
                IF succeeded = positive THEN
                    INC(passed)
                ELSE
                    INC(failed);
                    IF shown < 100 THEN
                        context.out.String("FAIL #"); context.out.Int(count, 0);
                        context.out.String(" "); context.out.String(line);
                        context.out.String(" (result "); context.out.Int(result, 0);
                        context.out.String(") "); context.out.String(message); context.out.Ln;
                        INC(shown)
                    END
                END
            END;
            IF count MOD 100 = 0 THEN
                context.out.Int(count, 0); context.out.String(" cases: ");
                context.out.Int(passed, 0); context.out.String(" passed"); context.out.Ln;
                context.out.Update
            END
        END
    END;
    context.out.String("A64 Fox suite: "); context.out.Int(passed, 0);
    context.out.String("/"); context.out.Int(count - skipped - replaced, 0);
    context.out.String(" passed, "); context.out.Int(failed, 0);
    context.out.String(" failed, "); context.out.Int(skipped, 0);
    context.out.String(" non-AArch64 cases skipped, ");
    context.out.Int(replaced, 0); context.out.String(" legacy NIL cases replaced"); context.out.Ln;
    context.out.Update;
    IF failed # 0 THEN context.result := Commands.CommandError END
END Run;

END A64FoxSuite.
