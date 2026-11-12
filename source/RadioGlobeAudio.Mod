MODULE RadioGlobeAudio;

IMPORT Commands, Files, Codecs, MP3Decoder, SoundDevices, KernelLog;

PROCEDURE LE(w: Files.Writer; value: SIGNED32; bytes: SIGNED32);
VAR i: SIGNED32;
BEGIN
	FOR i := 1 TO bytes DO w.Char(CHR(value MOD 256)); value := value DIV 256 END
END LE;

(** Decode a local MPEG Layer III file to PCM WAV for playback and codec testing.
    DecodeMP3 input.mp3 output.wav *)
PROCEDURE DecodeMP3*(context: Commands.Context);
VAR input, output: Files.FileName;
	source, target: Files.File;
	r: Files.Reader; w: Files.Writer;
	decoder: Codecs.AudioDecoder;
	buffer: SoundDevices.Buffer;
	channels, rate, bits, byteRate, count: SIGNED32;
	res: INTEGER;
BEGIN
	IF ~context.arg.GetString(input) OR ~context.arg.GetString(output) THEN
		context.error.String("Usage: RadioGlobeAudio.DecodeMP3 input.mp3 output.wav"); context.error.Ln; RETURN
	END;
	IF input = output THEN context.error.String("Input and output must differ"); context.error.Ln; RETURN END;
	source := Files.Old(input);
	IF source = NIL THEN context.error.String("MP3 input not found"); context.error.Ln; RETURN END;
	Files.OpenReader(r, source, 0);
	decoder := MP3Decoder.Factory(); decoder.Open(r, res);
	IF res # 0 THEN context.error.String("MP3 decoder rejected input"); context.error.Ln; RETURN END;
	decoder.GetAudioInfo(channels, rate, bits);
	IF (channels < 1) OR (channels > 2) OR (rate <= 0) OR (bits # 16) THEN
		context.error.String("Unsupported MP3 output format"); context.error.Ln; RETURN
	END;
	byteRate := rate * channels * (bits DIV 8);
	target := Files.New(output);
	IF target = NIL THEN context.error.String("Cannot create WAV output"); context.error.Ln; RETURN END;
	Files.OpenWriter(w, target, 0);
	FOR count := 0 TO 43 DO w.Char(0X) END;
	NEW(buffer); NEW(buffer.data, 4608); buffer.len := LEN(buffer.data^);
	count := 0;
	WHILE decoder.HasMoreData() & (count < byteRate * 600) DO
		decoder.FillBuffer(buffer);
		w.Bytes(buffer.data^, 0, buffer.len);
		INC(count, SIGNED32(buffer.len))
	END;
	w.Update;
	Files.OpenWriter(w, target, 0);
	w.String("RIFF"); LE(w, count + 36, 4); w.String("WAVEfmt "); LE(w, 16, 4);
	LE(w, 1, 2); LE(w, channels, 2); LE(w, rate, 4); LE(w, byteRate, 4);
	LE(w, channels * (bits DIV 8), 2); LE(w, bits, 2); w.String("data"); LE(w, count, 4);
	w.Update; Files.Register(target);
	KernelLog.String("MP3 decoded bytes="); KernelLog.Int(count, 0);
	KernelLog.String(" rate="); KernelLog.Int(rate, 0);
	KernelLog.String(" channels="); KernelLog.Int(channels, 0); KernelLog.Ln
END DecodeMP3;

END RadioGlobeAudio.
