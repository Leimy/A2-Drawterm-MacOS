MODULE DrawtermDisplay;

(** Linear A2 framebuffer exported through drawterm's /dev/draw protocol. *)

IMPORT S := SYSTEM, Displays, Drawterm9P := Drawterm9PMux, KernelLog;

CONST
	ControlFid = 2;
	DataFid = 3;
	ControlSize = 144;
	DrawHeaderSize = 21;

TYPE
	Display* = OBJECT(Displays.Display)
	VAR
		connection*: Drawterm9P.Connection;
		framebuffer: POINTER TO ARRAY OF CHAR;
		upload: POINTER TO ARRAY OF CHAR;
		dataFid: SIGNED32;
		screenX, screenY: SIGNED32;
		dirtyLeft, dirtyTop, dirtyRight, dirtyBottom: SIGNED32;
		ready-: BOOLEAN;
		transfers-, updates-, uploads-: SIGNED32;
		error-: ARRAY 256 OF CHAR;

		PROCEDURE &Init*(descriptor: SIGNED32);
		BEGIN
			ready := FALSE; error[0] := 0X; dataFid := DataFid;
			NEW(connection, descriptor);
			IF ~connection.Handshake() THEN Fail; RETURN END;
			IF ~AttachScreen() THEN RETURN END;
			NEW(upload, connection.msize - 23);
			dirtyLeft := 0; dirtyTop := 0; dirtyRight := width; dirtyBottom := height;
			ready := TRUE
		END Init;

		(* Opening a new draw client binds image 0 to the current host screen.
		   The old named image becomes invalid when drawterm resizes. *)
		PROCEDURE AttachScreen(): BOOLEAN;
		VAR control: ARRAY ControlSize OF CHAR; got: SIZE;
			clientId, x1, y1: SIGNED32; dataPath: ARRAY 64 OF CHAR;
		BEGIN
			IF ~connection.Walk(Drawterm9P.RootFid, ControlFid, "dev/draw/new") THEN Fail; RETURN FALSE END;
			IF ~connection.Open(ControlFid, Drawterm9P.ReadWrite) THEN Fail; RETURN FALSE END;
			IF ~connection.Read(ControlFid, 0, control, LEN(control), got) THEN Fail; RETURN FALSE END;
			IF got # LEN(control) THEN Fail; RETURN FALSE END;
			IF ~ARGB32(control) THEN SetError("drawterm screen is not a8r8g8b8"); RETURN FALSE END;
			clientId := FieldInteger(control, 0);
			screenX := FieldInteger(control, 4); screenY := FieldInteger(control, 5);
			x1 := FieldInteger(control, 6); y1 := FieldInteger(control, 7);
			IF (clientId < 0) OR (x1 <= screenX) OR (y1 <= screenY) THEN
				SetError("invalid drawterm screen control record"); RETURN FALSE
			END;
			MakeDataPath(clientId, dataPath);
			IF ~connection.Walk(Drawterm9P.RootFid, DataFid, dataPath) THEN Fail; RETURN FALSE END;
			IF ~connection.Open(DataFid, Drawterm9P.WriteOnly) THEN Fail; RETURN FALSE END;

			width := x1 - screenX; height := y1 - screenY; offscreen := 0;
			format := Displays.color8888; unit := 10000;
			NEW(framebuffer, width * height * format);
			RETURN TRUE
		END AttachScreen;

		(* Caller holds the window manager write lock across display/view resize. *)
		PROCEDURE Resize*(): BOOLEAN;
		BEGIN {EXCLUSIVE}
			ready := FALSE;
			IF ~connection.Clunk(DataFid) THEN Fail; RETURN FALSE END;
			IF ~connection.Clunk(ControlFid) THEN Fail; RETURN FALSE END;
			IF ~AttachScreen() THEN RETURN FALSE END;
			dirtyLeft := 0; dirtyTop := 0; dirtyRight := width; dirtyBottom := height;
			error[0] := 0X; ready := TRUE;
			RETURN TRUE
		END Resize;

		PROCEDURE SetError(CONST text: ARRAY OF CHAR);
		BEGIN
			COPY(text, error); ready := FALSE
		END SetError;

		PROCEDURE Fail;
		BEGIN
			connection.Error(error); ready := FALSE;
			(* A host resize can race an upload before /dev/mouse delivers r.
			   Pause uploads until that event reattaches the screen. *)
			IF error = "named image no longer valid" THEN RETURN END;
			KernelLog.String("drawterm display failed: "); KernelLog.String(error); KernelLog.Ln
		END Fail;

		PROCEDURE Dirty(left, top, right, bottom: SIGNED32);
		BEGIN
			IF left < 0 THEN left := 0 END; IF top < 0 THEN top := 0 END;
			IF right > width THEN right := width END; IF bottom > height THEN bottom := height END;
			IF (left < right) & (top < bottom) THEN
				IF dirtyLeft > dirtyRight THEN
					dirtyLeft := left; dirtyTop := top; dirtyRight := right; dirtyBottom := bottom
				ELSE
					IF left < dirtyLeft THEN dirtyLeft := left END;
					IF top < dirtyTop THEN dirtyTop := top END;
					IF right > dirtyRight THEN dirtyRight := right END;
					IF bottom > dirtyBottom THEN dirtyBottom := bottom END
				END
			END
		END Dirty;

		PROCEDURE Transfer*(VAR buf: ARRAY OF CHAR; ofs, stride, x, y, w, h: SIZE; op: INTEGER);
		VAR source, destination: ADDRESS; rowBytes, bottom: SIZE;
		BEGIN {EXCLUSIVE}
			INC(transfers);
			ASSERT((x + w <= SIZE(width)) & (y + h <= SIZE(height)));
			bottom := y + h;
			rowBytes := w * SIZE(format);
			source := ADDRESSOF(buf[ofs]);
			destination := ADDRESSOF(framebuffer[y * SIZE(width * format) + x * SIZE(format)]);
			WHILE h > 0 DO
				IF op = Displays.set THEN S.MOVE(source, destination, rowBytes)
				ELSIF op = Displays.get THEN S.MOVE(destination, source, rowBytes)
				END;
				INC(source, stride); INC(destination, width * format); DEC(h)
			END;
			IF op = Displays.set THEN
				Dirty(SIGNED32(x), SIGNED32(y), SIGNED32(x + w), SIGNED32(bottom))
			END
		END Transfer;

		PROCEDURE UploadRect(): BOOLEAN;
		VAR y, n, rows, rowBytes, screenStride, bytes, i, row: SIZE;
		BEGIN
			rowBytes := SIZE(dirtyRight - dirtyLeft) * 4;
			screenStride := SIZE(width) * 4;
			rows := (LEN(upload) - DrawHeaderSize) DIV rowBytes;
			IF rows <= 0 THEN SetError("drawterm message cannot hold one screen row"); RETURN FALSE END;
			y := dirtyTop;
			WHILE y < SIZE(dirtyBottom) DO
				n := MIN(rows, SIZE(dirtyBottom) - y); bytes := n * rowBytes;
				upload[0] := "y";
				S.PUT(ADDRESSOF(upload[1]), SIGNED32(0));
				S.PUT(ADDRESSOF(upload[5]), screenX + dirtyLeft);
				S.PUT(ADDRESSOF(upload[9]), screenY + SIGNED32(y));
				S.PUT(ADDRESSOF(upload[13]), screenX + dirtyRight);
				S.PUT(ADDRESSOF(upload[17]), screenY + SIGNED32(y + n));
				IF rowBytes = screenStride THEN
					S.MOVE(ADDRESSOF(framebuffer[y * screenStride]), ADDRESSOF(upload[DrawHeaderSize]), bytes)
				ELSE
					(* Pack the dirty columns; framebuffer rows still have full-screen stride. *)
					FOR row := 0 TO n - 1 DO
						S.MOVE(ADDRESSOF(framebuffer[(y + row) * screenStride + SIZE(dirtyLeft) * 4]),
							ADDRESSOF(upload[DrawHeaderSize + row * rowBytes]), rowBytes)
					END
				END;
				(* A2's framebuffer alpha is unused; drawterm's screen is opaque. *)
				i := DrawHeaderSize + 3;
				WHILE i < DrawHeaderSize + bytes DO upload[i] := 0FFX; INC(i, 4) END;
				IF ~connection.Write(dataFid, 0, upload^, 0, DrawHeaderSize + bytes) THEN
					Fail; RETURN FALSE
				END;
				INC(uploads); INC(y, n)
			END;
			RETURN TRUE
		END UploadRect;

		PROCEDURE Update*;
		VAR flush: ARRAY 1 OF CHAR;
		BEGIN {EXCLUSIVE}
			INC(updates);
			IF ready & (dirtyLeft <= dirtyRight) THEN
				IF UploadRect() THEN
					flush[0] := "v";
					IF connection.Write(dataFid, 0, flush, 0, 1) THEN
						IF updates = 1 THEN KernelLog.String("drawterm full frame acknowledged"); KernelLog.Ln END;
						dirtyLeft := 1; dirtyTop := 1; dirtyRight := 0; dirtyBottom := 0
					ELSE Fail
					END
				END
			END
		END Update;

		PROCEDURE Origin*(VAR x, y: SIGNED32);
		BEGIN x := screenX; y := screenY END Origin;

	END Display;

VAR display*: Display;

PROCEDURE Put32(VAR data: ARRAY OF CHAR; pos: SIZE; value: SIGNED32);
VAR bits: UNSIGNED32; i: SIZE;
BEGIN
	bits := UNSIGNED32(value);
	FOR i := 0 TO 3 DO data[pos + i] := CHR(bits MOD 256); bits := bits DIV 256 END
END Put32;

PROCEDURE FieldInteger(CONST control: ARRAY OF CHAR; field: SIZE): SIGNED32;
VAR i, limit: SIZE; value, sign: SIGNED32;
BEGIN
	i := field * 12; limit := i + 11; value := 0; sign := 1;
	WHILE (i < limit) & (control[i] = " ") DO INC(i) END;
	IF (i < limit) & (control[i] = "-") THEN sign := -1; INC(i) END;
	IF (i >= limit) OR (control[i] < "0") OR (control[i] > "9") THEN RETURN MIN(SIGNED32) END;
	WHILE (i < limit) & (control[i] >= "0") & (control[i] <= "9") DO
		value := value * 10 + ORD(control[i]) - ORD("0"); INC(i)
	END;
	RETURN sign * value
END FieldInteger;

PROCEDURE ARGB32(CONST control: ARRAY OF CHAR): BOOLEAN;
CONST Channel = "a8r8g8b8";
VAR i, start: SIZE;
BEGIN
	start := 24;
	WHILE (start < 35) & (control[start] = " ") DO INC(start) END;
	i := 0;
	WHILE Channel[i] # 0X DO
		IF (start + i >= 35) OR (control[start + i] # Channel[i]) THEN RETURN FALSE END;
		INC(i)
	END;
	RETURN TRUE
END ARGB32;

PROCEDURE MakeDataPath(id: SIGNED32; VAR path: ARRAY OF CHAR);
VAR digits: ARRAY 12 OF CHAR; suffix: ARRAY 6 OF CHAR; i, n, j: SIZE;
BEGIN
	COPY("dev/draw/", path); i := 0; WHILE path[i] # 0X DO INC(i) END;
	n := 0;
	REPEAT digits[n] := CHR(ORD("0") + id MOD 10); id := id DIV 10; INC(n) UNTIL id = 0;
	WHILE n > 0 DO DEC(n); path[i] := digits[n]; INC(i) END;
	COPY("/data", suffix); j := 0;
	WHILE suffix[j] # 0X DO path[i] := suffix[j]; INC(i); INC(j) END;
	path[i] := 0X
END MakeDataPath;

PROCEDURE TestPattern(d: Display);
VAR y, band, height, color: SIGNED32;
BEGIN
	band := 16; y := 0;
	WHILE y < d.height DO
		color := ASH((2 * y) MOD 256, 16) + ASH((255 - y MOD 256), 8) + (y MOD 256);
		height := band; IF y + height > d.height THEN height := d.height - y END;
		d.Fill(color, 0, y, d.width, height); INC(y, height)
	END;
	d.Update;
	(* A second, smaller update verifies dirty-rectangle upload after the initial frame. *)
	d.Fill(0FFFFFFH, d.width DIV 4, d.height DIV 4, d.width DIV 2, d.height DIV 2);
	d.Fill(0002040H, d.width DIV 4 + 8, d.height DIV 4 + 8,
		d.width DIV 2 - 16, d.height DIV 2 - 16);
	d.Update
END TestPattern;

PROCEDURE Install*;
VAR descriptor: SIGNED32; result: INTEGER;
BEGIN
	descriptor := Drawterm9P.EnvironmentFD();
	IF descriptor >= 0 THEN
		NEW(display, descriptor);
		IF display.ready THEN
			display.SetName("DrawtermDisplay"); display.desc := "drawterm 9P display";
			Displays.registry.Add(display, result);
			IF result = 0 THEN
				#IF ~DESKTOP THEN
					TestPattern(display)
				#END;
				KernelLog.String("drawterm display ready: "); KernelLog.Int(display.width, 0);
				KernelLog.Char("x"); KernelLog.Int(display.height, 0); KernelLog.Ln
			ELSE
				KernelLog.String("drawterm display registration failed: "); KernelLog.Int(result, 0); KernelLog.Ln
			END
		ELSE
			KernelLog.String("drawterm display failed: "); KernelLog.String(display.error); KernelLog.Ln
		END
	END
END Install;

END DrawtermDisplay.
