MODULE NativeRadioDecoder;
IMPORT Glue, Unix, Streams, Codecs, SoundDevices, KernelLog;

TYPE Decoder* = OBJECT(Codecs.AudioDecoder)
VAR handle: ADDRESS; input: Streams.Reader; ended, more: BOOLEAN; error*: SIGNED32;
	block: ARRAY 4096 OF CHAR; total: SIGNED64;

	PROCEDURE Feed(): BOOLEAN;
	VAR n: SIZE; status: SIGNED32;
	BEGIN
		IF ended THEN RETURN FALSE END;
		input.Bytes(block, 0, LEN(block), n);
		IF n > 0 THEN
			status := FeedNative(handle, ADDRESSOF(block), SIGNED32(n));
			IF status # 0 THEN error := status; RETURN FALSE END
		END;
		IF input.res # Streams.Ok THEN ended := TRUE; EndNative(handle) END;
		RETURN TRUE
	END Feed;

	PROCEDURE Open*(source: Streams.Reader; VAR res: INTEGER);
	VAR count: SIZE;
	BEGIN
		Close; input := source; ended := FALSE; error := 0; total := 0; res := Codecs.ResFailed;
		IF (input = NIL) OR ~Bind() THEN RETURN END;
		handle := Create(); IF handle = 0 THEN RETURN END;
		count := 0;
		WHILE (Ready(handle) = 0) & ~ended & (count < 65536) DO
			IF ~Feed() THEN RETURN END; INC(count, LEN(block))
		END;
		IF Ready(handle) = 0 THEN RETURN END;
		more := TRUE; res := Codecs.ResOk
	END Open;

	PROCEDURE HasMoreData*(): BOOLEAN;
	BEGIN RETURN more END HasMoreData;
	PROCEDURE GetAudioInfo*(VAR channels, rate, bits: SIGNED32);
	BEGIN channels := 2; rate := 44100; bits := 16 END GetAudioInfo;
	PROCEDURE CanSeek*(): BOOLEAN;
	BEGIN RETURN FALSE END CanSeek;
	PROCEDURE GetCurrentSample*(): SIGNED32;
	BEGIN RETURN SIGNED32(MIN(total DIV 4, MAX(SIGNED32))) END GetCurrentSample;
	PROCEDURE GetTotalSamples*(): SIGNED32;
	BEGIN RETURN -1 END GetTotalSamples;
	PROCEDURE GetCurrentTime*(): SIGNED32;
	BEGIN RETURN SIGNED32(MIN(total * 1000 DIV 176400, MAX(SIGNED32))) END GetCurrentTime;

	PROCEDURE FillBuffer*(buffer: SoundDevices.Buffer);
	VAR capacity: SIZE; n: SIGNED32;
	BEGIN
		capacity := MIN(buffer.len, LEN(buffer.data^)); buffer.len := 0;
		IF ~more OR (handle = 0) OR (capacity < 4) THEN RETURN END;
		capacity := MIN(capacity, 4096);
		LOOP
			n := ReadNative(handle, ADDRESSOF(buffer.data[0]), SIGNED32(capacity));
			IF n > 0 THEN buffer.len := n; INC(total, n); RETURN END;
			IF n < 0 THEN
				more := FALSE;
				IF n = -2 THEN error := ErrorNative(handle); KernelLog.String("Native radio codec error: "); KernelLog.Int(error, 0); KernelLog.Ln END;
				RETURN
			END;
			IF ~Feed() THEN more := FALSE; RETURN END
		END
	END FillBuffer;

	PROCEDURE Close*;
	BEGIN IF handle # 0 THEN Destroy(handle); handle := 0 END; more := FALSE END Close;
END Decoder;

VAR library: ADDRESS;
	Create: PROCEDURE {C}(): ADDRESS;
	FeedNative: PROCEDURE {C}(handle, data: ADDRESS; len: SIGNED32): SIGNED32;
	Ready, ErrorNative: PROCEDURE {C}(handle: ADDRESS): SIGNED32;
	ReadNative: PROCEDURE {C}(handle, data: ADDRESS; capacity: SIGNED32): SIGNED32;
	EndNative, Destroy: PROCEDURE {C}(handle: ADDRESS);

PROCEDURE Bind(): BOOLEAN;
BEGIN {EXCLUSIVE}
	IF library # 0 THEN RETURN TRUE END;
	library := Glue.dlopen(ADDRESSOF("@executable_path/libA2Radio.dylib"), 2);
	IF library = 0 THEN RETURN FALSE END;
	Unix.Dlsym(library, "a2codec_create", ADDRESSOF(Create));
	Unix.Dlsym(library, "a2codec_feed", ADDRESSOF(FeedNative));
	Unix.Dlsym(library, "a2codec_ready", ADDRESSOF(Ready));
	Unix.Dlsym(library, "a2codec_read", ADDRESSOF(ReadNative));
	Unix.Dlsym(library, "a2codec_end", ADDRESSOF(EndNative));
	Unix.Dlsym(library, "a2codec_destroy", ADDRESSOF(Destroy));
	Unix.Dlsym(library, "a2codec_error", ADDRESSOF(ErrorNative));
	ASSERT((Create # NIL) & (FeedNative # NIL) & (Ready # NIL) & (ReadNative # NIL) &
		(EndNative # NIL) & (Destroy # NIL) & (ErrorNative # NIL));
	RETURN TRUE
END Bind;
END NativeRadioDecoder.
