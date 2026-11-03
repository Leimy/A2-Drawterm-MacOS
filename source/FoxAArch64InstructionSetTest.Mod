MODULE FoxAArch64InstructionSetTest;

IMPORT Instructions := FoxAArch64InstructionSet, Commands, Files;

PROCEDURE Run*(context: Commands.Context);
BEGIN
	ASSERT(Instructions.Nop() = SIGNED32(0D503201FH));
	ASSERT(Instructions.Brk(0123H) = SIGNED32(0D4202460H));
	ASSERT(Instructions.MovZ64(Instructions.X0, 01234H, 0) = SIGNED32(0D2824680H));
	ASSERT(Instructions.MovK64(Instructions.X0, 0ABCDH, 16) = SIGNED32(0F2B579A0H));
	ASSERT(Instructions.AddImmediate64(Instructions.X1, Instructions.X0, 17, FALSE) = SIGNED32(091004401H));
	ASSERT(Instructions.AddImmediate32(Instructions.X1, Instructions.X2, 3, FALSE) = 011000C41H);
	ASSERT(Instructions.SubImmediate64(Instructions.X2, Instructions.X1, 3, FALSE) = SIGNED32(0D1000C22H));
	ASSERT(Instructions.SubsImmediate64(Instructions.X15, Instructions.X15, 1, FALSE) = SIGNED32(0F10005EFH));
	ASSERT(Instructions.AddRegister64(Instructions.X8, Instructions.X0, Instructions.X1) = SIGNED32(08B010008H));
	ASSERT(Instructions.AddRegister32(Instructions.X3, Instructions.X4, Instructions.X5) = 00B050083H);
	ASSERT(Instructions.SubRegister64(Instructions.X8, Instructions.X0, Instructions.X1) = SIGNED32(0CB010008H));
	ASSERT(Instructions.Neg64(Instructions.X8, Instructions.X9) = SIGNED32(0CB0903E8H));
	ASSERT(Instructions.Lsrv64(Instructions.X4, Instructions.X4, Instructions.X3) = SIGNED32(09AC32484H));
	ASSERT(Instructions.Lslv64(Instructions.X8, Instructions.X9, Instructions.X10) = SIGNED32(09ACA2128H));
	ASSERT(Instructions.Rorv32(Instructions.X8, Instructions.X9, Instructions.X10) = 01ACA2D28H);
	ASSERT(Instructions.AndRegister64(Instructions.X4, Instructions.X4, Instructions.X3) = SIGNED32(08A030084H));
	ASSERT(Instructions.OrrRegister32(Instructions.X8, Instructions.X9, Instructions.X10) = 02A0A0128H);
	ASSERT(Instructions.EorRegister64(Instructions.X8, Instructions.X9, Instructions.X10) = SIGNED32(0CA0A0128H));
	ASSERT(Instructions.Mvn64(Instructions.X8, Instructions.X9) = SIGNED32(0AA2903E8H));
	ASSERT(Instructions.AndLowBit64(Instructions.X4, Instructions.X4) = SIGNED32(092400084H));
	ASSERT(Instructions.Mul64(Instructions.X8, Instructions.X9, Instructions.X10) = SIGNED32(09B0A7D28H));
	ASSERT(Instructions.UDiv64(Instructions.X8, Instructions.X9, Instructions.X10) = SIGNED32(09ACA0928H));
	ASSERT(Instructions.SDiv64(Instructions.X8, Instructions.X9, Instructions.X10) = SIGNED32(09ACA0D28H));
	ASSERT(Instructions.MSub64(Instructions.X11, Instructions.X8, Instructions.X10,
		Instructions.X9) = SIGNED32(09B0AA50BH));
	ASSERT(Instructions.Csel64(Instructions.X8, Instructions.X12, Instructions.X8,
		Instructions.LT) = SIGNED32(09A88B188H));
	ASSERT(Instructions.MovRegister64(Instructions.X0, Instructions.X8) = SIGNED32(0AA0803E0H));
	ASSERT(Instructions.AdrCurrent(Instructions.X0) = 010000000H);
	ASSERT(Instructions.LdrLiteral64(Instructions.X16, 8) = 058000050H);
	ASSERT(Instructions.Yield() = SIGNED32(0D503203FH));
	ASSERT(Instructions.Casal32(Instructions.X0, Instructions.X1, Instructions.X2) = SIGNED32(088E0FC41H));
	ASSERT(Instructions.Casal64(Instructions.X6, Instructions.X7, Instructions.X8) = SIGNED32(0C8E6FD07H));
	ASSERT(Instructions.Casal8(Instructions.X3, Instructions.X4, Instructions.X5) = 008E3FCA4H);
	ASSERT(Instructions.SignExtend64(Instructions.X23, Instructions.X24, 32) = SIGNED32(093407F17H));
	ASSERT(Instructions.ZeroExtend32To64(Instructions.X25, Instructions.X26) = SIGNED32(0D3407F59H));
	ASSERT(Instructions.CmpRegister64(Instructions.X9, Instructions.X10) = SIGNED32(0EB0A013FH));
	ASSERT(Instructions.CmpImmediate64(Instructions.X9, 7) = SIGNED32(0F1001D3FH));
	ASSERT(Instructions.StrUnsigned64(Instructions.X2, Instructions.SP, 16) = SIGNED32(0F9000BE2H));
	ASSERT(Instructions.LdrUnsigned64(Instructions.X3, Instructions.SP, 16) = SIGNED32(0F9400BE3H));
	ASSERT(Instructions.LdrUnsigned32(Instructions.X6, Instructions.X7, 12) = SIGNED32(0B9400CE6H));
	ASSERT(Instructions.StrUnsigned32(Instructions.X8, Instructions.X9, 16) = SIGNED32(0B9001128H));
	ASSERT(Instructions.LdrUnsigned16(Instructions.X1, Instructions.X2, 6) = 079400C41H);
	ASSERT(Instructions.StrUnsigned16(Instructions.X3, Instructions.X4, 8) = 079001083H);
	ASSERT(Instructions.LdrUnsigned8(Instructions.X10, Instructions.X11, 7) = 039401D6AH);
	ASSERT(Instructions.StrUnsigned8(Instructions.X12, Instructions.X13, 9) = 0390025ACH);
	ASSERT(Instructions.Stur64(Instructions.X0, Instructions.FP, -16) = SIGNED32(0F81F03A0H));
	ASSERT(Instructions.Ldur64(Instructions.X8, Instructions.FP, -16) = SIGNED32(0F85F03A8H));
	ASSERT(Instructions.Ldur32(Instructions.X14, Instructions.X15, -4) = SIGNED32(0B85FC1EEH));
	ASSERT(Instructions.Stur32(Instructions.X16, Instructions.X17, -8) = SIGNED32(0B81F8230H));
	ASSERT(Instructions.Ldur16(Instructions.X5, Instructions.X6, -2) = 0785FE0C5H);
	ASSERT(Instructions.Stur16(Instructions.X7, Instructions.X8, -4) = 0781FC107H);
	ASSERT(Instructions.Ldur8(Instructions.X19, Instructions.X20, -1) = 0385FF293H);
	ASSERT(Instructions.Stur8(Instructions.X21, Instructions.X22, -2) = 0381FE2D5H);
	ASSERT(Instructions.FmovToFloat64(8, Instructions.X9) = SIGNED32(09E670128H));
	ASSERT(Instructions.FmovFromFloat64(Instructions.X10, 11) = SIGNED32(09E66016AH));
	ASSERT(Instructions.LdurFloat64(8, Instructions.FP, -8) = SIGNED32(0FC5F83A8H));
	ASSERT(Instructions.SturFloat64(9, Instructions.FP, -16) = SIGNED32(0FC1F03A9H));
	ASSERT(Instructions.Fadd64(8, 9, 10) = 01E6A2928H);
	ASSERT(Instructions.Fsub64(8, 9, 10) = 01E6A3928H);
	ASSERT(Instructions.Fmul64(8, 9, 10) = 01E6A0928H);
	ASSERT(Instructions.Fdiv64(8, 9, 10) = 01E6A1928H);
	ASSERT(Instructions.Fneg64(8, 9) = 01E614128H);
	ASSERT(Instructions.Fabs64(8, 9) = 01E60C128H);
	ASSERT(Instructions.Fcmp64(9, 10) = 01E6A2120H);
	ASSERT(Instructions.Scvtf64From32(8, Instructions.X9) = 01E620128H);
	ASSERT(Instructions.Fcvtms32From64(Instructions.X8, 9) = 01E700128H);
	ASSERT(Instructions.Fcvtms32From32(Instructions.X8, 9) = 01E300128H);
	ASSERT(Instructions.Fcvtms64From32(Instructions.X8, 9) = SIGNED32(09E300128H));
	ASSERT(Instructions.StpPre64(Instructions.FP, Instructions.LR, Instructions.SP, -16) = SIGNED32(0A9BF7BFDH));
	ASSERT(Instructions.LdpPost64(Instructions.FP, Instructions.LR, Instructions.SP, 16) = SIGNED32(0A8C17BFDH));
	ASSERT(Instructions.Bl(8) = SIGNED32(094000002H));
	ASSERT(Instructions.BCond(8, Instructions.GE) = SIGNED32(05400004AH));
	ASSERT(Instructions.BCond(-4, Instructions.LT) = SIGNED32(054FFFFEBH));
	ASSERT(Instructions.Cbz64(Instructions.X15, 28) = SIGNED32(0B40000EFH));
	ASSERT(Instructions.Br(Instructions.X3) = SIGNED32(0D61F0060H));
	ASSERT(Instructions.Ret(Instructions.LR) = SIGNED32(0D65F03C0H));
	context.out.String("AArch64 instruction encoding tests passed"); context.out.Ln
END Run;

PROCEDURE EmitAnswer*(context: Commands.Context);
VAR file: Files.File; writer: Files.Writer;
BEGIN
	file := Files.New("AArch64Answer.bin"); ASSERT(file # NIL);
	Files.OpenWriter(writer, file, 0);
	writer.RawLInt(Instructions.MovZ64(Instructions.X0, 42, 0));
	writer.RawLInt(Instructions.Ret(Instructions.LR));
	writer.Update(); Files.Register(file);
	context.out.String("wrote AArch64Answer.bin"); context.out.Ln
END EmitAnswer;

END FoxAArch64InstructionSetTest.
