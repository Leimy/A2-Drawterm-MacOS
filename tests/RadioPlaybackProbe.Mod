MODULE RadioPlaybackProbe;
IMPORT RadioGlobeAudio, Commands, Kernel, KernelLog, Strings, DarwinSound, SoundDevices;

PROCEDURE Run*(context: Commands.Context);
VAR base, first, last: ARRAY 2049 OF CHAR; status: ARRAY 1024 OF CHAR;
	timer: Kernel.Timer; i: SIGNED32;
BEGIN
	ASSERT(context.arg.GetString(base));
	COPY(base, first); Strings.Append(first, "/continuous-one");
	COPY(base, last); Strings.Append(last, "/continuous-two");
	FOR i := 0 TO 9 DO RadioGlobeAudio.RequestPlay("Old selection", first) END;
	RadioGlobeAudio.RequestPlay("Last station", last);
	NEW(timer); i := 0; RadioGlobeAudio.GetStatus(status);
	WHILE (i < 60) & (Strings.Pos("Playing | Last station", status) # 0) DO
		timer.Sleep(50); INC(i); RadioGlobeAudio.GetStatus(status)
	END;
	ASSERT(Strings.Pos("Playing | Last station", status) = 0);
	RadioGlobeAudio.Stop; RadioGlobeAudio.GetStatus(status);
	ASSERT(Strings.Pos("Stopped", status) = 0);
	KernelLog.String("RADIO PASS rapid selection keeps latest station and stops"); KernelLog.Ln
FINALLY
	RadioGlobeAudio.Stop
END Run;

(** Optional external-network probe. Output is muted in this process. *)
PROCEDURE Live*(context: Commands.Context);
VAR name: ARRAY 513 OF CHAR; url: ARRAY 8193 OF CHAR; status: ARRAY 1024 OF CHAR;
	timer: Kernel.Timer; i: SIGNED32; device: SoundDevices.Driver; mixer: SoundDevices.MixerChannel;
BEGIN
	ASSERT(context.arg.GetString(name)); ASSERT(context.arg.GetString(url));
	device := DarwinSound.GetDevice(); ASSERT(device # NIL); device.GetMixerChannel(0, mixer);
	ASSERT(mixer # NIL); mixer.SetMute(TRUE);
	RadioGlobeAudio.Start(name, url); NEW(timer); i := 0; RadioGlobeAudio.GetStatus(status);
	WHILE (i < 200) & (Strings.Pos("Playing", status) # 0) DO
		timer.Sleep(100); INC(i); RadioGlobeAudio.GetStatus(status)
	END;
	KernelLog.String(status); KernelLog.Ln;
	ASSERT(Strings.Pos("Playing", status) = 0);
	timer.Sleep(2000); RadioGlobeAudio.GetStatus(status);
	ASSERT(Strings.Pos("Playing", status) = 0);
	KernelLog.String("RADIO LIVE PASS "); KernelLog.String(name); KernelLog.Ln
FINALLY
	RadioGlobeAudio.Stop
END Live;
END RadioPlaybackProbe.
