MODULE RadioGlobeAudio;

IMPORT Commands, Files, Codecs, MP3Decoder, SoundDevices, KernelLog, DarwinSound, RadioStream, Modules, Streams, Strings, NativeRadioDecoder;

TYPE Player = OBJECT
VAR url: ARRAY 8193 OF CHAR; input: RadioStream.Source;
	name: ARRAY 513 OF CHAR; state: ARRAY 128 OF CHAR;
	channel: SoundDevices.Channel; stopping, done: BOOLEAN;

	PROCEDURE &Init*(CONST label, address: ARRAY OF CHAR);
	BEGIN COPY(label, name); COPY(address, url); state := "Connecting"; NEW(input) END Init;
	PROCEDURE State(CONST text: ARRAY OF CHAR);
	BEGIN {EXCLUSIVE} COPY(text, state) END State;
	PROCEDURE Status(VAR text: ARRAY OF CHAR);
	VAR title: ARRAY 4081 OF CHAR;
	BEGIN {EXCLUSIVE}
		COPY(state, text);
		IF name # "" THEN Strings.AppendX(text, " | "); Strings.AppendX(text, name) END;
		IF state = "Playing" THEN
			input.GetTitle(title);
			IF title # "" THEN Strings.AppendX(text, " | "); Strings.AppendX(text, title) END
		END
	END Status;
	PROCEDURE Stop;
	BEGIN {EXCLUSIVE}
		IF done THEN state := "Stopped"; RETURN END;
		stopping := TRUE; state := "Stopping"; input.Close;
		IF channel # NIL THEN channel.Stop END
	END Stop;
	PROCEDURE Wait;
	BEGIN {EXCLUSIVE} AWAIT(done) END Wait;
	PROCEDURE IsDone(): BOOLEAN;
	BEGIN {EXCLUSIVE} RETURN done END IsDone;
	PROCEDURE IsStopping(): BOOLEAN;
	BEGIN {EXCLUSIVE} RETURN stopping END IsStopping;

	PROCEDURE Run;
	VAR decoder: NativeRadioDecoder.Decoder; device: SoundDevices.Driver;
		buffer: SoundDevices.Buffer; rate, bits, channels: SIGNED32; res: INTEGER;
		c: SoundDevices.Channel;
	BEGIN
		IF ~input.Open(url) THEN
			State("Connection failed: stream unavailable or unsupported format");
			IF ~IsStopping() THEN KernelLog.String("Radio connection failed (use a direct HTTP/HTTPS audio stream URL)"); KernelLog.Ln END;
			RETURN
		END;
		NEW(decoder); decoder.Open(input.reader, res);
		IF res # 0 THEN
			State("Unsupported stream codec or invalid audio");
			IF ~IsStopping() THEN KernelLog.String("Radio codec rejected stream"); KernelLog.Ln END;
			RETURN
		END;
		decoder.GetAudioInfo(channels, rate, bits);
		device := DarwinSound.GetDevice(); IF device = NIL THEN State("Audio driver unavailable"); RETURN END;
		device.OpenPlayChannel(c, rate, bits, channels, SoundDevices.FormatPCM, res);
		BEGIN {EXCLUSIVE}
			channel := c;
			IF stopping THEN RETURN END;
			IF channel = NIL THEN state := "Cannot open audio output"; RETURN END;
			channel.Start
		END;
		NEW(buffer); NEW(buffer.data, 4608); buffer.len := LEN(buffer.data^);
		KernelLog.String("Radio playing"); KernelLog.Ln;
		State("Playing");
		LOOP
			BEGIN {EXCLUSIVE} IF stopping THEN EXIT END END;
			IF ~decoder.HasMoreData() THEN EXIT END;
			decoder.FillBuffer(buffer);
			BEGIN {EXCLUSIVE} IF stopping THEN EXIT END END;
			c.QueueBuffer(buffer)
		END
	FINALLY
		IF decoder # NIL THEN
			IF (decoder.error # 0) & ~IsStopping() THEN
				State("Audio decoder error (station format unsupported or damaged)");
				KernelLog.String("Radio decoder error: "); KernelLog.Int(decoder.error, 0); KernelLog.Ln
			END;
			decoder.Close
		END;
		input.Release;
		(* Do not hold the player's lock while draining the native channel. *)
		BEGIN {EXCLUSIVE} c := channel; channel := NIL END;
		IF c # NIL THEN c.Close END
	END Run;

BEGIN {ACTIVE}
	Run;
FINALLY
	KernelLog.String("Radio stopped"); KernelLog.Ln;
	BEGIN {EXCLUSIVE}
		IF stopping THEN state := "Stopped" ELSIF state = "Playing" THEN state := "Stream ended" END;
		done := TRUE
	END
END Player;

TYPE Controller = OBJECT
	PROCEDURE Replace(token: SIGNED64; CONST name, url: ARRAY OF CHAR);
	VAR old, next: Player;
	BEGIN {EXCLUSIVE}
		IF ~Latest(token) THEN RETURN END;
		old := Current();
		IF old # NIL THEN old.Stop; old.Wait END;
		IF Latest(token) & (url # "") THEN NEW(next, name, url); SetCurrent(next) END
	END Replace;
END Controller;

TYPE Request = OBJECT
VAR token: SIGNED64; name: ARRAY 513 OF CHAR; url: ARRAY 8193 OF CHAR;
	PROCEDURE &Init*(id: SIGNED64; CONST label, address: ARRAY OF CHAR);
	BEGIN token := id; COPY(label, name); COPY(address, url) END Init;
BEGIN {ACTIVE}
	controller.Replace(token, name, url)
FINALLY
	JobDone
END Request;

VAR player: Player; controller: Controller; request: SIGNED64; jobs: SIZE;

PROCEDURE JobDone;
BEGIN {EXCLUSIVE} DEC(jobs) END JobDone;

PROCEDURE Reserve(): SIGNED64;
BEGIN {EXCLUSIVE} INC(request); RETURN request END Reserve;

PROCEDURE Latest(token: SIGNED64): BOOLEAN;
BEGIN {EXCLUSIVE} RETURN token = request END Latest;

PROCEDURE Current(): Player;
BEGIN {EXCLUSIVE} RETURN player END Current;

PROCEDURE SetCurrent(p: Player);
BEGIN {EXCLUSIVE} player := p END SetCurrent;

PROCEDURE Start*(CONST name, url: ARRAY OF CHAR);
BEGIN controller.Replace(Reserve(), name, url) END Start;

PROCEDURE RequestPlay*(CONST name, url: ARRAY OF CHAR);
VAR job: Request; token: SIGNED64;
BEGIN
	BEGIN {EXCLUSIVE} INC(request); token := request; INC(jobs) END;
	NEW(job, token, name, url)
END RequestPlay;

PROCEDURE RequestStop*;
BEGIN RequestPlay("", "") END RequestStop;

PROCEDURE GetStatus*(VAR text: ARRAY OF CHAR);
VAR p: Player;
BEGIN p := Current(); IF p = NIL THEN text := "Idle" ELSE p.Status(text) END END GetStatus;

PROCEDURE Status*(context: Commands.Context);
VAR text: ARRAY 1024 OF CHAR;
BEGIN GetStatus(text); context.out.String(text); context.out.Ln END Status;

PROCEDURE PlayURL*(context: Commands.Context);
VAR url: ARRAY 8193 OF CHAR;
BEGIN
	IF ~context.arg.GetString(url) THEN
		context.error.String("Usage: RadioGlobeAudio.PlayURL https://host/mount.mp3"); context.error.Ln; RETURN
	END;
	Start("", url)
END PlayURL;

PROCEDURE Stop*;
BEGIN Start("", "") END Stop;

(** Wait for a finite test stream without keeping a desktop open. *)
PROCEDURE Wait*;
VAR p: Player;
BEGIN
	p := Current();
	IF p # NIL THEN p.Wait END
END Wait;

PROCEDURE LE(w: Files.Writer; value: SIGNED32; bytes: SIGNED32);
VAR i: SIGNED32;
BEGIN
	FOR i := 1 TO bytes DO w.Char(CHR(value MOD 256)); value := value DIV 256 END
END LE;

(** Decode a local MPEG Layer III file to PCM WAV for playback and codec testing.
    DecodeMP3 input.mp3 output.wav *)
PROCEDURE Decode(context: Commands.Context; native: BOOLEAN);
VAR input, output: Files.FileName;
	source, target: Files.File;
	r: Streams.Reader; fileReader: Files.Reader; w: Files.Writer; network: RadioStream.Source;
	decoder: Codecs.AudioDecoder;
	nativeDecoder: NativeRadioDecoder.Decoder;
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
	IF native THEN NEW(nativeDecoder); decoder := nativeDecoder ELSE decoder := MP3Decoder.Factory() END;
	decoder.Open(r, res);
	IF res # 0 THEN
		IF native THEN context.error.String("Native audio decode failed: "); context.error.Int(nativeDecoder.error, 0)
		ELSE context.error.String("MP3 decoder rejected input") END;
		context.error.Ln; RETURN
	END;
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
	IF (nativeDecoder # NIL) & (nativeDecoder.error # 0) THEN
		context.error.String("Native audio decode failed: "); context.error.Int(nativeDecoder.error, 0); context.error.Ln; RETURN
	END;
	Files.OpenWriter(w, target, 0);
	w.String("RIFF"); LE(w, count + 36, 4); w.String("WAVEfmt "); LE(w, 16, 4);
	LE(w, 1, 2); LE(w, channels, 2); LE(w, rate, 4); LE(w, byteRate, 4);
	LE(w, channels * (bits DIV 8), 2); LE(w, bits, 2); w.String("data"); LE(w, count, 4);
	w.Update; Files.Register(target);
	IF native THEN KernelLog.String("Audio decoded bytes=") ELSE KernelLog.String("MP3 decoded bytes=") END;
	KernelLog.Int(count, 0);
	KernelLog.String(" rate="); KernelLog.Int(rate, 0);
	KernelLog.String(" channels="); KernelLog.Int(channels, 0); KernelLog.Ln
FINALLY
	IF nativeDecoder # NIL THEN nativeDecoder.Close END;
	IF network # NIL THEN network.Release END
END Decode;

PROCEDURE DecodeMP3*(context: Commands.Context);
BEGIN Decode(context, FALSE) END DecodeMP3;

PROCEDURE DecodeNative*(context: Commands.Context);
BEGIN Decode(context, TRUE) END DecodeNative;

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

PROCEDURE Cleanup;
BEGIN
	Stop;
	BEGIN {EXCLUSIVE} AWAIT(jobs = 0) END
END Cleanup;

BEGIN
	NEW(controller); Modules.InstallTermHandler(Cleanup)
END RadioGlobeAudio.
