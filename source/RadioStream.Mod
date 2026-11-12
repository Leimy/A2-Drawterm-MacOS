MODULE RadioStream;

IMPORT Glue, Unix, Streams, Strings, KernelLog;

TYPE Source* = OBJECT
VAR handle: ADDRESS; stopped: BOOLEAN;
	raw: Streams.Reader; interval, remaining: SIGNED32;
	reader*: Streams.Reader;
	title: ARRAY 4081 OF CHAR;

	PROCEDURE Open*(CONST url: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		IF ~Bind() THEN RETURN FALSE END;
		BEGIN {EXCLUSIVE}
			IF stopped OR (handle # 0) THEN RETURN FALSE END;
			handle := Create(ADDRESSOF(url));
			IF handle = 0 THEN RETURN FALSE END
		END;
		interval := MetaInterval(handle);
		IF interval < 0 THEN RETURN FALSE END;
		IF Prefill(handle) <= 0 THEN RETURN FALSE END;
		remaining := interval;
		Streams.OpenReader(raw, ReceiveRaw);
		Streams.OpenReader(reader, ReceiveAudio);
		RETURN TRUE
	END Open;

	PROCEDURE ReceiveRaw(VAR buf: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
	VAR n: SIGNED32;
	BEGIN
		len := 0; res := Streams.Ok;
		IF min = 0 THEN RETURN END;
		n := Read(handle, ADDRESSOF(buf[ofs]), SIGNED32(size));
		IF n > 0 THEN len := n ELSE
			res := Streams.EOF;
			IF n < 0 THEN KernelLog.String("Radio transport disconnected with an error"); KernelLog.Ln END
		END
	END ReceiveRaw;

	PROCEDURE Metadata;
	VAR length: CHAR; data, nextTitle: ARRAY 4081 OF CHAR; n, got, start, finish, i: SIZE; changed: BOOLEAN;
	BEGIN
		raw.Char(length);
		IF raw.res # Streams.Ok THEN RETURN END;
		n := ORD(length) * 16;
		IF n > 0 THEN
			raw.Bytes(data, 0, n, got);
			IF got # n THEN
				KernelLog.String("Truncated ICY metadata"); KernelLog.Ln; RETURN
			END;
			data[n] := 0X;
			start := Strings.Pos("StreamTitle='", data);
			IF start >= 0 THEN
				INC(start, 13); finish := start;
				WHILE (finish < n) & (data[finish] # 0X) &
					~((data[finish] = "'") & (data[finish + 1] = ";")) DO INC(finish) END;
				Strings.Copy(data, start, finish - start, nextTitle);
				FOR i := 0 TO finish - start - 1 DO
					IF (nextTitle[i] < 20X) OR (nextTitle[i] = 7FX) THEN nextTitle[i] := " " END
				END;
				BEGIN {EXCLUSIVE} changed := title # nextTitle; title := nextTitle END;
				IF changed THEN KernelLog.String("Radio title: "); KernelLog.String(nextTitle); KernelLog.Ln END
			END
		END;
		remaining := interval
	END Metadata;

	PROCEDURE ReceiveAudio(VAR buf: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
	VAR n, got: SIZE;
	BEGIN
		len := 0; res := Streams.Ok;
		IF min = 0 THEN RETURN END;
		LOOP
			IF (interval > 0) & (remaining = 0) THEN Metadata END;
			IF raw.res # Streams.Ok THEN res := Streams.EOF; EXIT END;
			n := size - len;
			IF (interval > 0) & (n > remaining) THEN n := remaining END;
			raw.Bytes(buf, ofs + len, n, got); INC(len, got);
			IF interval > 0 THEN DEC(remaining, SIGNED32(got)) END;
			IF (len >= min) OR (raw.res # Streams.Ok) THEN
				IF len = 0 THEN res := Streams.EOF END;
				EXIT
			END
		END
	END ReceiveAudio;

	PROCEDURE GetTitle*(VAR text: ARRAY OF CHAR);
	BEGIN {EXCLUSIVE} COPY(title, text) END GetTitle;

	PROCEDURE Close*;
	BEGIN {EXCLUSIVE}
		stopped := TRUE; IF handle # 0 THEN Cancel(handle) END
	END Close;

	PROCEDURE Release*;
	VAR h: ADDRESS;
	BEGIN
		Close;
		BEGIN {EXCLUSIVE} h := handle; handle := 0 END;
		IF h # 0 THEN Destroy(h) END
	END Release;
END Source;

VAR library: ADDRESS;
	Create: PROCEDURE {C}(url: ADDRESS): ADDRESS;
	MetaInterval: PROCEDURE {C}(handle: ADDRESS): SIGNED32;
	Prefill: PROCEDURE {C}(handle: ADDRESS): SIGNED32;
	Read: PROCEDURE {C}(handle, data: ADDRESS; len: SIGNED32): SIGNED32;
	Cancel, Destroy: PROCEDURE {C}(handle: ADDRESS);

PROCEDURE Bind(): BOOLEAN;
BEGIN {EXCLUSIVE}
	IF library # 0 THEN RETURN TRUE END;
	library := Glue.dlopen(ADDRESSOF("@executable_path/libA2Radio.dylib"), 2);
	IF library = 0 THEN KernelLog.String("libA2Radio.dylib not found beside OberonLoader"); KernelLog.Ln; RETURN FALSE END;
	Unix.Dlsym(library, "a2radio_create", ADDRESSOF(Create));
	Unix.Dlsym(library, "a2radio_interval", ADDRESSOF(MetaInterval));
	Unix.Dlsym(library, "a2radio_prefill", ADDRESSOF(Prefill));
	Unix.Dlsym(library, "a2radio_read", ADDRESSOF(Read));
	Unix.Dlsym(library, "a2radio_cancel", ADDRESSOF(Cancel));
	Unix.Dlsym(library, "a2radio_destroy", ADDRESSOF(Destroy));
	ASSERT((Create # NIL) & (MetaInterval # NIL) & (Prefill # NIL) & (Read # NIL) & (Cancel # NIL) & (Destroy # NIL));
	RETURN TRUE
END Bind;

END RadioStream.
