MODULE A64NilTypeTest;

IMPORT Trace;

TYPE
    Base = POINTER TO BaseDesc;
    BaseDesc = RECORD END;
    Child = POINTER TO ChildDesc;
    ChildDesc = RECORD (BaseDesc) END;
    BaseObject = OBJECT END BaseObject;
    ChildObject = OBJECT (BaseObject) END ChildObject;

PROCEDURE NilBase(): Base;
BEGIN RETURN NIL END NilBase;

PROCEDURE NilObject(): BaseObject;
BEGIN RETURN NIL END NilObject;

PROCEDURE Run*;
VAR p: Base; c: Child; o: BaseObject;
BEGIN
    p := NIL;
    ASSERT(~(p IS Child));
    ASSERT(~(NilBase() IS Child));
    IF p IS Child THEN Trace.StringLn("NIL type test failed")
    ELSE Trace.StringLn("NIL type test passed") END;
    IF ~(p IS Child) THEN Trace.StringLn("negated NIL type test passed")
    ELSE Trace.StringLn("negated NIL type test failed") END;
    NEW(p);
    IF p IS Child THEN Trace.StringLn("base type test failed")
    ELSE Trace.StringLn("base type test passed") END;
    NEW(c); p := c;
    IF p IS Child THEN Trace.StringLn("child type test passed")
    ELSE Trace.StringLn("child type test failed") END;
    o := NIL;
    ASSERT(~(o IS ChildObject));
    ASSERT(~(NilObject() IS ChildObject));
    Trace.StringLn("NIL object type tests passed")
END Run;

END A64NilTypeTest.
