MODULE FoxAArch64InstructionSet; (** PURPOSE "Minimal AArch64 instruction encoders for the Fox backend"; *)

CONST
	X0* = 0; X1* = 1; X2* = 2; X3* = 3; X4* = 4; X5* = 5; X6* = 6; X7* = 7;
	X8* = 8; X9* = 9; X10* = 10; X11* = 11; X12* = 12; X13* = 13; X14* = 14; X15* = 15;
	X16* = 16; X17* = 17; X18* = 18; X19* = 19; X20* = 20; X21* = 21; X22* = 22; X23* = 23;
	X24* = 24; X25* = 25; X26* = 26; X27* = 27; X28* = 28; X29* = 29; X30* = 30;
	SP* = 31; ZR* = 31;
	FP* = X29; LR* = X30;
	NumberRegisters* = 32;
	InstructionSize* = 4;
	EQ* = 0; NE* = 1; CS* = 2; CC* = 3; MI* = 4; PL* = 5; VS* = 6; VC* = 7;
	HI* = 8; LS* = 9; GE* = 10; LT* = 11; GT* = 12; LE* = 13;

PROCEDURE Register(register: SIGNED32);
BEGIN
	ASSERT((0 <= register) & (register < NumberRegisters))
END Register;

PROCEDURE Word(base, fields: SIGNED32): SIGNED32;
BEGIN
	RETURN SIGNED32(SET(base) + SET(fields))
END Word;

PROCEDURE Nop*(): SIGNED32;
BEGIN
	RETURN SIGNED32(0D503201FH)
END Nop;

PROCEDURE Brk*(immediate: SIGNED32): SIGNED32;
BEGIN
	ASSERT((0 <= immediate) & (immediate <= 0FFFFH));
	RETURN Word(SIGNED32(0D4200000H), ASH(immediate, 5))
END Brk;

PROCEDURE Ret*(register: SIGNED32): SIGNED32;
BEGIN
	Register(register);
	RETURN Word(SIGNED32(0D65F0000H), ASH(register, 5))
END Ret;

PROCEDURE Br*(register: SIGNED32): SIGNED32;
BEGIN
	Register(register);
	RETURN Word(SIGNED32(0D61F0000H), ASH(register, 5))
END Br;

PROCEDURE Blr*(register: SIGNED32): SIGNED32;
BEGIN
	Register(register);
	RETURN Word(SIGNED32(0D63F0000H), ASH(register, 5))
END Blr;

PROCEDURE MoveWide(base, destination, immediate, shift: SIGNED32): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(destination);
	ASSERT((0 <= immediate) & (immediate <= 0FFFFH));
	ASSERT((shift = 0) OR (shift = 16) OR (shift = 32) OR (shift = 48));
	fields := ASH(shift DIV 16, 21) + ASH(immediate, 5) + destination;
	RETURN Word(base, fields)
END MoveWide;

PROCEDURE MovZ64*(destination, immediate, shift: SIGNED32): SIGNED32;
BEGIN
	RETURN MoveWide(SIGNED32(0D2800000H), destination, immediate, shift)
END MovZ64;

PROCEDURE MovK64*(destination, immediate, shift: SIGNED32): SIGNED32;
BEGIN
	RETURN MoveWide(SIGNED32(0F2800000H), destination, immediate, shift)
END MovK64;

PROCEDURE AddSubImmediate(base, destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(destination); Register(source);
	ASSERT((0 <= immediate) & (immediate < 4096));
	fields := ASH(immediate, 10) + ASH(source, 5) + destination;
	IF shift12 THEN fields := SIGNED32(SET(fields) + {22}) END;
	RETURN Word(base, fields)
END AddSubImmediate;

PROCEDURE AddImmediate64*(destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
BEGIN
	RETURN AddSubImmediate(SIGNED32(091000000H), destination, source, immediate, shift12)
END AddImmediate64;

PROCEDURE AddImmediate32*(destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
BEGIN
	RETURN AddSubImmediate(011000000H, destination, source, immediate, shift12)
END AddImmediate32;

PROCEDURE SubImmediate64*(destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
BEGIN
	RETURN AddSubImmediate(SIGNED32(0D1000000H), destination, source, immediate, shift12)
END SubImmediate64;

PROCEDURE SubsImmediate64*(destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
BEGIN
	RETURN AddSubImmediate(SIGNED32(0F1000000H), destination, source, immediate, shift12)
END SubsImmediate64;

PROCEDURE SubImmediate32*(destination, source, immediate: SIGNED32; shift12: BOOLEAN): SIGNED32;
BEGIN
	RETURN AddSubImmediate(051000000H, destination, source, immediate, shift12)
END SubImmediate32;

PROCEDURE AddRegister64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(08B000000H), ASH(right, 16) + ASH(left, 5) + destination)
END AddRegister64;

PROCEDURE AddRegister32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(00B000000H, ASH(right, 16) + ASH(left, 5) + destination)
END AddRegister32;

PROCEDURE SubRegister64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(0CB000000H), ASH(right, 16) + ASH(left, 5) + destination)
END SubRegister64;

PROCEDURE SubRegister32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(04B000000H, ASH(right, 16) + ASH(left, 5) + destination)
END SubRegister32;

PROCEDURE Neg64*(destination, source: SIGNED32): SIGNED32;
BEGIN
	RETURN SubRegister64(destination, ZR, source)
END Neg64;

PROCEDURE Lsrv64*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source); Register(shift);
	RETURN Word(SIGNED32(09AC02400H), ASH(shift, 16) + ASH(source, 5) + destination)
END Lsrv64;

PROCEDURE Asrv64*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source); Register(shift);
	RETURN Word(SIGNED32(09AC02800H), ASH(shift, 16) + ASH(source, 5) + destination)
END Asrv64;

PROCEDURE Lslv64*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source); Register(shift);
	RETURN Word(SIGNED32(09AC02000H), ASH(shift, 16) + ASH(source, 5) + destination)
END Lslv64;

PROCEDURE Rorv64*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source); Register(shift);
	RETURN Word(SIGNED32(09AC02C00H), ASH(shift, 16) + ASH(source, 5) + destination)
END Rorv64;

PROCEDURE Lslv32*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source); Register(shift);
	RETURN Word(01AC02000H, ASH(shift, 16) + ASH(source, 5) + destination)
END Lslv32;

PROCEDURE Lsrv32*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source); Register(shift);
	RETURN Word(01AC02400H, ASH(shift, 16) + ASH(source, 5) + destination)
END Lsrv32;

PROCEDURE Rorv32*(destination, source, shift: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source); Register(shift);
	RETURN Word(01AC02C00H, ASH(shift, 16) + ASH(source, 5) + destination)
END Rorv32;

PROCEDURE AndRegister64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(08A000000H), ASH(right, 16) + ASH(left, 5) + destination)
END AndRegister64;

PROCEDURE AndRegister32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(00A000000H, ASH(right, 16) + ASH(left, 5) + destination)
END AndRegister32;

PROCEDURE OrrRegister64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(0AA000000H), ASH(right, 16) + ASH(left, 5) + destination)
END OrrRegister64;

PROCEDURE OrrRegister32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(02A000000H, ASH(right, 16) + ASH(left, 5) + destination)
END OrrRegister32;

PROCEDURE EorRegister64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(0CA000000H), ASH(right, 16) + ASH(left, 5) + destination)
END EorRegister64;

PROCEDURE EorRegister32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(04A000000H, ASH(right, 16) + ASH(left, 5) + destination)
END EorRegister32;

PROCEDURE Mvn64*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(SIGNED32(0AA2003E0H), ASH(source, 16) + destination)
END Mvn64;

PROCEDURE Mvn32*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(02A2003E0H, ASH(source, 16) + destination)
END Mvn32;

PROCEDURE AndLowBit64*(destination, source: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source);
	RETURN Word(SIGNED32(092400000H), ASH(source, 5) + destination)
END AndLowBit64;

PROCEDURE Mul64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(left); Register(right);
	RETURN Word(SIGNED32(09B007C00H), ASH(right, 16) + ASH(left, 5) + destination)
END Mul64;

PROCEDURE UDiv64*(destination, dividend, divisor: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(dividend); Register(divisor);
	RETURN Word(SIGNED32(09AC00800H), ASH(divisor, 16) + ASH(dividend, 5) + destination)
END UDiv64;

PROCEDURE SDiv64*(destination, dividend, divisor: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(dividend); Register(divisor);
	RETURN Word(SIGNED32(09AC00C00H), ASH(divisor, 16) + ASH(dividend, 5) + destination)
END SDiv64;

PROCEDURE MSub64*(destination, multiplicand, multiplier, minuend: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(multiplicand); Register(multiplier); Register(minuend);
	RETURN Word(SIGNED32(09B008000H), ASH(multiplier, 16) + ASH(minuend, 10) +
		ASH(multiplicand, 5) + destination)
END MSub64;

PROCEDURE Csel64*(destination, ifTrue, ifFalse, condition: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(ifTrue); Register(ifFalse);
	ASSERT((0 <= condition) & (condition <= LE));
	RETURN Word(SIGNED32(09A800000H), ASH(ifFalse, 16) + ASH(condition, 12) +
		ASH(ifTrue, 5) + destination)
END Csel64;

PROCEDURE MovRegister64*(destination, source: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source);
	RETURN Word(SIGNED32(0AA0003E0H), ASH(source, 16) + destination)
END MovRegister64;

PROCEDURE AdrCurrent*(destination: SIGNED32): SIGNED32;
BEGIN
	Register(destination);
	RETURN Word(010000000H, destination)
END AdrCurrent;

PROCEDURE LdrLiteral64*(destination, displacement: SIGNED32): SIGNED32;
BEGIN
	Register(destination);
	ASSERT((displacement MOD 4 = 0) & (displacement >= -1048576) &
		(displacement <= 1048572));
	RETURN Word(SIGNED32(058000000H), ASH(displacement DIV 4, 5) + destination)
END LdrLiteral64;

PROCEDURE Yield*(): SIGNED32;
BEGIN RETURN SIGNED32(0D503203FH)
END Yield;

PROCEDURE Casal32*(expected, newValue, address: SIGNED32): SIGNED32;
BEGIN
	Register(expected); Register(newValue); Register(address);
	RETURN Word(SIGNED32(088E0FC00H), ASH(expected, 16) + ASH(address, 5) + newValue)
END Casal32;

PROCEDURE Casal64*(expected, newValue, address: SIGNED32): SIGNED32;
BEGIN
	Register(expected); Register(newValue); Register(address);
	RETURN Word(SIGNED32(0C8E0FC00H), ASH(expected, 16) + ASH(address, 5) + newValue)
END Casal64;

PROCEDURE Casal8*(expected, newValue, address: SIGNED32): SIGNED32;
BEGIN
	Register(expected); Register(newValue); Register(address);
	RETURN Word(008E0FC00H, ASH(expected, 16) + ASH(address, 5) + newValue)
END Casal8;

PROCEDURE SignExtend64*(destination, source, bits: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source);
	ASSERT((bits = 8) OR (bits = 16) OR (bits = 32));
	RETURN Word(SIGNED32(093400000H), ASH(bits - 1, 10) + ASH(source, 5) + destination)
END SignExtend64;

PROCEDURE ZeroExtend32To64*(destination, source: SIGNED32): SIGNED32;
BEGIN
	Register(destination); Register(source);
	RETURN Word(SIGNED32(0D3400000H), ASH(31, 10) + ASH(source, 5) + destination)
END ZeroExtend32To64;

PROCEDURE CmpRegister64*(left, right: SIGNED32): SIGNED32;
BEGIN
	Register(left); Register(right);
	RETURN Word(SIGNED32(0EB00001FH), ASH(right, 16) + ASH(left, 5))
END CmpRegister64;

PROCEDURE CmpImmediate64*(left, immediate: SIGNED32): SIGNED32;
BEGIN
	Register(left);
	ASSERT((0 <= immediate) & (immediate < 4096));
	RETURN Word(SIGNED32(0F100001FH), ASH(immediate, 10) + ASH(left, 5))
END CmpImmediate64;

PROCEDURE LoadStoreUnsigned64(base, register, address, byteOffset: SIGNED32): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(register); Register(address);
	ASSERT((0 <= byteOffset) & (byteOffset <= 32760) & (byteOffset MOD 8 = 0));
	fields := ASH(byteOffset DIV 8, 10) + ASH(address, 5) + register;
	RETURN Word(base, fields)
END LoadStoreUnsigned64;

PROCEDURE LdrUnsigned64*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN LoadStoreUnsigned64(SIGNED32(0F9400000H), destination, address, byteOffset)
END LdrUnsigned64;

PROCEDURE StrUnsigned64*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN LoadStoreUnsigned64(SIGNED32(0F9000000H), source, address, byteOffset)
END StrUnsigned64;

PROCEDURE LoadStoreUnsigned(base, scale, register, address, byteOffset: SIGNED32): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(register); Register(address);
	ASSERT((0 <= byteOffset) & (byteOffset <= 4095 * scale) & (byteOffset MOD scale = 0));
	fields := ASH(byteOffset DIV scale, 10) + ASH(address, 5) + register;
	RETURN Word(base, fields)
END LoadStoreUnsigned;

PROCEDURE LdrUnsigned32*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0B9400000H), 4, destination, address, byteOffset)
END LdrUnsigned32;

PROCEDURE StrUnsigned32*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0B9000000H), 4, source, address, byteOffset)
END StrUnsigned32;

PROCEDURE LdrUnsigned16*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(079400000H, 2, destination, address, byteOffset)
END LdrUnsigned16;

PROCEDURE StrUnsigned16*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(079000000H, 2, source, address, byteOffset)
END StrUnsigned16;

PROCEDURE LdrUnsigned8*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(039400000H, 1, destination, address, byteOffset)
END LdrUnsigned8;

PROCEDURE StrUnsigned8*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(039000000H, 1, source, address, byteOffset)
END StrUnsigned8;

PROCEDURE LoadStoreUnscaled64(base, register, address, byteOffset: SIGNED32): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(register); Register(address);
	ASSERT((-256 <= byteOffset) & (byteOffset <= 255));
	fields := ASH(SIGNED32(SET(byteOffset) * SET(01FFH)), 12) + ASH(address, 5) + register;
	RETURN Word(base, fields)
END LoadStoreUnscaled64;

PROCEDURE Ldur64*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN LoadStoreUnscaled64(SIGNED32(0F8400000H), destination, address, byteOffset)
END Ldur64;

PROCEDURE Stur64*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN LoadStoreUnscaled64(SIGNED32(0F8000000H), source, address, byteOffset)
END Stur64;

PROCEDURE LoadStoreUnscaled(base, register, address, byteOffset: SIGNED32): SIGNED32;
VAR fields: SIGNED32;
BEGIN
	Register(register); Register(address);
	ASSERT((-256 <= byteOffset) & (byteOffset <= 255));
	fields := ASH(SIGNED32(SET(byteOffset) * SET(01FFH)), 12) + ASH(address, 5) + register;
	RETURN Word(base, fields)
END LoadStoreUnscaled;

PROCEDURE Ldur32*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0B8400000H), destination, address, byteOffset)
END Ldur32;

PROCEDURE Stur32*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0B8000000H), source, address, byteOffset)
END Stur32;

PROCEDURE Ldur16*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(078400000H, destination, address, byteOffset)
END Ldur16;

PROCEDURE Stur16*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(078000000H, source, address, byteOffset)
END Stur16;

PROCEDURE Ldur8*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(038400000H, destination, address, byteOffset)
END Ldur8;

PROCEDURE Stur8*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(038000000H, source, address, byteOffset)
END Stur8;

PROCEDURE FmovToFloat64*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(SIGNED32(09E670000H), ASH(source, 5) + destination)
END FmovToFloat64;

PROCEDURE FmovFromFloat64*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(SIGNED32(09E660000H), ASH(source, 5) + destination)
END FmovFromFloat64;

PROCEDURE FmovToFloat32*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(01E270000H, ASH(source, 5) + destination)
END FmovToFloat32;

PROCEDURE FmovFromFloat32*(destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(01E260000H, ASH(source, 5) + destination)
END FmovFromFloat32;

PROCEDURE LdrFloat64*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0FD400000H), 8, destination, address, byteOffset)
END LdrFloat64;

PROCEDURE StrFloat64*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0FD000000H), 8, source, address, byteOffset)
END StrFloat64;

PROCEDURE LdurFloat64*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0FC400000H), destination, address, byteOffset)
END LdurFloat64;

PROCEDURE SturFloat64*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0FC000000H), source, address, byteOffset)
END SturFloat64;

PROCEDURE LdrFloat32*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0BD400000H), 4, destination, address, byteOffset)
END LdrFloat32;

PROCEDURE StrFloat32*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnsigned(SIGNED32(0BD000000H), 4, source, address, byteOffset)
END StrFloat32;

PROCEDURE LdurFloat32*(destination, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0BC400000H), destination, address, byteOffset)
END LdurFloat32;

PROCEDURE SturFloat32*(source, address, byteOffset: SIGNED32): SIGNED32;
BEGIN RETURN LoadStoreUnscaled(SIGNED32(0BC000000H), source, address, byteOffset)
END SturFloat32;

PROCEDURE FloatBinary(base, destination, left, right: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(left); Register(right);
	RETURN Word(base, ASH(right, 16) + ASH(left, 5) + destination)
END FloatBinary;

PROCEDURE Fadd64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E602800H, destination, left, right) END Fadd64;
PROCEDURE Fsub64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E603800H, destination, left, right) END Fsub64;
PROCEDURE Fmul64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E600800H, destination, left, right) END Fmul64;
PROCEDURE Fdiv64*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E601800H, destination, left, right) END Fdiv64;
PROCEDURE Fadd32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E202800H, destination, left, right) END Fadd32;
PROCEDURE Fsub32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E203800H, destination, left, right) END Fsub32;
PROCEDURE Fmul32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E200800H, destination, left, right) END Fmul32;
PROCEDURE Fdiv32*(destination, left, right: SIGNED32): SIGNED32;
BEGIN RETURN FloatBinary(01E201800H, destination, left, right) END Fdiv32;

PROCEDURE FloatUnary(base, destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(base, ASH(source, 5) + destination)
END FloatUnary;

PROCEDURE FmovFloat64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E604000H, destination, source) END FmovFloat64;

PROCEDURE FmovFloat32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E204000H, destination, source) END FmovFloat32;

PROCEDURE Fneg64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E614000H, destination, source) END Fneg64;
PROCEDURE Fabs64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E60C000H, destination, source) END Fabs64;
PROCEDURE Fneg32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E214000H, destination, source) END Fneg32;
PROCEDURE Fabs32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatUnary(01E20C000H, destination, source) END Fabs32;

PROCEDURE Fcmp64*(left, right: SIGNED32): SIGNED32;
BEGIN Register(left); Register(right);
	RETURN Word(01E602000H, ASH(right, 16) + ASH(left, 5))
END Fcmp64;

PROCEDURE Fcmp32*(left, right: SIGNED32): SIGNED32;
BEGIN Register(left); Register(right);
	RETURN Word(01E202000H, ASH(right, 16) + ASH(left, 5))
END Fcmp32;

PROCEDURE FloatConvert(base, destination, source: SIGNED32): SIGNED32;
BEGIN Register(destination); Register(source);
	RETURN Word(base, ASH(source, 5) + destination)
END FloatConvert;

PROCEDURE Scvtf64From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E620000H, destination, source) END Scvtf64From32;
PROCEDURE Scvtf64From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E620000H), destination, source) END Scvtf64From64;
PROCEDURE Ucvtf64From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E630000H, destination, source) END Ucvtf64From32;
PROCEDURE Ucvtf64From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E630000H), destination, source) END Ucvtf64From64;
PROCEDURE Scvtf32From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E220000H, destination, source) END Scvtf32From32;
PROCEDURE Scvtf32From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E220000H), destination, source) END Scvtf32From64;
PROCEDURE Ucvtf32From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E230000H, destination, source) END Ucvtf32From32;
PROCEDURE Ucvtf32From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E230000H), destination, source) END Ucvtf32From64;
PROCEDURE Fcvtms32From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E700000H, destination, source) END Fcvtms32From64;
PROCEDURE Fcvtms64From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E700000H), destination, source) END Fcvtms64From64;
PROCEDURE Fcvtms32From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E300000H, destination, source) END Fcvtms32From32;
PROCEDURE Fcvtms64From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(SIGNED32(09E300000H), destination, source) END Fcvtms64From32;
PROCEDURE Fcvt64From32*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E22C000H, destination, source) END Fcvt64From32;
PROCEDURE Fcvt32From64*(destination, source: SIGNED32): SIGNED32;
BEGIN RETURN FloatConvert(01E624000H, destination, source) END Fcvt32From64;

PROCEDURE Pair64(base, first, second, address, byteOffset: SIGNED32): SIGNED32;
VAR scaled, fields: SIGNED32;
BEGIN
	Register(first); Register(second); Register(address);
	ASSERT((byteOffset MOD 8 = 0) & (-512 <= byteOffset) & (byteOffset <= 504));
	scaled := byteOffset DIV 8;
	fields := ASH(SIGNED32(SET(scaled) * SET(07FH)), 15) + ASH(second, 10) + ASH(address, 5) + first;
	RETURN Word(base, fields)
END Pair64;

PROCEDURE StpPre64*(first, second, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN Pair64(SIGNED32(0A9800000H), first, second, address, byteOffset)
END StpPre64;

PROCEDURE LdpPost64*(first, second, address, byteOffset: SIGNED32): SIGNED32;
BEGIN
	RETURN Pair64(SIGNED32(0A8C00000H), first, second, address, byteOffset)
END LdpPost64;

PROCEDURE BranchImmediate(offsetBytes: SIGNED32; link: BOOLEAN): SIGNED32;
VAR immediate, base: SIGNED32;
BEGIN
	ASSERT(offsetBytes MOD InstructionSize = 0);
	immediate := offsetBytes DIV InstructionSize;
	ASSERT((-33554432 <= immediate) & (immediate < 33554432));
	IF link THEN base := SIGNED32(094000000H) ELSE base := 014000000H END;
	RETURN SIGNED32(SET(base) + (SET(immediate) * SET(03FFFFFFH)))
END BranchImmediate;

PROCEDURE B*(offsetBytes: SIGNED32): SIGNED32;
BEGIN
	RETURN BranchImmediate(offsetBytes, FALSE)
END B;

PROCEDURE BCond*(offsetBytes, condition: SIGNED32): SIGNED32;
VAR immediate: SIGNED32;
BEGIN
	ASSERT((0 <= condition) & (condition <= LE));
	ASSERT(offsetBytes MOD InstructionSize = 0);
	immediate := offsetBytes DIV InstructionSize;
	ASSERT((-262144 <= immediate) & (immediate < 262144));
	RETURN Word(SIGNED32(054000000H),
		ASH(SIGNED32(SET(immediate) * SET(07FFFFH)), 5) + condition)
END BCond;

PROCEDURE Cbz64*(register, offsetBytes: SIGNED32): SIGNED32;
VAR immediate: SIGNED32;
BEGIN
	Register(register);
	ASSERT(offsetBytes MOD InstructionSize = 0);
	immediate := offsetBytes DIV InstructionSize;
	ASSERT((-262144 <= immediate) & (immediate < 262144));
	RETURN Word(SIGNED32(0B4000000H),
		ASH(SIGNED32(SET(immediate) * SET(07FFFFH)), 5) + register)
END Cbz64;

PROCEDURE Bl*(offsetBytes: SIGNED32): SIGNED32;
BEGIN
	RETURN BranchImmediate(offsetBytes, TRUE)
END Bl;

END FoxAArch64InstructionSet.
