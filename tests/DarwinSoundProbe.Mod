MODULE DarwinSoundProbe;
IMPORT DarwinSound, SoundDevices, Kernel, KernelLog;

TYPE Producer = OBJECT
VAR channel: SoundDevices.Channel; done: BOOLEAN; count: SIGNED32;
	b: SoundDevices.Buffer; i: SIGNED32;
	PROCEDURE &Init*(c: SoundDevices.Channel);
	BEGIN channel := c END Init;
	PROCEDURE Returned(buffer: SoundDevices.Buffer);
	BEGIN INC(count) END Returned;
	PROCEDURE Wait;
	BEGIN {EXCLUSIVE} AWAIT(done) END Wait;
	PROCEDURE IsDone(): BOOLEAN;
	BEGIN {EXCLUSIVE} RETURN done END IsDone;
BEGIN {ACTIVE}
	NEW(b); NEW(b.data, 4096); b.len := 4096;
	channel.RegisterBufferListener(Returned);
	FOR i := 0 TO 31 DO channel.QueueBuffer(b) END;
	BEGIN {EXCLUSIVE} done := TRUE END
END Producer;

PROCEDURE Run*;
VAR device: SoundDevices.Driver; first, second, empty: SoundDevices.Channel;
	mixer: SoundDevices.MixerChannel; producer, other: Producer; timer: Kernel.Timer; res: INTEGER;
BEGIN
	first := NIL; second := NIL; empty := NIL;
	device := DarwinSound.GetDevice(); ASSERT(device # NIL);
	(* Start is legal before any PCM arrives; empty pause/stop/close must not
	   try to start an empty macOS AudioQueue. *)
	device.OpenPlayChannel(empty, 44100, 16, 2, SoundDevices.FormatPCM, res);
	ASSERT((empty # NIL) & (res = 0));
	empty.Start; empty.Pause; empty.Start; empty.Stop; empty.Close; empty := NIL;
	device.OpenPlayChannel(first, 0, 16, 2, SoundDevices.FormatPCM, res);
	ASSERT(first = NIL); ASSERT(res = SoundDevices.ResUnsupportedFrequency);
	device.OpenPlayChannel(first, 44100, 16, 2, SoundDevices.FormatPCM, res);
	ASSERT((first # NIL) & (res = 0));
	device.OpenPlayChannel(second, 48000, 16, 1, SoundDevices.FormatPCM, res);
	ASSERT((second # NIL) & (res = 0));
	first.SetVolume(128); second.SetVolume(256);
	ASSERT((first.GetVolume() = 128) & (second.GetVolume() = 256));
	device.GetMixerChannel(0, mixer); ASSERT(mixer # NIL);
	mixer.SetVolume(100); ASSERT(mixer.GetVolume() = 100);
	mixer.SetMute(TRUE); ASSERT(mixer.GetIsMute()); ASSERT(mixer.GetVolume() = 100);
	mixer.SetMute(FALSE); mixer.SetVolume(255);
	NEW(timer); NEW(producer, first); NEW(other, second);
	timer.Sleep(100); ASSERT(~producer.IsDone()); ASSERT(~other.IsDone());
	first.Start; second.Start; producer.Wait; other.Wait;
	ASSERT((producer.count = 32) & (other.count = 32));
	first.Pause; first.Stop; first.Start;
	first.Close; first.Close; first := NIL;
	second.Close; second := NIL;
	KernelLog.String("AUDIO PASS channels, mixer, backpressure, resume, stop, close"); KernelLog.Ln
FINALLY
	IF empty # NIL THEN empty.Close END;
	IF first # NIL THEN first.Close END;
	IF second # NIL THEN second.Close END
END Run;
END DarwinSoundProbe.
