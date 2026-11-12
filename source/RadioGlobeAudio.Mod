MODULE RadioGlobeAudio;

IMPORT Commands, Files, Codecs, MP3Decoder, SoundDevices, KernelLog, DarwinSound, RadioStream, Modules, Streams, Strings;

TYPE Player = OBJECT
VAR url: ARRAY 2049 OF CHAR; input: RadioStream.Source;
	channel: SoundDevices.Channel; stopping, done: BOOLEAN;

	PROCEDURE &Init*(CONST address: ARRAY OF CHAR);
	BEGIN COPY(address, url); NEW(input) END Init;
	PROCEDURE Stop;
	BEGIN {EXCLUSIVE}
		stopping := TRUE; input.Close;
		IF channel # NIL THEN channel.Stop END
	END Stop;
	PROCEDURE Wait;
	BEGIN {EXCLUSIVE} AWAIT(done) END Wait;
	PROCEDURE IsDone(): BOOLEAN;
	BEGIN {EXCLUSIVE} RETURN done END IsDone;
	PROCEDURE IsStopping(): BOOLEAN;
	BEGIN {EXCLUSIVE} RETURN stopping END IsStopping;

	PROCEDURE Run;
	VAR decoder: Codecs.AudioDecoder; device: SoundDevices.Driver;
		buffer: SoundDevices.Buffer; rate, bits, channels: SIGNED32; res: INTEGER;
		c: SoundDevices.Channel;
	BEGIN
		IF ~input.Open(url) THEN
			IF ~IsStopping() THEN KernelLog.String("Radio connection failed (use a direct HTTP/HTTPS MP3 stream URL)"); KernelLog.Ln END;
			RETURN
		END;
		decoder := MP3Decoder.Factory(); decoder.Open(input.reader, res);
		IF res # 0 THEN
			IF ~IsStopping() THEN KernelLog.String("Radio MP3 decoder rejected stream"); KernelLog.Ln END;
			RETURN
		END;
		decoder.GetAudioInfo(channels, rate, bits);
		device := DarwinSound.GetDevice(); IF device = NIL THEN RETURN END;
		device.OpenPlayChannel(c, rate, bits, channels, SoundDevices.FormatPCM, res);
		BEGIN {EXCLUSIVE}
			channel := c;
			IF stopping OR (channel = NIL) THEN RETURN END;
			channel.Start
		END;
		NEW(buffer); NEW(buffer.data, 4608); buffer.len := LEN(buffer.data^);
		KernelLog.String("Radio playing"); KernelLog.Ln;
		LOOP
			BEGIN {EXCLUSIVE} IF stopping THEN EXIT END END;
			IF ~decoder.HasMoreData() THEN EXIT END;
			decoder.FillBuffer(buffer);
			BEGIN {EXCLUSIVE} IF stopping THEN EXIT END END;
			c.QueueBuffer(buffer)
		END
	FINALLY
		input.Release;
		(* Do not hold the player's lock while draining the native channel. *)
		BEGIN {EXCLUSIVE} c := channel; channel := NIL END;
		IF c # NIL THEN c.Close END
	END Run;

BEGIN {ACTIVE}
	Run;
FINALLY
	BEGIN {EXCLUSIVE} done := TRUE END;
	KernelLog.String("Radio stopped"); KernelLog.Ln
END Player;

VAR player: Player;

PROCEDURE PlayURL*(context: Commands.Context);
VAR url: ARRAY 2049 OF CHAR;
BEGIN {EXCLUSIVE}
	IF ~context.arg.GetString(url) THEN
		context.error.String("Usage: RadioGlobeAudio.PlayURL https://host/mount.mp3"); context.error.Ln; RETURN
	END;
	IF (player # NIL) & ~player.IsDone() THEN
		context.error.String("A radio stream is active; run RadioGlobeAudio.Stop first"); context.error.Ln; RETURN
	END;
	NEW(player, url)
END PlayURL;

PROCEDURE Stop*;
VAR p: Player;
BEGIN
	BEGIN {EXCLUSIVE} p := player END;
	IF p # NIL THEN p.Stop; p.Wait END
END Stop;

(** Wait for a finite test stream without keeping a desktop open. *)
PROCEDURE Wait*;
VAR p: Player;
BEGIN
	BEGIN {EXCLUSIVE} p := player END;
	IF p # NIL THEN p.Wait END
END Wait;

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
	r: Streams.Reader; fileReader: Files.Reader; w: Files.Writer; network: RadioStream.Source;
	decoder: Codecs.AudioDecoder;
	buffer: SoundDevices.Buffer;
	channels, rate, bits, byteRate, count: SIGNED32;
	res: INTEGER;
BEGIN
	IF ~context.arg.GetString(input) OR ~context.arg.GetString(output) THEN
		context.error.String("Usage: RadioGlobeAudio.DecodeMP3 input.mp3 output.wav"); context.error.Ln; RETURN
	END;
	IF input = output THEN context.error.String("Input and output must differ"); context.error.Ln; RETURN END;
	IF (Strings.Pos("http://", input) = 0) OR (Strings.Pos("https://", input) = 0) THEN
		NEW(network);
		IF ~network.Open(input) THEN context.error.String("Radio connection failed"); context.error.Ln; RETURN END;
		r := network.reader
	ELSE
		source := Files.Old(input);
		IF source = NIL THEN context.error.String("MP3 input not found"); context.error.Ln; RETURN END;
		Files.OpenReader(fileReader, source, 0); r := fileReader
	END;
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
FINALLY
	IF network # NIL THEN network.Release END
END DecodeMP3;

PROCEDURE PlayMP3*(context: Commands.Context);
VAR input: Files.FileName; source: Files.File; r: Files.Reader;
	decoder: Codecs.AudioDecoder; device: SoundDevices.Driver;
	channel: SoundDevices.Channel; buffer: SoundDevices.Buffer;
	channels, rate, bits: SIGNED32; res: INTEGER;
BEGIN
	channel := NIL;
	IF ~context.arg.GetString(input) THEN
		context.error.String("Usage: RadioGlobeAudio.PlayMP3 RadioGlobeTest.mp3"); context.error.Ln; RETURN
	END;
	source := Files.Old(input);
	IF source = NIL THEN context.error.String("MP3 input not found"); context.error.Ln; RETURN END;
	Files.OpenReader(r, source, 0);
	decoder := MP3Decoder.Factory(); decoder.Open(r, res);
	IF res # 0 THEN context.error.String("MP3 decoder rejected input"); context.error.Ln; RETURN END;
	decoder.GetAudioInfo(channels, rate, bits);
	device := DarwinSound.GetDevice();
	IF device = NIL THEN context.error.String("Native audio driver unavailable"); context.error.Ln; RETURN END;
	device.OpenPlayChannel(channel, rate, bits, channels, SoundDevices.FormatPCM, res);
	IF channel = NIL THEN context.error.String("Cannot open macOS audio output"); context.error.Ln; RETURN END;
	NEW(buffer); NEW(buffer.data, 4608); buffer.len := LEN(buffer.data^);
	channel.Start;
	WHILE decoder.HasMoreData() DO
		decoder.FillBuffer(buffer); channel.QueueBuffer(buffer)
	END;
	channel.Close; channel := NIL;
	KernelLog.String("Native MP3 playback complete"); KernelLog.Ln
FINALLY
	IF channel # NIL THEN channel.Close END
END PlayMP3;

BEGIN
	Modules.InstallTermHandler(Stop)
END RadioGlobeAudio.
