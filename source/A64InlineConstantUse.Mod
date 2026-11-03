MODULE A64InlineConstantUse;
IMPORT A64InlineConstant, Trace;
PROCEDURE Run*;
BEGIN ASSERT(A64InlineConstant.Get() = 16); Trace.StringLn("exported AArch64 inline constant passed") END Run;
END A64InlineConstantUse.
