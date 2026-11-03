MODULE FoxAArch64BackendTest; (** PURPOSE "Smoke input for the initial AArch64 backend"; *)

IMPORT SYSTEM;

VAR
	GlobalValue*: SIGNED64;
	GlobalPair*: ARRAY 2 OF SIGNED64;
	GlobalBytes*: ARRAY 16 OF CHAR;
	GlobalCounter32*: SIGNED32;

PROCEDURE Answer*(): SIGNED64;
BEGIN
	RETURN 42
END Answer;

PROCEDURE WideAnswer*(): SIGNED64;
BEGIN
	RETURN 0123456789ABCDEFH
END WideAnswer;

PROCEDURE NegativeAnswer*(): SIGNED64;
BEGIN
	RETURN -1
END NegativeAnswer;

PROCEDURE {C} Add*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left + right
END Add;

PROCEDURE {C} AddImmediate*(left: SIGNED64): SIGNED64;
BEGIN
	RETURN left + 7
END AddImmediate;

PROCEDURE {C} Subtract*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left - right
END Subtract;

PROCEDURE {C} SubtractImmediate*(left: SIGNED64): SIGNED64;
BEGIN
	RETURN left - 7
END SubtractImmediate;

PROCEDURE {C} Identity*(value: SIGNED64): SIGNED64;
BEGIN
	RETURN value
END Identity;

PROCEDURE {C} Increment*(value: SIGNED64): SIGNED64;
BEGIN
	RETURN value + 1
END Increment;

PROCEDURE {C} CallIncrement*(value: SIGNED64): SIGNED64;
BEGIN
	RETURN Increment(value)
END CallIncrement;

PROCEDURE InternalAdd(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left + right
END InternalAdd;

PROCEDURE {C} CallInternalAdd*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN InternalAdd(left, right)
END CallInternalAdd;

PROCEDURE {C} LocalRoundTrip*(value: SIGNED64): SIGNED64;
VAR temporary: SIGNED64;
BEGIN
	temporary := value + 5;
	temporary := temporary - 3;
	RETURN temporary
END LocalRoundTrip;

PROCEDURE {C} Maximum*(left, right: SIGNED64): SIGNED64;
BEGIN
	IF left < right THEN RETURN right ELSE RETURN left END
END Maximum;

PROCEDURE {C} SumTo*(limit: SIGNED64): SIGNED64;
VAR sum: SIGNED64;
BEGIN
	sum := 0;
	WHILE limit > 0 DO
		sum := sum + limit;
		limit := limit - 1
	END;
	RETURN sum
END SumTo;

PROCEDURE {C} Equal*(left, right: SIGNED64): SIGNED64;
BEGIN
	IF left = right THEN RETURN 1 ELSE RETURN 0 END
END Equal;

PROCEDURE {C} UnsignedLess*(left, right: UNSIGNED64): UNSIGNED64;
BEGIN
	IF left < right THEN RETURN 1 ELSE RETURN 0 END
END UnsignedLess;

PROCEDURE {C} Multiply*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left * right
END Multiply;

PROCEDURE {C} SignedDivide*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left DIV right
END SignedDivide;

PROCEDURE {C} SignedRemainder*(left, right: SIGNED64): SIGNED64;
BEGIN
	RETURN left MOD right
END SignedRemainder;

PROCEDURE {C} UnsignedDivide*(left, right: UNSIGNED64): UNSIGNED64;
BEGIN
	RETURN left DIV right
END UnsignedDivide;

PROCEDURE {C} UnsignedRemainder*(left, right: UNSIGNED64): UNSIGNED64;
BEGIN
	RETURN left MOD right
END UnsignedRemainder;

PROCEDURE {C} GlobalRoundTrip*(value: SIGNED64): SIGNED64;
BEGIN
	GlobalValue := value;
	RETURN GlobalValue
END GlobalRoundTrip;

PROCEDURE {C} GlobalOffsetRoundTrip*(value: SIGNED64): SIGNED64;
BEGIN
	GlobalPair[1] := value;
	RETURN GlobalPair[1]
END GlobalOffsetRoundTrip;

PROCEDURE {C} VariableByteRoundTrip*(index: SIZE; value: CHAR): UNSIGNED64;
BEGIN
	GlobalBytes[index] := value;
	RETURN ORD(GlobalBytes[index])
END VariableByteRoundTrip;

PROCEDURE {C} IncrementCounter32*(value: SIGNED32): SIGNED32;
BEGIN
	GlobalCounter32 := value;
	INC(GlobalCounter32);
	RETURN GlobalCounter32
END IncrementCounter32;

PROCEDURE {C} CopyBytes*(source, destination: ADDRESS; count: SIZE);
BEGIN
	SYSTEM.MOVE(source, destination, count)
END CopyBytes;

PROCEDURE {C} FloatAdd*(left, right: FLOAT64): FLOAT64;
BEGIN
	RETURN left + right
END FloatAdd;

PROCEDURE {C} FloatMultiply*(left, right: FLOAT64): FLOAT64;
BEGIN
	RETURN left * right
END FloatMultiply;

PROCEDURE {C} IntegerToFloat*(value: SIGNED32): FLOAT64;
BEGIN
	RETURN value
END IntegerToFloat;

PROCEDURE {C} FloatToInteger*(value: FLOAT64): SIGNED32;
BEGIN
	RETURN ENTIER(value)
END FloatToInteger;

BEGIN
	GlobalValue := 7
END FoxAArch64BackendTest.
