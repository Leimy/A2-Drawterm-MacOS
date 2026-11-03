MODULE A64InlineEmpty;
IMPORT SYSTEM, Trace;
PROCEDURE -Nothing;
CODE{SYSTEM.AArch64}
END Nothing;
PROCEDURE Run*;
BEGIN Nothing; Trace.StringLn("empty AArch64 inline passed") END Run;
END A64InlineEmpty.
