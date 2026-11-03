MODULE DrawtermClipboard;

(** Host clipboard bridge over drawterm's /dev/snarf 9P file. *)

IMPORT Drawterm9PMux, DrawtermDisplay, HostClipboard, Texts, TextUtilities, Strings, KernelLog;

CONST ClipboardFid = 7; MaxClipboard = 8192; Chunk = 2048;

VAR connection: Drawterm9PMux.Connection; installed: BOOLEAN;

PROCEDURE GetFromClipboard(text: Texts.Text);
VAR data: ARRAY MaxClipboard + 1 OF CHAR; block: ARRAY Chunk OF CHAR;
	pos, got, i, count: SIZE; opened, ok: BOOLEAN;
BEGIN {EXCLUSIVE}
	IF connection = NIL THEN RETURN END;
	opened := connection.Walk(Drawterm9PMux.RootFid, ClipboardFid, "dev/snarf") &
		connection.Open(ClipboardFid, Drawterm9PMux.ReadOnly);
	IF ~opened THEN RETURN END;
	pos := 0; ok := TRUE;
	LOOP
		count := MaxClipboard - pos;
		IF count > Chunk THEN count := Chunk END;
		IF count = 0 THEN EXIT END;
		ok := connection.Read(ClipboardFid, UNSIGNED64(pos), block, count, got);
		IF ok THEN
			FOR i := 0 TO got - 1 DO data[pos + i] := block[i] END;
			INC(pos, got)
		END;
		IF ~ok OR (got = 0) THEN EXIT END
	END;
	IF ~connection.Clunk(ClipboardFid) THEN ok := FALSE END;
	IF ok & (pos > 0) THEN
		data[pos] := 0X;
		TextUtilities.StrToText(text, text.GetLength(), data)
	END
END GetFromClipboard;

PROCEDURE PutToClipboard(text: Texts.Text);
VAR data: ARRAY MaxClipboard OF CHAR; count: SIZE; opened: BOOLEAN;
BEGIN {EXCLUSIVE}
	IF connection = NIL THEN RETURN END;
	TextUtilities.TextToStr(text, data);
	count := Strings.Length(data);
	opened := connection.Walk(Drawterm9PMux.RootFid, ClipboardFid, "dev/snarf") &
		connection.Open(ClipboardFid, Drawterm9PMux.WriteOnly);
	IF opened THEN
		IF count > 0 THEN IGNORE connection.Write(ClipboardFid, 0, data, 0, count) END;
		IGNORE connection.Clunk(ClipboardFid)
	END
END PutToClipboard;

PROCEDURE ClipboardChanged(sender, data: ANY);
BEGIN
	Texts.clipboard.AcquireRead;
	PutToClipboard(Texts.clipboard);
	Texts.clipboard.ReleaseRead
END ClipboardChanged;

PROCEDURE Install*;
BEGIN
	IF ~installed & (DrawtermDisplay.display # NIL) & DrawtermDisplay.display.ready THEN
		connection := DrawtermDisplay.display.connection;
		IF connection.Walk(Drawterm9PMux.RootFid, ClipboardFid, "dev/snarf") THEN
			IGNORE connection.Clunk(ClipboardFid);
			HostClipboard.SetHandlers(GetFromClipboard, PutToClipboard);
			Texts.clipboard.onTextChanged.Add(ClipboardChanged);
			installed := TRUE;
			KernelLog.String("drawterm clipboard ready"); KernelLog.Ln
		END
	END
END Install;

END DrawtermClipboard.
