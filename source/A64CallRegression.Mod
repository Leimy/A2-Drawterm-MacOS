MODULE A64CallRegression;
TYPE Rectangle = RECORD l, t, r, b: SIZE END;
PROCEDURE Make(l, t, r, b: SIZE): Rectangle;
VAR result: Rectangle;
BEGIN result.l := l; result.t := t; result.r := r; result.b := b; RETURN result END Make;
PROCEDURE Sum5(a,b,c,d,e: SIGNED64): SIGNED64;
BEGIN RETURN a + 10*b + 100*c + 1000*d + 10000*e END Sum5;
PROCEDURE {C} Scalars*(): SIGNED64;
BEGIN RETURN Sum5(1,2,3,4,5) END Scalars;
PROCEDURE {C} Record*(): SIGNED64;
VAR r: Rectangle;
BEGIN r := Make(1,2,3,4); RETURN r.l + 10*r.t + 100*r.r + 1000*r.b END Record;
PROCEDURE Score(r: Rectangle): SIGNED64;
BEGIN RETURN r.l + 10*r.t + 100*r.r + 1000*r.b END Score;
PROCEDURE Assign(VAR destination: Rectangle; CONST source: Rectangle);
BEGIN destination := source END Assign;
PROCEDURE {C} Nested*(): SIGNED64;
VAR a, b: Rectangle;
BEGIN
 a := Make(1,2,3,4); Assign(b,a);
 RETURN Score(b) + Score(Make(5,6,7,8))
END Nested;
PROCEDURE ShortCode(): SIGNED16;
BEGIN RETURN -32768 END ShortCode;
PROCEDURE {C} Narrow*(): SIGNED64;
VAR code: SIGNED16; n: SIGNED32;
BEGIN
 code := ShortCode(); n := SIGNED32(Sum5(0,0,0,0,0));
 IF code - 1 # 32767 THEN RETURN 1 END;
 IF n - 10 >= 0 THEN RETURN 2 END;
 RETURN 0
END Narrow;
PROCEDURE {C} SignedShift*(): SIGNED64;
VAR n: SIGNED32;
BEGIN n := SIGNED32(Sum5(0,0,0,0,0)) - 10; RETURN ASH(n,-1) END SignedShift;
PROCEDURE Mixed(a: SIGNED64; r: Rectangle; b: SIGNED64; s, t: Rectangle; c, d: SIGNED64): SIGNED64;
BEGIN
 IF a # 101 THEN RETURN 1 END;
 IF Score(r) # 4321 THEN RETURN 2 END;
 IF b # 202 THEN RETURN 3 END;
 IF Score(s) # 8765 THEN RETURN 4 END;
 IF Score(t) # 3210 THEN RETURN 5 END;
 IF c # 303 THEN RETURN 6 END;
 IF d # 404 THEN RETURN 7 END;
 RETURN 0
END Mixed;
PROCEDURE {C} MixedRecords*(): SIGNED64;
VAR r, s, t: Rectangle;
BEGIN
 r := Make(1,2,3,4); s := Make(5,6,7,8); t := Make(0,1,2,3);
 RETURN Mixed(101,r,202,s,t,303,404)
END MixedRecords;
PROCEDURE {C} MixedConstructed*(): SIGNED64;
BEGIN RETURN Mixed(101,Make(1,2,3,4),202,Make(5,6,7,8),Make(0,1,2,3),303,404) END MixedConstructed;
PROCEDURE Fold(s: ARRAY OF CHAR): SIGNED64;
BEGIN s[0] := 'z'; RETURN Sum5(ORD(s[0]),0,0,0,0) END Fold;
PROCEDURE {C} ValueArray*(): SIGNED64;
VAR s: ARRAY 7 OF CHAR;
BEGIN s[0] := "A"; s[1] := "b"; s[2] := "c"; s[3] := 0X; RETURN Fold(s) + ORD(s[0]) END ValueArray;
PROCEDURE {C} Rotations*(): SIGNED64;
VAR x: UNSIGNED64; y: UNSIGNED32; z: UNSIGNED16; b: UNSIGNED8; n: SIGNED32;
BEGIN
 n := SIGNED32(Sum5(4,0,0,0,0));
 x := 0123456789ABCDEFH;
 IF ROR(x,n) # 0F0123456789ABCDEH THEN RETURN 1 END;
 IF ROL(x,n) # 123456789ABCDEF0H THEN RETURN 2 END;
 IF ROT(x,-n) # ROR(x,n) THEN RETURN 3 END;
 y := 12345678H; IF ROR(y,n) # 81234567H THEN RETURN 4 END;
 z := 1234H; IF ROR(z,n) # 4123H THEN RETURN 5 END;
 b := 12H; IF ROR(b,n) # 21H THEN RETURN 6 END;
 IF ROR(x,0*n) # x THEN RETURN 7 END;
 IF ROR(x,n*16) # x THEN RETURN 8 END;
 RETURN 0
END Rotations;
END A64CallRegression.
