MODULE ActivityTreeMain;
IMPORT StdIO, Probe := DarwinActivityTreeProbe;
VAR word: ARRAY 4096 OF CHAR;
BEGIN
	IGNORE StdIO.env.arg.GetString(word);
	IGNORE StdIO.env.arg.GetString(word);
	IF word = "cancel" THEN Probe.Cancel(StdIO.env)
	ELSE ASSERT(word = "sieve"); Probe.Run(StdIO.env) END;
	StdIO.env.out.Update
END ActivityTreeMain.
