MODULE A64AddressLoweringTest;

IMPORT SYSTEM;

VAR address: SIGNED64;

PROCEDURE CompileOnly*;
VAR a: SIGNED32; adr: ADDRESS;
BEGIN
    address := SYSTEM.ADR(address);
    adr := 0;
    SYSTEM.GET(040EH, SYSTEM.VAL(SIGNED16, adr));
    SYSTEM.GET(-1, a)
END CompileOnly;

END A64AddressLoweringTest.
