MODULE A64CompositeReturnTest;
IMPORT Trace;
TYPE
  Object = OBJECT VAR a,b,c: SIGNED16 END Object;
  Record = RECORD a,b,c: SIGNED16 END;
  StaticArray = ARRAY 6 OF SIGNED16;
  DynamicArray = POINTER TO ARRAY OF SIGNED16;
PROCEDURE O(a,b,c: SIGNED16): Object;
VAR o: Object;
BEGIN NEW(o); o.a:=a; o.b:=b; o.c:=c; RETURN o END O;
PROCEDURE RO(a,b,c: SIGNED16): Object;
BEGIN IF RESULT=NIL THEN NEW(RESULT) END; RESULT.a:=a; RESULT.b:=b; RESULT.c:=c; RETURN RESULT END RO;
PROCEDURE R(a,b,c: SIGNED16): Record;
VAR r: Record;
BEGIN r.a:=a; r.b:=b; r.c:=c; RETURN r END R;
PROCEDURE A(x,y,z: SIGNED16): StaticArray;
VAR a: StaticArray;
BEGIN a[0]:=x; a[1]:=y; a[2]:=z; RETURN a END A;
PROCEDURE RA(x,y,z: SIGNED16): StaticArray;
BEGIN RESULT[0]:=x; RESULT[1]:=y; RESULT[2]:=z; RETURN RESULT END RA;
PROCEDURE DA(x,y,z: SIGNED16): DynamicArray;
VAR a: DynamicArray;
BEGIN NEW(a,3); a[0]:=x; a[1]:=y; a[2]:=z; RETURN a END DA;
PROCEDURE RDA(x,y,z: SIGNED16): DynamicArray;
BEGIN IF RESULT=NIL THEN NEW(RESULT,3) END; RESULT[0]:=x; RESULT[1]:=y; RESULT[2]:=z; RETURN RESULT END RDA;
PROCEDURE Run*;
VAR o: Object; r: Record; a: StaticArray; d: DynamicArray;
BEGIN
  o:=O(1,2,3); ASSERT(o.a=1); ASSERT(o.b=2); ASSERT(o.c=3);
  o:=RO(10,20,30); ASSERT(o.a=10); ASSERT(o.b=20); ASSERT(o.c=30);
  r:=R(10,20,30); ASSERT(r.a=10); ASSERT(r.b=20); ASSERT(r.c=30);
  a:=A(10,20,30); ASSERT(a[0]=10); ASSERT(a[1]=20); ASSERT(a[2]=30);
  a:=RA(11,22,33); ASSERT(a[0]=11); ASSERT(a[1]=22); ASSERT(a[2]=33);
  d:=DA(10,20,30); ASSERT(d[0]=10); ASSERT(d[1]=20); ASSERT(d[2]=30);
  d:=RDA(11,22,33); ASSERT(d[0]=11); ASSERT(d[1]=22); ASSERT(d[2]=33);
  Trace.StringLn("portable composite returns passed")
END Run;
END A64CompositeReturnTest.
