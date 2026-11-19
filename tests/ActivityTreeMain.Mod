MODULE ActivityTreeMain;
IMPORT ActivityTrees, Objects, StdIO, Probe := DarwinActivityTreeProbe;
PROCEDURE WaitForInterrupt;
BEGIN
	StdIO.env.out.String("waiting for interrupt"); StdIO.env.out.Ln; StdIO.env.out.Update;
	Objects.Sleep(60000)
END WaitForInterrupt;

VAR word: ARRAY 4096 OF CHAR; used: SIZE;
BEGIN
	IGNORE StdIO.env.arg.GetString(word);
	IGNORE StdIO.env.arg.GetString(word);
	IF word = "cancel" THEN Probe.Cancel(StdIO.env)
	ELSIF word = "interrupt" THEN ASSERT(ActivityTrees.Run(WaitForInterrupt, 2, used))
	ELSE ASSERT(word = "sieve"); Probe.Run(StdIO.env) END;
	StdIO.env.out.Update
END ActivityTreeMain.
