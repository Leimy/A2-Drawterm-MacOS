MODULE DarwinSound;

IMPORT Glue, Unix, SoundDevices, Modules, KernelLog, Kernel;

TYPE
	Mixer = OBJECT(SoundDevices.MixerChannel)
	VAR volume: INTEGER; muted: BOOLEAN;
		PROCEDURE &Init;
		BEGIN volume := 255; muted := FALSE END Init;
		PROCEDURE GetName*(VAR name: ARRAY OF CHAR);
		BEGIN name := "PCM" END GetName;
		PROCEDURE GetDesc*(VAR desc: ARRAY OF CHAR);
		BEGIN desc := "A2 output volume" END GetDesc;
		PROCEDURE SetVolume*(v: INTEGER);
		BEGIN IF v < 0 THEN v := 0 ELSIF v > 255 THEN v := 255 END; volume := v END SetVolume;
		PROCEDURE GetVolume*(): INTEGER;
		BEGIN RETURN volume END GetVolume;
		PROCEDURE Gain(): INTEGER;
		BEGIN IF muted THEN RETURN 0 ELSE RETURN volume END END Gain;
		PROCEDURE SetMute*(m: BOOLEAN);
		BEGIN muted := m END SetMute;
		PROCEDURE GetIsMute*(): BOOLEAN;
		BEGIN RETURN muted END GetIsMute;
	END Mixer;

	PlayChannel = OBJECT(SoundDevices.Channel)
	VAR handle: ADDRESS; listener: SoundDevices.BufferListener; volume, generation: SIGNED32; mixer: Mixer;
		PROCEDURE &Init*(h: ADDRESS; m: Mixer);
		BEGIN handle := h; volume := 256; mixer := m END Init;
		PROCEDURE GetChannelKind*(): SIGNED32;
		BEGIN RETURN SoundDevices.ChannelPlay END GetChannelKind;
		PROCEDURE SetVolume*(v: SIGNED32);
		BEGIN {EXCLUSIVE}
			IF v < 0 THEN v := 0 ELSIF v > 256 THEN v := 256 END;
			IF handle # 0 THEN Check(SetVolumeNative(handle, v * mixer.Gain() * 256 DIV 255)) END; volume := v
		END SetVolume;
		PROCEDURE GetVolume*(): SIGNED32;
		BEGIN RETURN volume END GetVolume;
		PROCEDURE GetPosition*(): SIGNED32;
		BEGIN {EXCLUSIVE} IF handle = 0 THEN RETURN 0 END; RETURN Position(handle) END GetPosition;
		PROCEDURE RegisterBufferListener*(l: SoundDevices.BufferListener);
		BEGIN {EXCLUSIVE} listener := l END RegisterBufferListener;
		PROCEDURE Start*;
		BEGIN {EXCLUSIVE} IF handle # 0 THEN Check(Control(handle, 1)) END END Start;
		PROCEDURE Pause*;
		BEGIN {EXCLUSIVE} IF handle # 0 THEN Check(Control(handle, 2)) END END Pause;
		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE} INC(generation); IF handle # 0 THEN Check(Control(handle, 3)) END END Stop;
		PROCEDURE QueueBuffer*(buffer: SoundDevices.Buffer);
		VAR callback: SoundDevices.BufferListener; offset, length, count: SIZE;
			status, epoch: SIGNED32; timer: Kernel.Timer;
		BEGIN
			BEGIN {EXCLUSIVE}
				IF (handle = 0) OR (buffer = NIL) OR (buffer.data = NIL) THEN RETURN END;
				IF (buffer.len < 0) OR (buffer.len > LEN(buffer.data^)) THEN RETURN END;
				callback := listener; epoch := generation; length := buffer.len
			END;
			offset := 0; NEW(timer);
			LOOP
				IF offset >= length THEN EXIT END;
				count := length - offset; IF count > 16384 THEN count := 16384 END;
				BEGIN {EXCLUSIVE}
					IF (handle = 0) OR (generation # epoch) THEN EXIT END;
					Check(SetVolumeNative(handle, volume * mixer.Gain() * 256 DIV 255));
					status := Write(handle, ADDRESSOF(buffer.data[offset]), SIGNED32(count))
				END;
				IF status = 0 THEN INC(offset, count)
				ELSIF status = 1 THEN timer.Sleep(5)
				ELSE Check(status); EXIT
				END
			END;
			(* Native storage owns a copy, so A2 can reuse the buffer immediately. *)
			IF callback # NIL THEN callback(buffer) END
		END QueueBuffer;
		PROCEDURE Close*;
		BEGIN {EXCLUSIVE}
			INC(generation);
			IF handle # 0 THEN Check(Control(handle, 4)); Destroy(handle); handle := 0 END;
			listener := NIL;
			channels.Remove(SELF)
		END Close;
		PROCEDURE Finalize*;
		BEGIN {EXCLUSIVE} IF handle # 0 THEN Destroy(handle); handle := 0 END END Finalize;
	END PlayChannel;

	Driver = OBJECT(SoundDevices.Driver)
	VAR mixer: Mixer;
		PROCEDURE &Init;
		BEGIN NEW(mixer); masterOut := mixer; SetName("DarwinSound"); desc := "macOS AudioQueue PCM output" END Init;
		PROCEDURE GetNofMixerChannels*(): SIGNED32;
		BEGIN RETURN 1 END GetNofMixerChannels;
		PROCEDURE NofNativeFrequencies*(): SIGNED32;
		BEGIN RETURN 2 END NofNativeFrequencies;
		PROCEDURE GetNativeFrequency*(nr: SIGNED32): SIGNED32;
		BEGIN IF nr = 0 THEN RETURN 44100 ELSE RETURN 48000 END END GetNativeFrequency;
		PROCEDURE NofSamplingResolutions*(): SIGNED32;
		BEGIN RETURN 2 END NofSamplingResolutions;
		PROCEDURE GetSamplingResolution*(nr: SIGNED32): SIGNED32;
		BEGIN IF nr = 0 THEN RETURN 8 ELSE RETURN 16 END END GetSamplingResolution;
		PROCEDURE OpenPlayChannel*(VAR channel: SoundDevices.Channel; rate, bits, channels, format: SIGNED32; VAR res: INTEGER);
		VAR h: ADDRESS; c: PlayChannel;
		BEGIN
			channel := NIL; res := SoundDevices.ResUnsupportedFormat;
			IF format # SoundDevices.FormatPCM THEN RETURN END;
			res := SoundDevices.ResUnsupportedFrequency; IF (rate < 8000) OR (rate > 192000) THEN RETURN END;
			res := SoundDevices.ResUnsupportedSamplingRes; IF (bits # 8) & (bits # 16) THEN RETURN END;
			res := SoundDevices.ResUnsupportedSubChannels; IF (channels < 1) OR (channels > 2) THEN RETURN END;
			h := Create(rate, bits, channels);
			res := SoundDevices.ResNoMoreChannels;
			IF h # 0 THEN NEW(c, h, mixer); Track(c); channel := c; res := SoundDevices.ResOK END
		END OpenPlayChannel;
	END Driver;

VAR library: ADDRESS; driver: Driver;
	channels: Kernel.FinalizedCollection;
	Create: PROCEDURE {C}(rate, bits, channels: SIGNED32): ADDRESS;
	Write: PROCEDURE {C}(handle, data: ADDRESS; len: SIGNED32): SIGNED32;
	Control: PROCEDURE {C}(handle: ADDRESS; command: SIGNED32): SIGNED32;
	Destroy: PROCEDURE {C}(handle: ADDRESS);
	SetVolumeNative: PROCEDURE {C}(handle: ADDRESS; volume: SIGNED32): SIGNED32;
	Position: PROCEDURE {C}(handle: ADDRESS): SIGNED32;

PROCEDURE Check(status: SIGNED32);
BEGIN
	IF status # 0 THEN KernelLog.String("DarwinSound error "); KernelLog.Int(status, 0); KernelLog.Ln END
END Check;

PROCEDURE Install*;
VAR res: INTEGER;
BEGIN {EXCLUSIVE}
	IF driver # NIL THEN RETURN END;
	IF library = 0 THEN
		library := Glue.dlopen(ADDRESSOF("@executable_path/libA2Audio.dylib"), 2);
		IF library = 0 THEN KernelLog.String("DarwinSound: libA2Audio.dylib not found beside OberonLoader"); KernelLog.Ln; RETURN END;
		Unix.Dlsym(library, "a2audio_create", ADDRESSOF(Create));
		Unix.Dlsym(library, "a2audio_write", ADDRESSOF(Write));
		Unix.Dlsym(library, "a2audio_control", ADDRESSOF(Control));
		Unix.Dlsym(library, "a2audio_destroy", ADDRESSOF(Destroy));
		Unix.Dlsym(library, "a2audio_volume", ADDRESSOF(SetVolumeNative));
		Unix.Dlsym(library, "a2audio_position", ADDRESSOF(Position));
		ASSERT((Create # NIL) & (Write # NIL) & (Control # NIL) & (Destroy # NIL) & (SetVolumeNative # NIL) & (Position # NIL))
	END;
	NEW(driver); SoundDevices.devices.Add(driver, res);
	IF res # 0 THEN driver := NIL ELSE KernelLog.String("DarwinSound installed"); KernelLog.Ln END
END Install;

PROCEDURE GetDevice*(): SoundDevices.Driver;
BEGIN Install; RETURN driver END GetDevice;

PROCEDURE FinalizeChannel(obj: ANY);
BEGIN obj(PlayChannel).Finalize END FinalizeChannel;

PROCEDURE Track(c: PlayChannel);
BEGIN channels.Add(c, FinalizeChannel) END Track;

PROCEDURE CloseChannel(obj: ANY; VAR cont: BOOLEAN);
BEGIN obj(PlayChannel).Finalize; cont := TRUE END CloseChannel;

PROCEDURE Cleanup;
BEGIN
	channels.Enumerate(CloseChannel); channels.Clear;
	IF driver # NIL THEN SoundDevices.devices.Remove(driver); driver := NIL END
END Cleanup;

BEGIN
	NEW(channels); Modules.InstallTermHandler(Cleanup)

END DarwinSound.
