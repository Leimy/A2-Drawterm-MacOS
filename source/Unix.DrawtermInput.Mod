MODULE DrawtermInput;

(** Mouse and keyboard input from drawterm's direct 9P export. *)

IMPORT Inputs, Drawterm9PMux, DrawtermDisplay, KernelLog;

CONST MouseFid = 4; KeyboardFid = 5; CursorFid = 6;
	TraceInput = FALSE;

TYPE
	MouseReader = OBJECT
	VAR connection: Drawterm9PMux.Connection; originX, originY: SIGNED32; oldButtons: SIGNED32;

		PROCEDURE &Init*(connection: Drawterm9PMux.Connection; x, y: SIGNED32);
		BEGIN SELF.connection := connection; originX := x; originY := y; oldButtons := -1 END Init;

		PROCEDURE Run;
		VAR data: ARRAY 49 OF CHAR; got: SIZE; x, y, buttons, dz: SIGNED32; msg: Inputs.AbsMouseMsg;
		BEGIN
		LOOP
			IF ~connection.Read(MouseFid, 0, data, LEN(data), got) THEN EXIT END;
			IF (got = LEN(data)) & ((data[0] = "m") OR (data[0] = "r")) THEN
				IF (data[0] = "r") & (resizeHandler # NIL) THEN resizeHandler END;
				DrawtermDisplay.display.Origin(originX, originY);
				x := Field(data, 0) - originX; y := Field(data, 1) - originY; buttons := Field(data, 2);
				msg.keys := {}; IF buttons MOD 2 = 1 THEN INCL(msg.keys, 0) END;
				IF buttons DIV 2 MOD 2 = 1 THEN INCL(msg.keys, 1) END;
				IF buttons DIV 4 MOD 2 = 1 THEN INCL(msg.keys, 2) END;
				dz := 0; IF buttons DIV 8 MOD 2 = 1 THEN dz := -1 END;
				IF buttons DIV 16 MOD 2 = 1 THEN dz := 1 END;
				msg.x := x; msg.y := y; msg.z := 0; msg.dx := 0; msg.dy := 0; msg.dz := dz;
				Inputs.mouse.Handle(msg);
				IF TraceInput & (buttons # oldButtons) THEN
					KernelLog.String("drawterm mouse: "); KernelLog.Int(x, 0); KernelLog.Char(",");
					KernelLog.Int(y, 0); KernelLog.String(" buttons="); KernelLog.Int(buttons, 0); KernelLog.Ln;
				END;
				oldButtons := buttons
			END
		END
		END Run;

	BEGIN {ACTIVE}
		Run
	END MouseReader;

	KeyboardReader = OBJECT
	VAR connection: Drawterm9PMux.Connection; modifiers: SET; record: ARRAY 8 OF CHAR; used: SIZE;

		PROCEDURE &Init*(connection: Drawterm9PMux.Connection);
		BEGIN SELF.connection := connection; modifiers := {}; used := 0 END Init;

		PROCEDURE Event;
		VAR down: BOOLEAN; pos: SIZE; rune: UNSIGNED32; msg: Inputs.KeyboardMsg; bit: SIGNED32;
		BEGIN
			IF used < 2 THEN RETURN END; down := record[0] = "r"; pos := 1;
			IF ~Decode(record, pos, rune) THEN RETURN END;
			bit := Modifier(rune);
			IF bit >= 0 THEN
				IF down THEN INCL(modifiers, bit) ELSE EXCL(modifiers, bit) END
			END;
			msg.flags := modifiers; IF ~down THEN INCL(msg.flags, Inputs.Release) END;
			msg.keysym := KeySym(rune); msg.ch := 0X;
			IF down & (rune > 0) & (rune < 100H) & (bit < 0) THEN msg.ch := CHR(rune) END;
			Inputs.keyboard.Handle(msg);
			IF TraceInput & down THEN KernelLog.String("drawterm key down: "); KernelLog.Hex(rune, 0); KernelLog.Ln END
		END Event;

		PROCEDURE Consume(ch: CHAR);
		BEGIN
			IF ch = 0X THEN Event; used := 0
			ELSIF used < LEN(record) THEN record[used] := ch; INC(used)
			ELSE used := 0
			END
		END Consume;

		PROCEDURE Run;
		VAR data: ARRAY 128 OF CHAR; got, i: SIZE;
		BEGIN
		LOOP
			IF ~connection.Read(KeyboardFid, 0, data, LEN(data), got) THEN EXIT END;
			IF got > 0 THEN FOR i := 0 TO got - 1 DO Consume(data[i]) END END
		END
		END Run;

	BEGIN {ACTIVE}
		Run
	END KeyboardReader;

VAR resizeHandler*: PROCEDURE; mouse: MouseReader; keyboard: KeyboardReader; recordError: ARRAY 256 OF CHAR;

PROCEDURE HideHostCursor(c: Drawterm9PMux.Connection);
VAR cursor: ARRAY 72 OF CHAR; i: SIZE; opened, hidden: BOOLEAN;
BEGIN
	(* /dev/cursor is two big-endian hotspot coordinates followed by 32-byte
	   clear and set masks. All zero masks make drawterm's native cursor blank,
	   leaving A2's own cursor as the sole visible pointer. *)
	FOR i := 0 TO LEN(cursor) - 1 DO cursor[i] := 0X END;
	opened := c.Walk(Drawterm9PMux.RootFid, CursorFid, "dev/cursor") &
		c.Open(CursorFid, Drawterm9PMux.WriteOnly);
	IF opened THEN
		hidden := c.Write(CursorFid, 0, cursor, 0, LEN(cursor));
		IF ~c.Clunk(CursorFid) THEN hidden := FALSE END;
		IF hidden THEN KernelLog.String("drawterm host cursor hidden"); KernelLog.Ln END
	END
END HideHostCursor;

PROCEDURE Field(CONST data: ARRAY OF CHAR; number: SIZE): SIGNED32;
VAR i, limit: SIZE; value, sign: SIGNED32;
BEGIN
	i := 1 + number * 12; limit := i + 11; value := 0; sign := 1;
	WHILE (i < limit) & (data[i] = " ") DO INC(i) END;
	IF (i < limit) & (data[i] = "-") THEN sign := -1; INC(i) END;
	WHILE (i < limit) & (data[i] >= "0") & (data[i] <= "9") DO
		value := value * 10 + ORD(data[i]) - ORD("0"); INC(i)
	END; RETURN sign * value
END Field;

PROCEDURE Decode(CONST data: ARRAY OF CHAR; VAR pos: SIZE; VAR rune: UNSIGNED32): BOOLEAN;
VAR first, next, count: SIGNED32;
BEGIN
	IF pos >= LEN(data) THEN RETURN FALSE END; first := ORD(data[pos]); INC(pos);
	IF first < 80H THEN rune := UNSIGNED32(first); RETURN TRUE
	ELSIF first DIV 20H = 6 THEN rune := UNSIGNED32(first MOD 20H); count := 1
	ELSIF first DIV 10H = 0EH THEN rune := UNSIGNED32(first MOD 10H); count := 2
	ELSIF first DIV 8 = 1EH THEN rune := UNSIGNED32(first MOD 8); count := 3
	ELSE RETURN FALSE
	END;
	WHILE count > 0 DO
		IF pos >= LEN(data) THEN RETURN FALSE END; next := ORD(data[pos]); INC(pos);
		IF next DIV 40H # 2 THEN RETURN FALSE END; rune := rune * 40H + UNSIGNED32(next MOD 40H); DEC(count)
	END; RETURN TRUE
END Decode;

PROCEDURE Modifier(rune: UNSIGNED32): SIGNED32;
BEGIN
	CASE rune OF
	| 0F016H: RETURN Inputs.LeftShift
	| 0F017H: RETURN Inputs.LeftCtrl
	| 0F015H: RETURN Inputs.LeftAlt
	| 0F868H: RETURN Inputs.LeftMeta
	ELSE RETURN -1
	END
END Modifier;

PROCEDURE KeySym(rune: UNSIGNED32): SIGNED32;
BEGIN
	CASE rune OF
	| 08H: RETURN Inputs.KsBackSpace | 09H: RETURN Inputs.KsTab
	| 0AH, 0DH: RETURN Inputs.KsReturn | 01BH: RETURN Inputs.KsEscape | 07FH: RETURN Inputs.KsDelete
	| 0F00DH: RETURN Inputs.KsHome | 0F00EH: RETURN Inputs.KsUp | 0F800H: RETURN Inputs.KsDown
	| 0F011H: RETURN Inputs.KsLeft | 0F012H: RETURN Inputs.KsRight
	| 0F00FH: RETURN Inputs.KsPageUp | 0F013H: RETURN Inputs.KsPageDown
	| 0F014H: RETURN Inputs.KsInsert | 0F018H: RETURN Inputs.KsEnd
	| 0F016H: RETURN Inputs.KsShiftL | 0F017H: RETURN Inputs.KsControlL
	| 0F015H: RETURN Inputs.KsAltL | 0F868H: RETURN Inputs.KsMetaL
	ELSE
		IF (rune >= 0F001H) & (rune <= 0F00CH) THEN RETURN Inputs.KsF1 + SIGNED32(rune - 0F001H) END;
		RETURN SIGNED32(rune)
	END
END KeySym;

PROCEDURE Install*;
VAR x, y: SIGNED32; c: Drawterm9PMux.Connection;
BEGIN
	IF (mouse = NIL) & (DrawtermDisplay.display # NIL) & DrawtermDisplay.display.ready THEN
		c := DrawtermDisplay.display.connection;
		IF c.Walk(Drawterm9PMux.RootFid, MouseFid, "dev/mouse") & c.Open(MouseFid, Drawterm9PMux.ReadOnly) &
			c.Walk(Drawterm9PMux.RootFid, KeyboardFid, "dev/kbd") & c.Open(KeyboardFid, Drawterm9PMux.ReadOnly) THEN
			DrawtermDisplay.display.Origin(x, y); NEW(mouse, c, x, y); NEW(keyboard, c);
			Inputs.main.SetLimits(DrawtermDisplay.display.width - 1, DrawtermDisplay.display.height - 1, 0);
			HideHostCursor(c);
			KernelLog.String("drawterm input ready"); KernelLog.Ln
		ELSE
			KernelLog.String("drawterm input failed: "); c.Error(recordError); KernelLog.String(recordError); KernelLog.Ln
		END
	END
END Install;

END DrawtermInput.
