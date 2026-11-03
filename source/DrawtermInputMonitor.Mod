MODULE DrawtermInputMonitor;

(** Visible proof that drawterm input is being delivered through A2 Inputs. *)

IMPORT Inputs, DrawtermDisplay, KernelLog;

TYPE
	MouseMonitor = OBJECT(Inputs.Sink)
	VAR oldKeys: SET;

		PROCEDURE Handle*(VAR message: Inputs.Message);
		VAR size, color, x, y: SIGNED32;
		BEGIN {EXCLUSIVE}
			IF (DrawtermDisplay.display # NIL) & DrawtermDisplay.display.ready THEN
				WITH message: Inputs.AbsMouseMsg DO
					IF message.keys = oldKeys THEN RETURN END;
					x := message.x; y := message.y; size := 9; color := 00E0FFFFH;
					IF message.keys # {} THEN size := 25; color := 00FF5030H END;
					IF x < size DIV 2 THEN x := size DIV 2 END;
					IF y < size DIV 2 THEN y := size DIV 2 END;
					IF x >= DrawtermDisplay.display.width - size DIV 2 THEN x := DrawtermDisplay.display.width - size DIV 2 - 1 END;
					IF y >= DrawtermDisplay.display.height - size DIV 2 THEN y := DrawtermDisplay.display.height - size DIV 2 - 1 END;
					DrawtermDisplay.display.Fill(color, x - size DIV 2, y - size DIV 2, size, size);
					DrawtermDisplay.display.Update; oldKeys := message.keys
				END
			END
		END Handle;
	END MouseMonitor;

	KeyboardMonitor = OBJECT(Inputs.Sink)
	VAR column: SIGNED32;

		PROCEDURE Handle*(VAR message: Inputs.Message);
		VAR color, x, h: SIGNED32;
		BEGIN {EXCLUSIVE}
			WITH message: Inputs.KeyboardMsg DO
				IF ~(Inputs.Release IN message.flags) & (DrawtermDisplay.display # NIL) & DrawtermDisplay.display.ready THEN
					x := 12 + column * 14;
					IF x + 12 >= DrawtermDisplay.display.width THEN column := 0; x := 12 END;
					h := 12 + message.keysym MOD 72;
					color := 00404040H + (message.keysym * 0102041H) MOD 0BFBFBFH;
					DrawtermDisplay.display.Fill(color, x, DrawtermDisplay.display.height - h - 12, 12, h);
					DrawtermDisplay.display.Update; INC(column)
				END
			END
		END Handle;
	END KeyboardMonitor;

VAR mouse: MouseMonitor; keyboard: KeyboardMonitor;

PROCEDURE Install*;
BEGIN
	IF mouse = NIL THEN
		NEW(mouse); NEW(keyboard); Inputs.mouse.Register(mouse); Inputs.keyboard.Register(keyboard);
		KernelLog.String("drawterm visible input monitor ready"); KernelLog.Ln
	END
END Install;

END DrawtermInputMonitor.
