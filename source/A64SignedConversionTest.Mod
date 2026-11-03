MODULE A64SignedConversionTest;

IMPORT Trace;

PROCEDURE Run*;
VAR single: FLOAT32; double: FLOAT64;
BEGIN
    single := -1; ASSERT(ENTIER(single) = -1);
    single := -1.75; ASSERT(ENTIER(single) = -2);
    double := -1; ASSERT(ENTIER(double) = -1);
    double := -1.75; ASSERT(ENTIER(double) = -2);
    Trace.StringLn("signed float conversion tests passed")
END Run;

END A64SignedConversionTest.
