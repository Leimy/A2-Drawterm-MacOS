MODULE A64CallingConventionTest;

IMPORT SYSTEM, Trace;

TYPE Pointer = POINTER TO RECORD x, y: SIGNED32 END;

PROCEDURE {C} CReturn(x, y: SIGNED32): Pointer;
VAR p: Pointer;
BEGIN NEW(p); p.x := x; p.y := y; RETURN p END CReturn;

PROCEDURE {WINAPI} WinReturn(x, y: SIGNED32): Pointer;
VAR p: Pointer;
BEGIN NEW(p); p.x := x; p.y := y; RETURN p END WinReturn;

PROCEDURE {WINAPI} CheckBuffer(VAR buffer: ARRAY OF SYSTEM.BYTE);
BEGIN ASSERT(SYSTEM.VAL(CHAR, buffer[0]) = 'A') END CheckBuffer;

PROCEDURE Run*;
VAR p: Pointer; buffer: ARRAY 2 OF CHAR;
BEGIN
    p := CReturn(1, 2); ASSERT(p.x = 1); ASSERT(p.y = 2);
    p := WinReturn(3, 4); ASSERT(p.x = 3); ASSERT(p.y = 4);
    buffer[0] := 'A'; CheckBuffer(buffer);
    Trace.StringLn("AArch64 calling convention tests passed")
END Run;

END A64CallingConventionTest.
