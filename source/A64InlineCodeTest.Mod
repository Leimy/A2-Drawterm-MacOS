MODULE A64InlineCodeTest;

IMPORT SYSTEM, Trace;

PROCEDURE -CurrentPC(): ADDRESS;
CODE{SYSTEM.AArch64}
    AARCH64_CURRENT_PC
END CurrentPC;

PROCEDURE Run*;
VAR pc: ADDRESS;
BEGIN
    pc := CurrentPC();
    ASSERT(pc # 0);
    Trace.StringLn("AArch64 inline code passed")
END Run;

END A64InlineCodeTest.
