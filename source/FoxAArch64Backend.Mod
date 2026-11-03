MODULE FoxAArch64Backend; (** PURPOSE "Initial AArch64 backend for Fox"; *)

IMPORT
	Basic := FoxBasic, SyntaxTree := FoxSyntaxTree, Global := FoxGlobal,
	Backend := FoxBackend, Sections := FoxSections,
	IntermediateCode := FoxIntermediateCode,
	IntermediateBackend := FoxIntermediateBackend,
	BinaryCode := FoxBinaryCode, CodeGenerators := FoxCodeGenerators,
	InstructionSet := FoxAArch64InstructionSet,
	SemanticChecker := FoxSemanticChecker, Formats := FoxFormats,
	ObjectFileFormat := FoxGenericObjectFile,
	Diagnostics, ObjectFile, Streams, Strings;

TYPE
	CodeGenerator = OBJECT (CodeGenerators.GenericCodeGenerator)
	VAR
		(* Virtual-register storage is sized from each procedure, including large
		   generated widget and raster initialization procedures. *)
		virtualRegisters: POINTER TO ARRAY OF SIGNED32;
		floatVirtualRegisters: POINTER TO ARRAY OF SIGNED32;
		virtualRegisterTypes, floatVirtualRegisterTypes: POINTER TO ARRAY OF IntermediateCode.Type;
		physicalRegisterOwners, floatPhysicalRegisterOwners: ARRAY 10 OF SIZE;
		localFrameSize: SIGNED32;
		integerSpillCount, floatSpillCount: SIGNED32;
		protectedRegister1, protectedRegister2, protectedRegister3: SIZE;
		pendingArguments: ARRAY 32 OF IntermediateCode.Operand;
		pendingArgumentCount: SIGNED32;
		savedPopCount, savedStackBytes, savedGroupCount: SIGNED32;
		savedGroupCounts, savedGroupPaddings, savedGroupOffsets: ARRAY 32 OF SIGNED32;

		PROCEDURE & Init(diagnostics: Diagnostics.Diagnostics; optimize: BOOLEAN);
		BEGIN
			InitGenerator(diagnostics, optimize)
		END Init;

		PROCEDURE Emit(word: SIGNED32);
		BEGIN
			out.PutDWord(word)
		END Emit;

		PROCEDURE Prepare*;
		VAR i, count: SIZE;
			PROCEDURE Count(CONST operand: IntermediateCode.Operand);
			BEGIN
				IF operand.register >= 0 THEN
					IF (operand.mode = IntermediateCode.ModeRegister) &
						(operand.type.form = IntermediateCode.Float)
					THEN
						IF operand.register + 1 > floatSpillCount THEN
							floatSpillCount := SIGNED32(operand.register + 1)
						END
					ELSIF operand.register + 1 > integerSpillCount THEN
						integerSpillCount := SIGNED32(operand.register + 1)
					END
				END
			END Count;
		BEGIN
			FOR i := 0 TO LEN(physicalRegisterOwners) - 1 DO
				physicalRegisterOwners[i] := -1; floatPhysicalRegisterOwners[i] := -1
			END;
			localFrameSize := 0;
			integerSpillCount := 0; floatSpillCount := 0;
			FOR i := 0 TO in.pc - 1 DO
				Count(in.instructions[i].op1);
				Count(in.instructions[i].op2);
				Count(in.instructions[i].op3)
			END;
			count := MAX(1, MAX(integerSpillCount, floatSpillCount));
			NEW(virtualRegisters, count); NEW(floatVirtualRegisters, count);
			NEW(virtualRegisterTypes, count); NEW(floatVirtualRegisterTypes, count);
			FOR i := 0 TO count - 1 DO
				virtualRegisters[i] := -1; floatVirtualRegisters[i] := -1
			END;
			protectedRegister1 := -1; protectedRegister2 := -1; protectedRegister3 := -1;
			pendingArgumentCount := 0;
			savedPopCount := 0;
			savedStackBytes := 0; savedGroupCount := 0
		END Prepare;

		PROCEDURE Protected(virtualRegister: SIZE): BOOLEAN;
		BEGIN
			RETURN (virtualRegister = protectedRegister1) OR
				(virtualRegister = protectedRegister2) OR
				(virtualRegister = protectedRegister3)
		END Protected;

		PROCEDURE PendingIntegerRegister(virtualRegister: SIZE): BOOLEAN;
		VAR i: SIGNED32; operand: IntermediateCode.Operand;
		BEGIN
			FOR i := 0 TO pendingArgumentCount - 1 DO
				operand := pendingArguments[i];
				IF (operand.register = virtualRegister) &
					((operand.mode = IntermediateCode.ModeMemory) OR
					 (operand.type.form # IntermediateCode.Float))
				THEN RETURN TRUE
				END
			END;
			RETURN FALSE
		END PendingIntegerRegister;

		PROCEDURE PendingFloatRegister(virtualRegister: SIZE): BOOLEAN;
		VAR i: SIGNED32; operand: IntermediateCode.Operand;
		BEGIN
			FOR i := 0 TO pendingArgumentCount - 1 DO
				operand := pendingArguments[i];
				IF (operand.register = virtualRegister) &
					(operand.mode = IntermediateCode.ModeRegister) &
					(operand.type.form = IntermediateCode.Float)
				THEN RETURN TRUE
				END
			END;
			RETURN FALSE
		END PendingFloatRegister;

		PROCEDURE IntegerSpillOffset(virtualRegister: SIZE): SIGNED32;
		BEGIN RETURN -(localFrameSize + SIGNED32((virtualRegister + 1) * 8))
		END IntegerSpillOffset;

		PROCEDURE FloatSpillOffset(virtualRegister: SIZE): SIGNED32;
		BEGIN RETURN -(localFrameSize + integerSpillCount * 8 + SIGNED32((virtualRegister + 1) * 8))
		END FloatSpillOffset;

		PROCEDURE QueuedArgumentOffset(index: SIGNED32): SIGNED32;
		BEGIN
			RETURN -(localFrameSize + (integerSpillCount + floatSpillCount +
				10 + index + 1) * 8)
		END QueuedArgumentOffset;

		PROCEDURE ReclaimDeadRegisters;
		VAR i: SIGNED32; owner: SIZE;
		BEGIN
			FOR i := 0 TO LEN(physicalRegisterOwners) - 1 DO
				owner := physicalRegisterOwners[i];
				IF (owner >= 0) & (LastUse(owner) < inPC) &
					~PendingIntegerRegister(owner)
				THEN
					IF virtualRegisters[owner] = InstructionSet.X19 + i THEN virtualRegisters[owner] := -1 END;
					physicalRegisterOwners[i] := -1
				END;
				owner := floatPhysicalRegisterOwners[i];
				IF (owner >= 0) & (LastUse(owner) < inPC) &
					~PendingFloatRegister(owner)
				THEN
					IF floatVirtualRegisters[owner] = 18 + i THEN floatVirtualRegisters[owner] := -1 END;
					floatPhysicalRegisterOwners[i] := -1
				END
			END
		END ReclaimDeadRegisters;

		PROCEDURE AllocateIntegerRegister(virtualRegister: SIZE;
			type: IntermediateCode.Type): SIGNED32;
		VAR i, victim, register: SIGNED32; owner, farthest: SIZE; wasSpilled, foundFree: BOOLEAN;
		BEGIN
			ReclaimDeadRegisters;
			wasSpilled := virtualRegisters[virtualRegister] = -2;
			victim := -1; farthest := 0; foundFree := FALSE;
			FOR i := 0 TO LEN(physicalRegisterOwners) - 1 DO
				owner := physicalRegisterOwners[i];
				IF (owner < 0) & ~foundFree THEN victim := i; foundFree := TRUE
				ELSIF ~foundFree & ~Protected(owner) & ((victim < 0) OR (LastUse(owner) > farthest)) THEN
					victim := i; farthest := LastUse(owner)
				END
			END;
			IF victim < 0 THEN Error(Basic.invalidPosition, "no spillable AArch64 integer register"); RETURN InstructionSet.X19 END;
			owner := physicalRegisterOwners[victim]; register := InstructionSet.X19 + victim;
			IF owner >= 0 THEN
				StoreMemory(register, InstructionSet.FP, IntegerSpillOffset(owner), virtualRegisterTypes[owner]);
				virtualRegisters[owner] := -2
			END;
			physicalRegisterOwners[victim] := virtualRegister;
			virtualRegisters[virtualRegister] := register;
			virtualRegisterTypes[virtualRegister] := type;
			IF wasSpilled THEN LoadMemory(register, InstructionSet.FP, IntegerSpillOffset(virtualRegister), type) END;
			RETURN register
		END AllocateIntegerRegister;

		PROCEDURE AllocateFloatRegister(virtualRegister: SIZE;
			type: IntermediateCode.Type): SIGNED32;
		VAR i, victim, register: SIGNED32; owner, farthest: SIZE; wasSpilled, foundFree: BOOLEAN;
		BEGIN
			ReclaimDeadRegisters;
			wasSpilled := floatVirtualRegisters[virtualRegister] = -2;
			victim := -1; farthest := 0; foundFree := FALSE;
			FOR i := 0 TO LEN(floatPhysicalRegisterOwners) - 1 DO
				owner := floatPhysicalRegisterOwners[i];
				IF (owner < 0) & ~foundFree THEN victim := i; foundFree := TRUE
				ELSIF ~foundFree & ~Protected(owner) & ((victim < 0) OR (LastUse(owner) > farthest)) THEN
					victim := i; farthest := LastUse(owner)
				END
			END;
			IF victim < 0 THEN Error(Basic.invalidPosition, "no spillable AArch64 float register"); RETURN 18 END;
			owner := floatPhysicalRegisterOwners[victim]; register := 18 + victim;
			IF owner >= 0 THEN
				StoreFloatMemory(register, InstructionSet.FP, FloatSpillOffset(owner), floatVirtualRegisterTypes[owner]);
				floatVirtualRegisters[owner] := -2
			END;
			floatPhysicalRegisterOwners[victim] := virtualRegister;
			floatVirtualRegisters[virtualRegister] := register;
			floatVirtualRegisterTypes[virtualRegister] := type;
			IF wasSpilled THEN LoadFloatMemory(register, InstructionSet.FP, FloatSpillOffset(virtualRegister), type) END;
			RETURN register
		END AllocateFloatRegister;

		PROCEDURE EmitAddress(destination: SIGNED32; CONST operand: IntermediateCode.Operand);
		VAR pattern: BinaryCode.FixupPatterns; fixup: BinaryCode.Fixup;
		BEGIN
			ASSERT(operand.symbol.name # "");
			(* Keep the runtime relocation on a pointer-sized literal. The LDR is
			   PC-relative and the branch skips the embedded address. *)
			NEW(pattern, 1);
			pattern[0].offset := 0; pattern[0].bits := 64;
			fixup := BinaryCode.NewFixup(BinaryCode.Absolute, out.pc + 8, operand.symbol,
				operand.symbolOffset, operand.offset, 0, pattern);
			out.fixupList.AddFixup(fixup);
			Emit(InstructionSet.LdrLiteral64(destination, 8));
			Emit(InstructionSet.B(12));
			out.PutQWord(0)
		END EmitAddress;

		PROCEDURE DestinationRegister(CONST operand: IntermediateCode.Operand;
			position: Basic.Position): SIGNED32;
		VAR register: SIGNED32;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.register >= 0) & (operand.register < LEN(virtualRegisters))
			THEN
				register := virtualRegisters[operand.register];
				IF register < 0 THEN
					register := AllocateIntegerRegister(operand.register, operand.type)
				END;
				RETURN register
			END;
			Error(position, "register destination expected by AArch64 lowering");
			RETURN InstructionSet.X16
		END DestinationRegister;

		PROCEDURE DestinationFloatRegister(CONST operand: IntermediateCode.Operand;
			position: Basic.Position): SIGNED32;
		VAR register: SIGNED32;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.register >= 0) & (operand.register < LEN(floatVirtualRegisters))
			THEN
				register := floatVirtualRegisters[operand.register];
				IF register < 0 THEN
					register := AllocateFloatRegister(operand.register, operand.type)
				END;
				RETURN register
			END;
			Error(position, "floating register destination expected by AArch64 lowering");
			RETURN 16
		END DestinationFloatRegister;

		PROCEDURE AdjustAddress(destination, address, offset: SIGNED32);
		VAR magnitude, pages: SIGNED32; subtract: BOOLEAN;
		BEGIN
			subtract := offset < 0;
			IF subtract THEN magnitude := -offset ELSE magnitude := offset END;
			IF destination # address THEN
				IF address = InstructionSet.SP THEN
					Emit(InstructionSet.AddImmediate64(destination, InstructionSet.SP, 0, FALSE))
				ELSE Emit(InstructionSet.MovRegister64(destination, address))
				END
			END;
			WHILE magnitude >= 4096 DO
				pages := magnitude DIV 4096;
				IF pages > 4095 THEN pages := 4095 END;
				IF subtract THEN
					Emit(InstructionSet.SubImmediate64(destination, destination, pages, TRUE))
				ELSE
					Emit(InstructionSet.AddImmediate64(destination, destination, pages, TRUE))
				END;
				DEC(magnitude, pages * 4096)
			END;
			IF magnitude > 0 THEN
				IF subtract THEN
					Emit(InstructionSet.SubImmediate64(destination, destination, magnitude, FALSE))
				ELSE
					Emit(InstructionSet.AddImmediate64(destination, destination, magnitude, FALSE))
				END
			END
		END AdjustAddress;

		PROCEDURE LoadMemory(destination, address, offset: SIGNED32;
			type: IntermediateCode.Type);
		VAR bits, bytes: SIGNED32;
		BEGIN
			bits := type.sizeInBits;
			bytes := bits DIV 8;
			IF ~((-256 <= offset) & (offset <= 255)) &
				~((offset >= 0) & (bytes > 0) & (offset MOD bytes = 0) &
				(offset DIV bytes < 4096))
			THEN
				AdjustAddress(InstructionSet.X17, address, offset);
				address := InstructionSet.X17;
				offset := 0
			END;
			IF bits = 8 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Ldur8(destination, address, offset))
				ELSE Emit(InstructionSet.LdrUnsigned8(destination, address, offset))
				END
			ELSIF bits = 16 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Ldur16(destination, address, offset))
				ELSE Emit(InstructionSet.LdrUnsigned16(destination, address, offset))
				END
			ELSIF bits = 32 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Ldur32(destination, address, offset))
				ELSE Emit(InstructionSet.LdrUnsigned32(destination, address, offset))
				END
			ELSE
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Ldur64(destination, address, offset))
				ELSE Emit(InstructionSet.LdrUnsigned64(destination, address, offset))
				END
			END;
			IF (type.form = IntermediateCode.SignedInteger) & (bits < 64) THEN
				Emit(InstructionSet.SignExtend64(destination, destination, bits))
			END
		END LoadMemory;

		PROCEDURE StoreMemory(source, address, offset: SIGNED32; type: IntermediateCode.Type);
		VAR bits, bytes: SIGNED32;
		BEGIN
			bits := type.sizeInBits;
			bytes := bits DIV 8;
			IF ~((-256 <= offset) & (offset <= 255)) &
				~((offset >= 0) & (bytes > 0) & (offset MOD bytes = 0) &
				(offset DIV bytes < 4096))
			THEN
				AdjustAddress(InstructionSet.X17, address, offset);
				address := InstructionSet.X17;
				offset := 0
			END;
			IF bits = 8 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Stur8(source, address, offset))
				ELSE Emit(InstructionSet.StrUnsigned8(source, address, offset))
				END
			ELSIF bits = 16 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Stur16(source, address, offset))
				ELSE Emit(InstructionSet.StrUnsigned16(source, address, offset))
				END
			ELSIF bits = 32 THEN
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Stur32(source, address, offset))
				ELSE Emit(InstructionSet.StrUnsigned32(source, address, offset))
				END
			ELSE
				IF (offset >= -256) & (offset <= 255) THEN
					Emit(InstructionSet.Stur64(source, address, offset))
				ELSE Emit(InstructionSet.StrUnsigned64(source, address, offset))
				END
			END
		END StoreMemory;

		PROCEDURE LoadFloatMemory(destination, address, offset: SIGNED32;
			type: IntermediateCode.Type);
		VAR bytes: SIGNED32;
		BEGIN
			bytes := type.sizeInBits DIV 8;
			IF ~((-256 <= offset) & (offset <= 255)) &
				~((offset >= 0) & (offset MOD bytes = 0) & (offset DIV bytes < 4096))
			THEN
				AdjustAddress(InstructionSet.X17, address, offset);
				address := InstructionSet.X17; offset := 0
			END;
			IF type.sizeInBits = 32 THEN
				IF (-256 <= offset) & (offset <= 255) THEN
					Emit(InstructionSet.LdurFloat32(destination, address, offset))
				ELSE Emit(InstructionSet.LdrFloat32(destination, address, offset))
				END
			ELSE
				IF (-256 <= offset) & (offset <= 255) THEN
					Emit(InstructionSet.LdurFloat64(destination, address, offset))
				ELSE Emit(InstructionSet.LdrFloat64(destination, address, offset))
				END
			END
		END LoadFloatMemory;

		PROCEDURE StoreFloatMemory(source, address, offset: SIGNED32;
			type: IntermediateCode.Type);
		VAR bytes: SIGNED32;
		BEGIN
			bytes := type.sizeInBits DIV 8;
			IF ~((-256 <= offset) & (offset <= 255)) &
				~((offset >= 0) & (offset MOD bytes = 0) & (offset DIV bytes < 4096))
			THEN
				AdjustAddress(InstructionSet.X17, address, offset);
				address := InstructionSet.X17; offset := 0
			END;
			IF type.sizeInBits = 32 THEN
				IF (-256 <= offset) & (offset <= 255) THEN
					Emit(InstructionSet.SturFloat32(source, address, offset))
				ELSE Emit(InstructionSet.StrFloat32(source, address, offset))
				END
			ELSE
				IF (-256 <= offset) & (offset <= 255) THEN
					Emit(InstructionSet.SturFloat64(source, address, offset))
				ELSE Emit(InstructionSet.StrFloat64(source, address, offset))
				END
			END
		END StoreFloatMemory;

		PROCEDURE FloatOperandRegister(CONST operand: IntermediateCode.Operand;
			scratch: SIGNED32; position: Basic.Position): SIGNED32;
		VAR bits: SIGNED64; address: SIGNED32; addressType: IntermediateCode.Type;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeImmediate) & (operand.symbol.name = "") THEN
				IF operand.type.sizeInBits = 32 THEN
					EmitConstant(InstructionSet.X16, BinaryCode.ConvertReal(FLOAT32(operand.floatValue)));
					Emit(InstructionSet.FmovToFloat32(scratch, InstructionSet.X16))
				ELSE
					bits := BinaryCode.ConvertLongreal(operand.floatValue);
					EmitConstant(InstructionSet.X16, bits);
					Emit(InstructionSet.FmovToFloat64(scratch, InstructionSet.X16))
				END;
				RETURN scratch
			ELSIF operand.mode = IntermediateCode.ModeMemory THEN
				IF operand.symbol.name # "" THEN
					EmitAddress(InstructionSet.X16, operand); address := InstructionSet.X16
				ELSIF operand.register = IntermediateCode.FP THEN address := InstructionSet.FP
				ELSIF operand.register = IntermediateCode.SP THEN address := InstructionSet.SP
				ELSIF (operand.register >= 0) & (operand.register < LEN(virtualRegisters)) THEN
					address := virtualRegisters[operand.register];
					IF address < 0 THEN
						addressType := IntermediateCode.GetType(module.system, module.system.addressType);
						address := AllocateIntegerRegister(operand.register, addressType)
					END
				ELSE Error(position, "floating memory operand address unsupported"); RETURN scratch
				END;
				IF operand.symbol.name # "" THEN
					LoadFloatMemory(scratch, address, 0, operand.type)
				ELSE LoadFloatMemory(scratch, address, SIGNED32(operand.offset), operand.type)
				END;
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.registerClass.class = IntermediateCode.Parameter)
			THEN RETURN operand.registerClass.number
			ELSIF (operand.mode = IntermediateCode.ModeRegister) & (operand.register >= 0) &
				(operand.register < LEN(floatVirtualRegisters))
			THEN
				IF floatVirtualRegisters[operand.register] < 0 THEN
					RETURN AllocateFloatRegister(operand.register, operand.type)
				ELSE RETURN floatVirtualRegisters[operand.register]
				END
			END;
			Error(position, "floating operand not supported by initial AArch64 lowering");
			RETURN scratch
		END FloatOperandRegister;

		PROCEDURE EmitFloatMove(CONST destination, source: IntermediateCode.Operand;
			position: Basic.Position);
		VAR destinationRegister, sourceRegister, address, offset: SIGNED32; addressType: IntermediateCode.Type;
		BEGIN
			IF destination.mode = IntermediateCode.ModeMemory THEN
				sourceRegister := FloatOperandRegister(source, 16, position);
				IF destination.symbol.name # "" THEN
					EmitAddress(InstructionSet.X17, destination); address := InstructionSet.X17; offset := 0
				ELSIF destination.register = IntermediateCode.FP THEN
					address := InstructionSet.FP; offset := SIGNED32(destination.offset)
				ELSIF destination.register = IntermediateCode.SP THEN
					address := InstructionSet.SP; offset := SIGNED32(destination.offset)
				ELSIF (destination.register >= 0) & (destination.register < LEN(virtualRegisters)) THEN
					address := virtualRegisters[destination.register];
					IF address < 0 THEN
						addressType := IntermediateCode.GetType(module.system, module.system.addressType);
						address := AllocateIntegerRegister(destination.register, addressType)
					END;
					offset := SIGNED32(destination.offset)
				ELSE Error(position, "floating memory destination unsupported"); RETURN
				END;
				StoreFloatMemory(sourceRegister, address, offset, destination.type); RETURN
			END;
			IF (destination.mode = IntermediateCode.ModeRegister) &
				(destination.registerClass.class = IntermediateCode.Parameter)
			THEN destinationRegister := destination.registerClass.number
			ELSE destinationRegister := DestinationFloatRegister(destination, position)
			END;
			sourceRegister := FloatOperandRegister(source, destinationRegister, position);
			IF sourceRegister # destinationRegister THEN
				IF destination.type.sizeInBits = 32 THEN
					Emit(InstructionSet.FmovFloat32(destinationRegister, sourceRegister))
				ELSE Emit(InstructionSet.FmovFloat64(destinationRegister, sourceRegister))
				END
			END
		END EmitFloatMove;

		PROCEDURE EmitConstant(destination: SIGNED32; value: SIGNED64);
		VAR part, shift: SIGNED32;
		BEGIN
			part := SHORT(value MOD 10000H);
			IF part < 0 THEN INC(part, 10000H) END;
			Emit(InstructionSet.MovZ64(destination, part, 0));
			FOR shift := 16 TO 48 BY 16 DO
				value := value DIV 10000H;
				part := SHORT(value MOD 10000H);
				IF part < 0 THEN INC(part, 10000H) END;
				IF part # 0 THEN Emit(InstructionSet.MovK64(destination, part, shift)) END
			END
		END EmitConstant;

		PROCEDURE OperandRegister(CONST operand: IntermediateCode.Operand; scratch: SIGNED32;
			position: Basic.Position): SIGNED32;
		VAR address, register: SIGNED32; addressType: IntermediateCode.Type;
		BEGIN
			IF operand.mode = IntermediateCode.ModeImmediate THEN
				IF operand.symbol.name # "" THEN EmitAddress(scratch, operand)
				ELSE EmitConstant(scratch, operand.intValue)
				END;
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) &
				(operand.register = IntermediateCode.None) & (operand.symbol.name = "")
			THEN
				EmitConstant(scratch, operand.intValue + operand.offset);
				LoadMemory(scratch, scratch, 0, operand.type);
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) & (operand.symbol.name # "") THEN
				EmitAddress(scratch, operand);
				LoadMemory(scratch, scratch, 0, operand.type);
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) &
				(operand.register = IntermediateCode.FP)
			THEN
				LoadMemory(scratch, InstructionSet.FP, SIGNED32(operand.offset), operand.type);
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) &
				(operand.register = IntermediateCode.SP)
			THEN
				LoadMemory(scratch, InstructionSet.SP, SIGNED32(operand.offset), operand.type);
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) &
				(operand.register >= 0) & (operand.register < LEN(virtualRegisters))
			THEN
				address := virtualRegisters[operand.register];
				IF address < 0 THEN
					addressType := IntermediateCode.GetType(module.system, module.system.addressType);
					address := AllocateIntegerRegister(operand.register, addressType)
				END;
				LoadMemory(scratch, address, SIGNED32(operand.offset), operand.type);
				RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.registerClass.class = IntermediateCode.Parameter)
			THEN
				register := operand.registerClass.number;
				IF operand.offset # 0 THEN
					AdjustAddress(scratch, register, SIGNED32(operand.offset));
					RETURN scratch
				ELSE RETURN register
				END
			ELSIF (operand.mode = IntermediateCode.ModeRegister) &
				((operand.register = IntermediateCode.FP) OR (operand.register = IntermediateCode.SP))
			THEN
				IF operand.register = IntermediateCode.SP THEN
					(* Register 31 denotes zero in arithmetic/store register operands.
					   Materialize SP with ADD before using it as an ordinary value. *)
					AdjustAddress(scratch, InstructionSet.SP, SIGNED32(operand.offset));
					RETURN scratch
				ELSIF operand.offset # 0 THEN
					AdjustAddress(scratch, InstructionSet.FP, SIGNED32(operand.offset));
					RETURN scratch
				ELSE RETURN InstructionSet.FP
				END
			ELSIF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.register >= 0) & (operand.register < LEN(virtualRegisters))
			THEN
				register := virtualRegisters[operand.register];
				IF register < 0 THEN register := AllocateIntegerRegister(operand.register, operand.type) END;
				IF operand.offset # 0 THEN
					AdjustAddress(scratch, register, SIGNED32(operand.offset));
					RETURN scratch
				ELSE RETURN register
				END
			END;
			Error(position, "operand not supported by initial AArch64 lowering");
			RETURN scratch
		END OperandRegister;

		PROCEDURE OperandAddress(CONST operand: IntermediateCode.Operand; scratch: SIGNED32;
			position: Basic.Position): SIGNED32;
		VAR base: SIGNED32; addressType: IntermediateCode.Type;
		BEGIN
			IF operand.symbol.name # "" THEN
				EmitAddress(scratch, operand); RETURN scratch
			ELSIF (operand.mode = IntermediateCode.ModeMemory) &
				(operand.register = IntermediateCode.None)
			THEN
				EmitConstant(scratch, operand.intValue + operand.offset);
				RETURN scratch
			ELSIF operand.mode = IntermediateCode.ModeMemory THEN
				IF operand.register = IntermediateCode.FP THEN base := InstructionSet.FP
				ELSIF operand.register = IntermediateCode.SP THEN base := InstructionSet.SP
				ELSIF (operand.register >= 0) & (operand.register < LEN(virtualRegisters)) THEN
					base := virtualRegisters[operand.register];
					IF base < 0 THEN
						addressType := IntermediateCode.GetType(module.system, module.system.addressType);
						base := AllocateIntegerRegister(operand.register, addressType)
					END
				ELSE Error(position, "memory address not supported by AArch64 lowering"); RETURN scratch
				END;
				AdjustAddress(scratch, base, SIGNED32(operand.offset));
				RETURN scratch
			ELSIF operand.mode = IntermediateCode.ModeRegister THEN
				base := OperandRegister(operand, scratch, position);
				IF base # scratch THEN AdjustAddress(scratch, base, 0) END;
				RETURN scratch
			END;
			Error(position, "address operand not supported by AArch64 lowering");
			RETURN scratch
		END OperandAddress;

		PROCEDURE RememberParameter(CONST destination, source: IntermediateCode.Operand;
			position: Basic.Position);
		VAR destinationRegister, sourceRegister, addressRegister, offset: SIGNED32;
			addressType: IntermediateCode.Type;
		BEGIN
			IF (destination.type.form = IntermediateCode.Float) #
				(source.type.form = IntermediateCode.Float)
			THEN
				(* A same-size MOV across integer and floating register classes is
				   a bit reinterpretation (SYSTEM.VAL), not a numeric conversion. *)
				IF destination.mode # IntermediateCode.ModeRegister THEN
					Error(position, "bit reinterpretation destination must be a register"); RETURN
				END;
				IF destination.type.form = IntermediateCode.Float THEN
					IF destination.registerClass.class = IntermediateCode.Parameter THEN
						destinationRegister := destination.registerClass.number
					ELSE destinationRegister := DestinationFloatRegister(destination, position)
					END;
					sourceRegister := OperandRegister(source, InstructionSet.X16, position);
					IF destination.type.sizeInBits = 32 THEN
						Emit(InstructionSet.FmovToFloat32(destinationRegister, sourceRegister))
					ELSE Emit(InstructionSet.FmovToFloat64(destinationRegister, sourceRegister))
					END
				ELSE
					IF destination.registerClass.class = IntermediateCode.Parameter THEN
						destinationRegister := destination.registerClass.number
					ELSE destinationRegister := DestinationRegister(destination, position)
					END;
					sourceRegister := FloatOperandRegister(source, 16, position);
					IF source.type.sizeInBits = 32 THEN
						Emit(InstructionSet.FmovFromFloat32(destinationRegister, sourceRegister))
					ELSE Emit(InstructionSet.FmovFromFloat64(destinationRegister, sourceRegister))
					END;
					NormalizeInteger(destinationRegister, destination.type)
				END;
				RETURN
			END;
			IF (destination.type.form = IntermediateCode.Float) OR
				(source.type.form = IntermediateCode.Float)
			THEN EmitFloatMove(destination, source, position); RETURN
			END;
			IF (destination.mode = IntermediateCode.ModeRegister) &
				(destination.register = IntermediateCode.SP)
			THEN
				sourceRegister := OperandRegister(source, InstructionSet.X16, position);
				(* Generic value-array copies align to eight bytes. Darwin arm64
				   requires sixteen-byte SP alignment, including across calls. *)
				EmitConstant(InstructionSet.X12, -16);
				Emit(InstructionSet.AndRegister64(InstructionSet.X16, sourceRegister, InstructionSet.X12));
				Emit(InstructionSet.AddImmediate64(InstructionSet.SP, InstructionSet.X16, 0, FALSE));
				RETURN
			END;
			IF destination.mode = IntermediateCode.ModeMemory THEN
				IF (source.mode = IntermediateCode.ModeImmediate) & (source.symbol.name # "") THEN
					EmitAddress(InstructionSet.X16, source);
					sourceRegister := InstructionSet.X16
				ELSIF source.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X16, source.intValue);
					sourceRegister := InstructionSet.X16
				ELSE
					sourceRegister := OperandRegister(source, InstructionSet.X16, position)
				END;
				IF destination.symbol.name # "" THEN
					EmitAddress(InstructionSet.X17, destination);
					addressRegister := InstructionSet.X17; offset := 0
				ELSIF destination.register = IntermediateCode.FP THEN
					addressRegister := InstructionSet.FP; offset := SIGNED32(destination.offset)
				ELSIF destination.register = IntermediateCode.SP THEN
					addressRegister := InstructionSet.SP; offset := SIGNED32(destination.offset)
				ELSIF (destination.register >= 0) &
					(destination.register < LEN(virtualRegisters))
				THEN
					addressRegister := virtualRegisters[destination.register];
					IF addressRegister < 0 THEN
						addressType := IntermediateCode.GetType(module.system, module.system.addressType);
						addressRegister := AllocateIntegerRegister(destination.register, addressType)
					END;
					offset := SIGNED32(destination.offset)
				ELSE
					Error(position, "memory destination not supported by AArch64 lowering"); RETURN
				END;
				StoreMemory(sourceRegister, addressRegister, offset, destination.type);
				RETURN
			END;

			IF (destination.mode = IntermediateCode.ModeRegister) &
				(destination.registerClass.class = IntermediateCode.Parameter)
			THEN
				destinationRegister := destination.registerClass.number;
			ELSIF (destination.mode = IntermediateCode.ModeRegister) &
				(destination.register >= 0) & (destination.register < LEN(virtualRegisters))
			THEN
				destinationRegister := DestinationRegister(destination, position)
			ELSIF (destination.mode = IntermediateCode.ModeRegister) &
				(source.mode = IntermediateCode.ModeRegister) &
				(((destination.register = IntermediateCode.FP) & (source.register = IntermediateCode.SP)) OR
				 ((destination.register = IntermediateCode.SP) & (source.register = IntermediateCode.FP)))
			THEN
				(* Frame setup and teardown are emitted by enter and exit. *)
				RETURN
			ELSE
				Error(position, "move destination not supported by AArch64 lowering"); RETURN
			END;

			IF (source.mode = IntermediateCode.ModeRegister) & (source.register = IntermediateCode.SP) THEN
				IF destinationRegister # InstructionSet.SP THEN
					(* Register 31 is SP only for the add/sub family; the MOV alias
					   would read XZR here. *)
					Emit(InstructionSet.AddImmediate64(destinationRegister,
						InstructionSet.SP, 0, FALSE))
				END;
				RETURN
			ELSIF (source.mode = IntermediateCode.ModeImmediate) & (source.symbol.name # "") THEN
				EmitAddress(destinationRegister, source)
			ELSIF source.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(destinationRegister, source.intValue)
			ELSE
				sourceRegister := OperandRegister(source, destinationRegister, position);
				IF sourceRegister # destinationRegister THEN
					Emit(InstructionSet.MovRegister64(destinationRegister, sourceRegister))
				END
			END
		END RememberParameter;

		PROCEDURE EmitFloatArithmetic(CONST instruction: IntermediateCode.Instruction);
		VAR destination, left, right: SIGNED32;
		BEGIN
			destination := DestinationFloatRegister(instruction.op1, instruction.textPosition);
			left := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
			right := FloatOperandRegister(instruction.op3, 17, instruction.textPosition);
			IF instruction.op1.type.sizeInBits = 32 THEN
				IF instruction.opcode = IntermediateCode.add THEN
					Emit(InstructionSet.Fadd32(destination, left, right))
				ELSE Emit(InstructionSet.Fsub32(destination, left, right))
				END
			ELSE
				IF instruction.opcode = IntermediateCode.add THEN
					Emit(InstructionSet.Fadd64(destination, left, right))
				ELSE Emit(InstructionSet.Fsub64(destination, left, right))
				END
			END
		END EmitFloatArithmetic;

		PROCEDURE RecordSavedGroup(count, padding: SIGNED32; position: Basic.Position);
		BEGIN
			IF count <= 0 THEN RETURN END;
			IF savedGroupCount >= LEN(savedGroupCounts) THEN
				Error(position, "too many nested saved stack groups"); RETURN
			END;
			savedGroupCounts[savedGroupCount] := count;
			savedGroupPaddings[savedGroupCount] := padding;
			savedGroupOffsets[savedGroupCount] := 0;
			INC(savedGroupCount); INC(savedPopCount, count);
			INC(savedStackBytes, count * 8 + padding)
		END RecordSavedGroup;

		PROCEDURE ConsumeSavedValues(count: SIGNED32): SIGNED32;
		VAR take, bytes, top, groupBytes: SIGNED32;
		BEGIN
			bytes := 0;
			WHILE (count > 0) & (savedGroupCount > 0) DO
				top := savedGroupCount - 1; take := count;
				IF take > savedGroupCounts[top] THEN take := savedGroupCounts[top] END;
				DEC(savedGroupCounts[top], take); DEC(savedPopCount, take);
				INC(savedGroupOffsets[top], take * 8); DEC(count, take);
				IF savedGroupCounts[top] = 0 THEN
					groupBytes := savedGroupOffsets[top] + savedGroupPaddings[top];
					INC(bytes, groupBytes); DEC(savedStackBytes, groupBytes);
					DEC(savedGroupCount)
				END
			END;
			RETURN bytes
		END ConsumeSavedValues;

		PROCEDURE SavedValueOffset(index: SIGNED32): SIGNED32;
		VAR group, base, available: SIGNED32;
		BEGIN
			group := savedGroupCount - 1; base := 0;
			WHILE group >= 0 DO
				available := savedGroupCounts[group];
				IF index < available THEN
					RETURN base + savedGroupOffsets[group] + index * 8
				END;
				DEC(index, available);
				INC(base, savedGroupOffsets[group] + available * 8 + savedGroupPaddings[group]);
				DEC(group)
			END;
			RETURN base
		END SavedValueOffset;

		PROCEDURE FlushPendingValues(position: Basic.Position);
		VAR i, offset, allocation, source: SIGNED32; operand: IntermediateCode.Operand;
		BEGIN
			IF pendingArgumentCount = 0 THEN RETURN END;
			allocation := ((pendingArgumentCount * 8 + 15) DIV 16) * 16;
			EmitStackSubtract(allocation);
			FOR i := 0 TO pendingArgumentCount - 1 DO
				operand := pendingArguments[i]; offset := (pendingArgumentCount - i - 1) * 8;
				IF operand.type.form = IntermediateCode.Float THEN
					source := FloatOperandRegister(operand, 16, position);
					IF operand.type.sizeInBits = 32 THEN
						Emit(InstructionSet.StrFloat32(source, InstructionSet.SP, offset))
					ELSE Emit(InstructionSet.StrFloat64(source, InstructionSet.SP, offset))
					END
				ELSIF (operand.mode = IntermediateCode.ModeImmediate) & (operand.symbol.name # "") THEN
					EmitAddress(InstructionSet.X9, operand); source := InstructionSet.X9
				ELSIF operand.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X9, operand.intValue); source := InstructionSet.X9
				ELSE source := OperandRegister(operand, InstructionSet.X9, position)
				END;
				IF operand.type.form # IntermediateCode.Float THEN
					Emit(InstructionSet.StrUnsigned64(source, InstructionSet.SP, offset))
				END
			END;
			RecordSavedGroup(pendingArgumentCount,
				allocation - pendingArgumentCount * 8, position);
			pendingArgumentCount := 0
		END FlushPendingValues;

		PROCEDURE NormalizeInteger(register: SIGNED32; type: IntermediateCode.Type);
		VAR bits: SIGNED32;
		BEGIN
			bits := type.sizeInBits;
			IF (type.form IN IntermediateCode.Integer) & (bits < 64) THEN
				IF type.form = IntermediateCode.SignedInteger THEN
					Emit(InstructionSet.SignExtend64(register, register, bits))
				ELSIF bits = 32 THEN
					Emit(InstructionSet.ZeroExtend32To64(register, register))
				ELSE
					EmitConstant(InstructionSet.X12, ASH(SIGNED64(1), bits) - 1);
					Emit(InstructionSet.AndRegister64(register, register, InstructionSet.X12))
				END
			END
		END NormalizeInteger;

		PROCEDURE EmitArithmetic(VAR instruction: IntermediateCode.Instruction);
		VAR destination, left, right, address, offset, bits, amount: SIGNED32;
			memoryDestination: BOOLEAN; addressType: IntermediateCode.Type;
		BEGIN
			IF instruction.op1.type.form = IntermediateCode.Float THEN
				EmitFloatArithmetic(instruction); RETURN
			END;
			IF (instruction.op1.mode = IntermediateCode.ModeRegister) &
				(instruction.op1.register = IntermediateCode.SP)
			THEN
				IF (instruction.op3.mode = IntermediateCode.ModeImmediate) &
					(instruction.op3.intValue >= 0)
				THEN
					amount := SHORT(instruction.op3.intValue);
					IF instruction.opcode = IntermediateCode.sub THEN
						FlushPendingValues(instruction.textPosition);
						bits := ((amount + 15) DIV 16) * 16;
						EmitStackSubtract(bits);
						(* A by-value record is another stack group. Keeping it in
						   order with scalar pushes lets calls remove alignment gaps
						   without moving an intervening scalar into a record. *)
						RecordSavedGroup(amount DIV 8, bits - amount, instruction.textPosition)
					ELSIF amount DIV 8 <= savedPopCount THEN
						amount := ConsumeSavedValues(amount DIV 8);
						AdjustAddress(InstructionSet.SP, InstructionSet.SP, amount)
					END
				END;
				RETURN
			END;
			memoryDestination := instruction.op1.mode = IntermediateCode.ModeMemory;
			IF memoryDestination THEN
				destination := InstructionSet.X16
			ELSIF instruction.op1.mode = IntermediateCode.ModeRegister THEN
				destination := DestinationRegister(instruction.op1, instruction.textPosition)
			ELSE
				Error(instruction.textPosition, "arithmetic destination not supported by initial AArch64 backend");
				RETURN
			END;
			bits := instruction.op1.type.sizeInBits;
			IF instruction.op2.mode = IntermediateCode.ModeImmediate THEN
				IF instruction.op2.symbol.name # "" THEN
					EmitAddress(InstructionSet.X16, instruction.op2)
				ELSE
					EmitConstant(InstructionSet.X16, instruction.op2.intValue)
				END;
				left := InstructionSet.X16
			ELSE
				left := OperandRegister(instruction.op2, InstructionSet.X16,
					instruction.textPosition)
			END;
			IF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
				IF instruction.op3.symbol.name # "" THEN
					EmitAddress(InstructionSet.X17, instruction.op3);
					right := InstructionSet.X17;
					IF (bits = 32) & (instruction.opcode = IntermediateCode.add) THEN
						Emit(InstructionSet.AddRegister32(destination, left, right))
					ELSIF instruction.opcode = IntermediateCode.add THEN
						Emit(InstructionSet.AddRegister64(destination, left, right))
					ELSIF bits = 32 THEN Emit(InstructionSet.SubRegister32(destination, left, right))
					ELSE Emit(InstructionSet.SubRegister64(destination, left, right))
					END
				ELSIF (instruction.op3.intValue >= 0) &
					(instruction.op3.intValue < 4096)
				THEN
					IF bits = 32 THEN
						IF instruction.opcode = IntermediateCode.add THEN
							Emit(InstructionSet.AddImmediate32(destination, left, SHORT(instruction.op3.intValue), FALSE))
						ELSE
							Emit(InstructionSet.SubImmediate32(destination, left, SHORT(instruction.op3.intValue), FALSE))
						END
					ELSIF instruction.opcode = IntermediateCode.add THEN
						Emit(InstructionSet.AddImmediate64(destination, left, SHORT(instruction.op3.intValue), FALSE))
					ELSE
						Emit(InstructionSet.SubImmediate64(destination, left, SHORT(instruction.op3.intValue), FALSE))
					END
				ELSE
					EmitConstant(InstructionSet.X17, instruction.op3.intValue);
					right := InstructionSet.X17;
					IF (bits = 32) & (instruction.opcode = IntermediateCode.add) THEN
						Emit(InstructionSet.AddRegister32(destination, left, right))
					ELSIF instruction.opcode = IntermediateCode.add THEN
						Emit(InstructionSet.AddRegister64(destination, left, right))
					ELSIF bits = 32 THEN Emit(InstructionSet.SubRegister32(destination, left, right))
					ELSE Emit(InstructionSet.SubRegister64(destination, left, right))
					END
				END
			ELSE
				right := OperandRegister(instruction.op3, InstructionSet.X17, instruction.textPosition);
				IF (bits = 32) & (instruction.opcode = IntermediateCode.add) THEN
					Emit(InstructionSet.AddRegister32(destination, left, right))
				ELSIF instruction.opcode = IntermediateCode.add THEN
					Emit(InstructionSet.AddRegister64(destination, left, right))
				ELSIF bits = 32 THEN
					Emit(InstructionSet.SubRegister32(destination, left, right))
				ELSE
					Emit(InstructionSet.SubRegister64(destination, left, right))
				END
			END;
			NormalizeInteger(destination, instruction.op1.type);
			IF memoryDestination THEN
				IF instruction.op1.symbol.name # "" THEN
					EmitAddress(InstructionSet.X17, instruction.op1); address := InstructionSet.X17; offset := 0
				ELSIF instruction.op1.register = IntermediateCode.FP THEN
					address := InstructionSet.FP; offset := SIGNED32(instruction.op1.offset)
				ELSIF instruction.op1.register >= 0 THEN
					address := virtualRegisters[instruction.op1.register];
					IF address < 0 THEN
						addressType := IntermediateCode.GetType(module.system, module.system.addressType);
						address := AllocateIntegerRegister(instruction.op1.register, addressType)
					END;
					offset := SIGNED32(instruction.op1.offset)
				ELSE Error(instruction.textPosition, "arithmetic memory destination address unsupported"); RETURN
				END;
				StoreMemory(destination, address, offset, instruction.op1.type)
			END
		END EmitArithmetic;

		PROCEDURE EmitConversion(CONST instruction: IntermediateCode.Instruction);
		VAR destination, source, sourceBits, destinationBits: SIGNED32;
		BEGIN
			IF (instruction.op1.type.form = IntermediateCode.Float) &
				(instruction.op2.type.form = IntermediateCode.Float)
			THEN
				destination := DestinationFloatRegister(instruction.op1, instruction.textPosition);
				source := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
				IF instruction.op1.type.sizeInBits = instruction.op2.type.sizeInBits THEN
					IF instruction.op1.type.sizeInBits = 32 THEN
						Emit(InstructionSet.FmovFloat32(destination, source))
					ELSE Emit(InstructionSet.FmovFloat64(destination, source))
					END
				ELSIF instruction.op1.type.sizeInBits = 64 THEN
					Emit(InstructionSet.Fcvt64From32(destination, source))
				ELSE Emit(InstructionSet.Fcvt32From64(destination, source))
				END;
				RETURN
			ELSIF instruction.op1.type.form = IntermediateCode.Float THEN
				destination := DestinationFloatRegister(instruction.op1, instruction.textPosition);
				source := OperandRegister(instruction.op2, InstructionSet.X16, instruction.textPosition);
				IF instruction.op2.type.form = IntermediateCode.SignedInteger THEN
					IF instruction.op1.type.sizeInBits = 32 THEN
						IF instruction.op2.type.sizeInBits <= 32 THEN
							Emit(InstructionSet.Scvtf32From32(destination, source))
						ELSE Emit(InstructionSet.Scvtf32From64(destination, source))
						END
					ELSIF instruction.op2.type.sizeInBits <= 32 THEN
						Emit(InstructionSet.Scvtf64From32(destination, source))
					ELSE Emit(InstructionSet.Scvtf64From64(destination, source))
					END
				ELSE
					IF instruction.op1.type.sizeInBits = 32 THEN
						IF instruction.op2.type.sizeInBits <= 32 THEN
							Emit(InstructionSet.Ucvtf32From32(destination, source))
						ELSE Emit(InstructionSet.Ucvtf32From64(destination, source))
						END
					ELSIF instruction.op2.type.sizeInBits <= 32 THEN
						Emit(InstructionSet.Ucvtf64From32(destination, source))
					ELSE Emit(InstructionSet.Ucvtf64From64(destination, source))
					END
				END;
				RETURN
			ELSIF instruction.op2.type.form = IntermediateCode.Float THEN
				destination := DestinationRegister(instruction.op1, instruction.textPosition);
				source := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
				IF instruction.op1.type.sizeInBits <= 32 THEN
					IF instruction.op2.type.sizeInBits = 32 THEN
						Emit(InstructionSet.Fcvtms32From32(destination, source))
					ELSE Emit(InstructionSet.Fcvtms32From64(destination, source))
					END
				ELSIF instruction.op2.type.sizeInBits = 32 THEN
					Emit(InstructionSet.Fcvtms64From32(destination, source))
				ELSE Emit(InstructionSet.Fcvtms64From64(destination, source))
				END;
				(* A W-register conversion clears the upper half of X. Integer
				   comparisons use X registers, so restore the declared sign. *)
				NormalizeInteger(destination, instruction.op1.type);
				RETURN
			END;
			destination := DestinationRegister(instruction.op1, instruction.textPosition);
			source := OperandRegister(instruction.op2, destination, instruction.textPosition);
			IF source # destination THEN Emit(InstructionSet.MovRegister64(destination, source)) END;
			sourceBits := instruction.op2.type.sizeInBits;
			destinationBits := instruction.op1.type.sizeInBits;
			IF (destinationBits = 64) & (sourceBits < 64) THEN
				IF instruction.op2.type.form = IntermediateCode.SignedInteger THEN
					Emit(InstructionSet.SignExtend64(destination, destination, sourceBits))
				ELSIF sourceBits = 32 THEN
					Emit(InstructionSet.ZeroExtend32To64(destination, destination))
				END
			ELSIF destinationBits < 64 THEN
				IF instruction.op1.type.form = IntermediateCode.SignedInteger THEN
					Emit(InstructionSet.SignExtend64(destination, destination, destinationBits))
				ELSIF destinationBits = 32 THEN
					Emit(InstructionSet.ZeroExtend32To64(destination, destination))
				END
			END;
			NormalizeInteger(destination, instruction.op1.type)
		END EmitConversion;

		PROCEDURE EmitUnary(CONST instruction: IntermediateCode.Instruction);
		VAR destination, source: SIGNED32;
		BEGIN
			IF instruction.op1.type.form = IntermediateCode.Float THEN
				destination := DestinationFloatRegister(instruction.op1, instruction.textPosition);
				source := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
				IF instruction.op1.type.sizeInBits = 32 THEN
					IF instruction.opcode = IntermediateCode.neg THEN
						Emit(InstructionSet.Fneg32(destination, source))
					ELSE Emit(InstructionSet.Fabs32(destination, source))
					END
				ELSE
					IF instruction.opcode = IntermediateCode.neg THEN
						Emit(InstructionSet.Fneg64(destination, source))
					ELSE Emit(InstructionSet.Fabs64(destination, source))
					END
				END;
				RETURN
			END;
			destination := DestinationRegister(instruction.op1, instruction.textPosition);
			IF instruction.op2.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(InstructionSet.X16, instruction.op2.intValue);
				source := InstructionSet.X16
			ELSE
				source := OperandRegister(instruction.op2, InstructionSet.X16, instruction.textPosition)
			END;
			IF instruction.opcode = IntermediateCode.neg THEN
				Emit(InstructionSet.Neg64(destination, source))
			ELSIF instruction.opcode = IntermediateCode.abs THEN
				Emit(InstructionSet.Neg64(InstructionSet.X17, source));
				Emit(InstructionSet.CmpImmediate64(source, 0));
				Emit(InstructionSet.Csel64(destination, InstructionSet.X17, source, InstructionSet.LT))
			ELSIF instruction.opcode = IntermediateCode.not THEN
				IF instruction.op1.type.sizeInBits <= 32 THEN
					Emit(InstructionSet.Mvn32(destination, source))
				ELSE Emit(InstructionSet.Mvn64(destination, source))
				END
			ELSE Error(instruction.textPosition, "unary instruction not supported by AArch64 lowering")
			END;
			NormalizeInteger(destination, instruction.op1.type)
		END EmitUnary;

		PROCEDURE EmitLogical(CONST instruction: IntermediateCode.Instruction);
		VAR destination, left, right, bits: SIGNED32; mask: SIGNED64;
		BEGIN
			IF (instruction.opcode = IntermediateCode.and) &
				(instruction.op1.mode = IntermediateCode.ModeRegister) &
				(instruction.op1.register = IntermediateCode.SP)
			THEN RETURN
			END;
			destination := DestinationRegister(instruction.op1, instruction.textPosition);
			IF instruction.op2.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(InstructionSet.X16, instruction.op2.intValue); left := InstructionSet.X16
			ELSE left := OperandRegister(instruction.op2, InstructionSet.X16, instruction.textPosition)
			END;
			bits := instruction.op1.type.sizeInBits;
			IF instruction.opcode IN {IntermediateCode.shr, IntermediateCode.shl,
				IntermediateCode.rol, IntermediateCode.ror}
			THEN
				IF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X17, instruction.op3.intValue);
					right := InstructionSet.X17
				ELSE
					right := OperandRegister(instruction.op3, InstructionSet.X17,
						instruction.textPosition)
				END;
				IF instruction.opcode IN {IntermediateCode.rol, IntermediateCode.ror} THEN
					(* Preserve both sources even when the destination aliases one.
					   Rotations wrap at the declared width, including 8/16 bits. *)
					Emit(InstructionSet.MovRegister64(InstructionSet.X16, left));
					Emit(InstructionSet.MovRegister64(InstructionSet.X17, right));
					IF instruction.opcode = IntermediateCode.rol THEN
						Emit(InstructionSet.SubRegister64(InstructionSet.X17, InstructionSet.ZR, InstructionSet.X17))
					END;
					IF bits = 64 THEN
						Emit(InstructionSet.Rorv64(destination, InstructionSet.X16, InstructionSet.X17))
					ELSIF bits = 32 THEN
						Emit(InstructionSet.Rorv32(destination, InstructionSet.X16, InstructionSet.X17))
					ELSE
						mask := ASH(SIGNED64(1), bits) - 1;
						EmitConstant(InstructionSet.X12, mask);
						Emit(InstructionSet.AndRegister64(InstructionSet.X16, InstructionSet.X16, InstructionSet.X12));
						EmitConstant(InstructionSet.X12, bits - 1);
						Emit(InstructionSet.AndRegister64(InstructionSet.X17, InstructionSet.X17, InstructionSet.X12));
						EmitConstant(InstructionSet.X12, bits);
						Emit(InstructionSet.SubRegister64(InstructionSet.X12, InstructionSet.X12, InstructionSet.X17));
						Emit(InstructionSet.Lsrv32(InstructionSet.X11, InstructionSet.X16, InstructionSet.X17));
						Emit(InstructionSet.Lslv32(destination, InstructionSet.X16, InstructionSet.X12));
						Emit(InstructionSet.OrrRegister32(destination, destination, InstructionSet.X11))
					END
				ELSIF (instruction.opcode = IntermediateCode.shr) &
					(instruction.op1.type.form = IntermediateCode.SignedInteger) THEN
					Emit(InstructionSet.Asrv64(destination, left, right))
				ELSIF bits <= 32 THEN
					IF instruction.opcode = IntermediateCode.shl THEN
						Emit(InstructionSet.Lslv32(destination, left, right))
					ELSE Emit(InstructionSet.Lsrv32(destination, left, right))
					END
				ELSIF instruction.opcode = IntermediateCode.shl THEN
					Emit(InstructionSet.Lslv64(destination, left, right))
				ELSE Emit(InstructionSet.Lsrv64(destination, left, right))
				END
			ELSIF instruction.opcode = IntermediateCode.and THEN
				IF (instruction.op3.mode = IntermediateCode.ModeImmediate) &
					(instruction.op3.intValue = 1)
				THEN Emit(InstructionSet.AndLowBit64(destination, left))
				ELSIF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X17, instruction.op3.intValue);
					IF bits <= 32 THEN Emit(InstructionSet.AndRegister32(destination, left, InstructionSet.X17))
					ELSE Emit(InstructionSet.AndRegister64(destination, left, InstructionSet.X17))
					END
				ELSE
					right := OperandRegister(instruction.op3, InstructionSet.X17, instruction.textPosition);
					IF bits <= 32 THEN Emit(InstructionSet.AndRegister32(destination, left, right))
					ELSE Emit(InstructionSet.AndRegister64(destination, left, right))
					END
				END
			ELSIF instruction.opcode IN {IntermediateCode.or, IntermediateCode.xor} THEN
				IF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X17, instruction.op3.intValue); right := InstructionSet.X17
				ELSE right := OperandRegister(instruction.op3, InstructionSet.X17, instruction.textPosition)
				END;
				IF bits <= 32 THEN
					IF instruction.opcode = IntermediateCode.or THEN
						Emit(InstructionSet.OrrRegister32(destination, left, right))
					ELSE Emit(InstructionSet.EorRegister32(destination, left, right))
					END
				ELSIF instruction.opcode = IntermediateCode.or THEN
					Emit(InstructionSet.OrrRegister64(destination, left, right))
				ELSE Emit(InstructionSet.EorRegister64(destination, left, right))
				END
			ELSE Error(instruction.textPosition, "logical instruction not supported by AArch64 lowering")
			END;
			NormalizeInteger(destination, instruction.op1.type)
		END EmitLogical;

		PROCEDURE EmitCopy(CONST instruction: IntermediateCode.Instruction);
		VAR source, destination, length: SIGNED32;
		BEGIN
			(* COPY operands are pointer values, including pointers held in memory.
			   Keep private counters: the byte loop must not change virtual registers. *)
			destination := 12; source := 13; length := InstructionSet.X15;
			LoadIntegerOperand(instruction.op1, destination, instruction.textPosition);
			LoadIntegerOperand(instruction.op2, source, instruction.textPosition);
			LoadIntegerOperand(instruction.op3, length, instruction.textPosition);
			Emit(InstructionSet.Cbz64(length, 28));
			Emit(InstructionSet.LdrUnsigned8(InstructionSet.X14, source, 0));
			Emit(InstructionSet.StrUnsigned8(InstructionSet.X14, destination, 0));
			Emit(InstructionSet.AddImmediate64(source, source, 1, FALSE));
			Emit(InstructionSet.AddImmediate64(destination, destination, 1, FALSE));
			Emit(InstructionSet.SubsImmediate64(length, length, 1, FALSE));
			Emit(InstructionSet.BCond(-20, InstructionSet.NE))
		END EmitCopy;

		PROCEDURE EmitCas(CONST instruction: IntermediateCode.Instruction);
		VAR address, source, bits: SIGNED32;
		BEGIN
			IF instruction.op1.symbol.name # "" THEN
				EmitAddress(InstructionSet.X16, instruction.op1);
				address := InstructionSet.X16
			ELSE
				address := OperandRegister(instruction.op1, InstructionSet.X16,
					instruction.textPosition)
			END;
			IF instruction.op2.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(InstructionSet.X0, instruction.op2.intValue)
			ELSE
				source := OperandRegister(instruction.op2, InstructionSet.X0,
					instruction.textPosition);
				IF source # InstructionSet.X0 THEN
					Emit(InstructionSet.MovRegister64(InstructionSet.X0, source))
				END
			END;
			IF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(InstructionSet.X17, instruction.op3.intValue)
			ELSE
				source := OperandRegister(instruction.op3, InstructionSet.X17,
					instruction.textPosition);
				IF source # InstructionSet.X17 THEN
					Emit(InstructionSet.MovRegister64(InstructionSet.X17, source))
				END
			END;
			bits := instruction.op2.type.sizeInBits;
			IF bits = 8 THEN
				Emit(InstructionSet.Casal8(InstructionSet.X0, InstructionSet.X17, address))
			ELSIF bits = 32 THEN
				Emit(InstructionSet.Casal32(InstructionSet.X0, InstructionSet.X17, address))
			ELSIF bits = 64 THEN
				Emit(InstructionSet.Casal64(InstructionSet.X0, InstructionSet.X17, address))
			ELSE
				Error(instruction.textPosition, "compare-and-swap width is not supported")
			END
		END EmitCas;

		PROCEDURE LoadIntegerOperand(CONST operand: IntermediateCode.Operand; destination: SIGNED32;
			position: Basic.Position);
		VAR source: SIGNED32;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeImmediate) & (operand.symbol.name # "") THEN
				EmitAddress(destination, operand)
			ELSIF operand.mode = IntermediateCode.ModeImmediate THEN
				EmitConstant(destination, operand.intValue)
			ELSE
				source := OperandRegister(operand, destination, position);
				IF source # destination THEN
					AdjustAddress(destination, source, 0)
				END
			END
		END LoadIntegerOperand;

		PROCEDURE EmitMulDivMod(CONST instruction: IntermediateCode.Instruction);
		VAR signed: BOOLEAN; destination, left, right: SIGNED32;
		BEGIN
			IF instruction.op1.type.form = IntermediateCode.Float THEN
				destination := DestinationFloatRegister(instruction.op1, instruction.textPosition);
				left := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
				right := FloatOperandRegister(instruction.op3, 17, instruction.textPosition);
				IF instruction.op1.type.sizeInBits = 32 THEN
					IF instruction.opcode = IntermediateCode.mul THEN
						Emit(InstructionSet.Fmul32(destination, left, right))
					ELSIF instruction.opcode = IntermediateCode.div THEN
						Emit(InstructionSet.Fdiv32(destination, left, right))
					ELSE Error(instruction.textPosition, "floating remainder is unsupported")
					END
				ELSE
					IF instruction.opcode = IntermediateCode.mul THEN
						Emit(InstructionSet.Fmul64(destination, left, right))
					ELSIF instruction.opcode = IntermediateCode.div THEN
						Emit(InstructionSet.Fdiv64(destination, left, right))
					ELSE Error(instruction.textPosition, "floating remainder is unsupported")
					END
				END;
				RETURN
			END;
			IF (instruction.op1.mode # IntermediateCode.ModeRegister) OR
				(instruction.op1.register < 0) OR
				(instruction.op1.register >= LEN(virtualRegisters))
			THEN
				Error(instruction.textPosition, "integer destination not supported by initial AArch64 backend");
				RETURN
			END;
			destination := DestinationRegister(instruction.op1, instruction.textPosition);
			LoadIntegerOperand(instruction.op2, InstructionSet.X9, instruction.textPosition);
			LoadIntegerOperand(instruction.op3, InstructionSet.X10, instruction.textPosition);
			signed := instruction.op1.type.form = IntermediateCode.SignedInteger;
			CASE instruction.opcode OF
				IntermediateCode.mul:
					Emit(InstructionSet.Mul64(InstructionSet.X8, InstructionSet.X9, InstructionSet.X10))
			|IntermediateCode.div:
				IF signed THEN
					(* AArch64 SDIV truncates toward zero. Oberon DIV rounds down for its
					   defined case of a positive divisor, so correct a negative remainder. *)
					Emit(InstructionSet.SDiv64(InstructionSet.X8, InstructionSet.X9, InstructionSet.X10));
					Emit(InstructionSet.MSub64(InstructionSet.X11, InstructionSet.X8,
						InstructionSet.X10, InstructionSet.X9));
					Emit(InstructionSet.SubImmediate64(InstructionSet.X12, InstructionSet.X8, 1, FALSE));
					Emit(InstructionSet.CmpImmediate64(InstructionSet.X11, 0));
					Emit(InstructionSet.Csel64(InstructionSet.X8, InstructionSet.X12,
						InstructionSet.X8, InstructionSet.LT))
				ELSE
					Emit(InstructionSet.UDiv64(InstructionSet.X8, InstructionSet.X9, InstructionSet.X10))
				END
			|IntermediateCode.mod:
				IF signed THEN
					Emit(InstructionSet.SDiv64(InstructionSet.X8, InstructionSet.X9, InstructionSet.X10));
					Emit(InstructionSet.MSub64(InstructionSet.X11, InstructionSet.X8,
						InstructionSet.X10, InstructionSet.X9));
					Emit(InstructionSet.AddRegister64(InstructionSet.X12, InstructionSet.X11,
						InstructionSet.X10));
					Emit(InstructionSet.CmpImmediate64(InstructionSet.X11, 0));
					Emit(InstructionSet.Csel64(InstructionSet.X8, InstructionSet.X12,
						InstructionSet.X11, InstructionSet.LT))
				ELSE
					Emit(InstructionSet.UDiv64(InstructionSet.X8, InstructionSet.X9, InstructionSet.X10));
					Emit(InstructionSet.MSub64(InstructionSet.X8, InstructionSet.X8,
						InstructionSet.X10, InstructionSet.X9))
				END
			END;
			IF destination # InstructionSet.X8 THEN
				Emit(InstructionSet.MovRegister64(destination, InstructionSet.X8))
			END;
			NormalizeInteger(destination, instruction.op1.type)
		END EmitMulDivMod;

		PROCEDURE EmitBranch(CONST instruction: IntermediateCode.Instruction);
		VAR left, right, condition: SIGNED32; pattern: BinaryCode.FixupPatterns;
			fixup: BinaryCode.Fixup; signed: BOOLEAN; targetRegister: SIGNED32;
		BEGIN
			IF (instruction.opcode = IntermediateCode.br) &
				((instruction.op1.mode # IntermediateCode.ModeImmediate) OR
				 (instruction.op1.symbol.name = ""))
			THEN
				targetRegister := OperandRegister(instruction.op1, InstructionSet.X16,
					instruction.textPosition);
				Emit(InstructionSet.Br(targetRegister));
				RETURN
			END;
			IF (instruction.op1.mode # IntermediateCode.ModeImmediate) OR
				(instruction.op1.symbol.name = "")
			THEN
				Error(instruction.textPosition, "initial AArch64 backend only supports symbolic branch targets");
				RETURN
			END;
			IF instruction.opcode = IntermediateCode.br THEN
				NEW(pattern, 1); pattern[0].offset := 0; pattern[0].bits := 26;
				fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, instruction.op1.symbol,
					instruction.op1.symbolOffset, instruction.op1.offset, -2, pattern);
				out.fixupList.AddFixup(fixup);
				Emit(InstructionSet.B(0));
				RETURN
			END;

			IF instruction.op2.type.form = IntermediateCode.Float THEN
				left := FloatOperandRegister(instruction.op2, 16, instruction.textPosition);
				right := FloatOperandRegister(instruction.op3, 17, instruction.textPosition);
				IF instruction.op2.type.sizeInBits = 32 THEN
					Emit(InstructionSet.Fcmp32(left, right))
				ELSE Emit(InstructionSet.Fcmp64(left, right))
				END;
				CASE instruction.opcode OF
					IntermediateCode.breq: condition := InstructionSet.EQ
				|IntermediateCode.brne: condition := InstructionSet.NE
				|IntermediateCode.brge: condition := InstructionSet.GE
				|IntermediateCode.brlt: condition := InstructionSet.MI
				ELSE condition := InstructionSet.EQ
				END;
				NEW(pattern, 1); pattern[0].offset := 5; pattern[0].bits := 19;
				fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, instruction.op1.symbol,
					instruction.op1.symbolOffset, instruction.op1.offset, -2, pattern);
				out.fixupList.AddFixup(fixup);
				Emit(InstructionSet.BCond(0, condition));
				RETURN
			END;

			IF instruction.op2.mode = IntermediateCode.ModeImmediate THEN
				IF instruction.op2.symbol.name # "" THEN
					EmitAddress(InstructionSet.X9, instruction.op2)
				ELSE EmitConstant(InstructionSet.X9, instruction.op2.intValue)
				END;
				left := InstructionSet.X9
			ELSE
				left := OperandRegister(instruction.op2, InstructionSet.X9, instruction.textPosition)
			END;
			IF (instruction.op3.mode = IntermediateCode.ModeImmediate) &
				(instruction.op3.symbol.name = "") & (instruction.op3.intValue >= 0) &
				(instruction.op3.intValue < 4096)
			THEN
				Emit(InstructionSet.CmpImmediate64(left, SHORT(instruction.op3.intValue)))
			ELSE
				IF instruction.op3.mode = IntermediateCode.ModeImmediate THEN
					IF instruction.op3.symbol.name # "" THEN
						EmitAddress(InstructionSet.X10, instruction.op3)
					ELSE EmitConstant(InstructionSet.X10, instruction.op3.intValue)
					END;
					right := InstructionSet.X10
				ELSE
					right := OperandRegister(instruction.op3, InstructionSet.X10, instruction.textPosition)
				END;
				Emit(InstructionSet.CmpRegister64(left, right))
			END;

			signed := instruction.op2.type.form = IntermediateCode.SignedInteger;
			CASE instruction.opcode OF
				IntermediateCode.breq: condition := InstructionSet.EQ
			|IntermediateCode.brne: condition := InstructionSet.NE
			|IntermediateCode.brge:
				IF signed THEN condition := InstructionSet.GE ELSE condition := InstructionSet.CS END
			|IntermediateCode.brlt:
				IF signed THEN condition := InstructionSet.LT ELSE condition := InstructionSet.CC END
			ELSE
				condition := InstructionSet.EQ
			END;
			NEW(pattern, 1); pattern[0].offset := 5; pattern[0].bits := 19;
			fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, instruction.op1.symbol,
				instruction.op1.symbolOffset, instruction.op1.offset, -2, pattern);
			out.fixupList.AddFixup(fixup);
			Emit(InstructionSet.BCond(0, condition))
		END EmitBranch;

		PROCEDURE QueueArgument(CONST operand: IntermediateCode.Operand; position: Basic.Position);
		VAR stored: IntermediateCode.Operand; source, offset: SIGNED32;
			addressType: IntermediateCode.Type;
		BEGIN
			IF pendingArgumentCount >= LEN(pendingArguments) THEN
				Error(position, "too many stack arguments for initial AArch64 backend");
				RETURN
			END;
			IF operand.mode = IntermediateCode.ModeMemory THEN
				offset := QueuedArgumentOffset(pendingArgumentCount);
				IF operand.type.form = IntermediateCode.Float THEN
					source := FloatOperandRegister(operand, 16, position);
					StoreFloatMemory(source, InstructionSet.FP, offset, operand.type)
				ELSE
					source := OperandRegister(operand, InstructionSet.X16, position);
					StoreMemory(source, InstructionSet.FP, offset, operand.type)
				END;
				addressType := IntermediateCode.GetType(module.system, module.system.addressType);
				IntermediateCode.InitRegister(stored, addressType,
					IntermediateCode.GeneralPurposeRegister, IntermediateCode.FP);
				IntermediateCode.InitMemory(stored, operand.type, stored, offset);
				pendingArguments[pendingArgumentCount] := stored
			ELSE
				pendingArguments[pendingArgumentCount] := operand
			END;
			INC(pendingArgumentCount)
		END QueueArgument;

		PROCEDURE EmitStackSubtract(amount: SIGNED32);
		VAR pages: SIGNED32;
		BEGIN
			WHILE amount >= 4096 DO
				pages := amount DIV 4096;
				IF pages > 4095 THEN pages := 4095 END;
				Emit(InstructionSet.SubImmediate64(InstructionSet.SP, InstructionSet.SP,
					pages, TRUE));
				DEC(amount, pages * 4096)
			END;
			IF amount > 0 THEN
				Emit(InstructionSet.SubImmediate64(InstructionSet.SP, InstructionSet.SP,
					amount, FALSE))
			END
		END EmitStackSubtract;

		PROCEDURE EmitQueuedArguments(position: Basic.Position;
			argumentBytes: SIGNED32): SIGNED32;
		VAR i, offset, allocation, source, argumentCount, saveCount,
			consumedSaved, currentFootprint, cleanup, argumentAllocation,
			savedAllocation: SIGNED32;
			operand: IntermediateCode.Operand;
		BEGIN
			argumentCount := argumentBytes DIV 8;
			IF (pendingArgumentCount = 0) & (argumentCount = 0) THEN RETURN 0 END;
			IF argumentCount > pendingArgumentCount THEN
				consumedSaved := argumentCount - pendingArgumentCount;
				IF consumedSaved > savedPopCount THEN
					Error(position, "call argument stack is incomplete");
					consumedSaved := savedPopCount;
					argumentCount := pendingArgumentCount + consumedSaved
				END;
				currentFootprint := savedStackBytes;
				allocation := argumentCount * 8;
				WHILE (currentFootprint + allocation) MOD 16 # 0 DO INC(allocation, 8) END;
				EmitStackSubtract(allocation);
				FOR i := 0 TO pendingArgumentCount - 1 DO
					operand := pendingArguments[i];
					offset := (pendingArgumentCount - i - 1) * 8;
					IF operand.type.form = IntermediateCode.Float THEN
						source := FloatOperandRegister(operand, 16, position);
						IF operand.type.sizeInBits = 32 THEN
							Emit(InstructionSet.StrFloat32(source, InstructionSet.SP, offset))
						ELSE Emit(InstructionSet.StrFloat64(source, InstructionSet.SP, offset))
						END
					ELSIF (operand.mode = IntermediateCode.ModeImmediate) & (operand.symbol.name # "") THEN
						EmitAddress(InstructionSet.X9, operand); source := InstructionSet.X9
					ELSIF operand.mode = IntermediateCode.ModeImmediate THEN
						EmitConstant(InstructionSet.X9, operand.intValue); source := InstructionSet.X9
					ELSE source := OperandRegister(operand, InstructionSet.X9, position)
					END;
					IF operand.type.form # IntermediateCode.Float THEN
						Emit(InstructionSet.StrUnsigned64(source, InstructionSet.SP, offset))
					END
				END;
				FOR i := 0 TO consumedSaved - 1 DO
					Emit(InstructionSet.LdrUnsigned64(InstructionSet.X9, InstructionSet.SP,
						allocation + SavedValueOffset(i)));
					Emit(InstructionSet.StrUnsigned64(InstructionSet.X9, InstructionSet.SP,
						pendingArgumentCount * 8 + i * 8))
				END;
				cleanup := allocation + ConsumeSavedValues(consumedSaved);
				pendingArgumentCount := 0;
				RETURN cleanup
			END;
			saveCount := pendingArgumentCount - argumentCount;
			argumentAllocation := ((argumentCount * 8 + 15) DIV 16) * 16;
			savedAllocation := ((saveCount * 8 + 15) DIV 16) * 16;
			allocation := argumentAllocation + savedAllocation;
			EmitStackSubtract(allocation);
			FOR i := 0 TO pendingArgumentCount - 1 DO
				operand := pendingArguments[i];
				IF i < saveCount THEN
					offset := argumentAllocation + (saveCount - i - 1) * 8
				ELSE
					offset := (pendingArgumentCount - i - 1) * 8
				END;
				IF operand.type.form = IntermediateCode.Float THEN
					source := FloatOperandRegister(operand, 16, position);
					IF operand.type.sizeInBits = 32 THEN
						Emit(InstructionSet.StrFloat32(source, InstructionSet.SP, offset))
					ELSE Emit(InstructionSet.StrFloat64(source, InstructionSet.SP, offset))
					END
				ELSIF (operand.mode = IntermediateCode.ModeImmediate) & (operand.symbol.name # "") THEN
					EmitAddress(InstructionSet.X9, operand);
					source := InstructionSet.X9
				ELSIF operand.mode = IntermediateCode.ModeImmediate THEN
					EmitConstant(InstructionSet.X9, operand.intValue);
					source := InstructionSet.X9
				ELSE
					source := OperandRegister(operand, InstructionSet.X9, position)
				END;
				IF operand.type.form # IntermediateCode.Float THEN
					Emit(InstructionSet.StrUnsigned64(source, InstructionSet.SP, offset))
				END
			END;
			RecordSavedGroup(saveCount, savedAllocation - saveCount * 8, position);
			pendingArgumentCount := 0;
			RETURN argumentAllocation
		END EmitQueuedArguments;

		PROCEDURE EmitPop(CONST operand: IntermediateCode.Operand;
			position: Basic.Position);
		VAR destination, amount, offset: SIGNED32; source: IntermediateCode.Operand;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeRegister) &
				((operand.register = IntermediateCode.FP) OR
				 (operand.register = IntermediateCode.SP) OR
				 (operand.register = IntermediateCode.LR))
			THEN RETURN
			END;
			IF pendingArgumentCount > 0 THEN
				DEC(pendingArgumentCount);
				source := pendingArguments[pendingArgumentCount];
				RememberParameter(operand, source, position);
				RETURN
			END;
			IF savedPopCount <= 0 THEN
				Error(position, "pop without a saved AArch64 call value");
				RETURN
			END;
			offset := SavedValueOffset(0);
			IF operand.type.form = IntermediateCode.Float THEN
				IF (operand.mode = IntermediateCode.ModeRegister) &
					(operand.registerClass.class = IntermediateCode.Parameter)
				THEN destination := operand.registerClass.number
				ELSE destination := DestinationFloatRegister(operand, position)
				END;
				LoadFloatMemory(destination, InstructionSet.SP, offset, operand.type)
			ELSIF (operand.mode = IntermediateCode.ModeRegister) &
				(operand.registerClass.class = IntermediateCode.Parameter)
			THEN
				destination := operand.registerClass.number
			ELSE
				destination := DestinationRegister(operand, position)
			END;
			IF operand.type.form # IntermediateCode.Float THEN
				LoadMemory(destination, InstructionSet.SP, offset, operand.type)
			END;
			amount := ConsumeSavedValues(1);
			IF amount > 0 THEN AdjustAddress(InstructionSet.SP, InstructionSet.SP, amount) END
		END EmitPop;

		PROCEDURE EmitEnter(CONST instruction: IntermediateCode.Instruction);
		VAR frameSize, i, offset: SIGNED32;
		BEGIN
			(* Pushes before enter describe the generic frame. The AArch64 prologue
			   below reserves that storage directly; none are call arguments. *)
			pendingArgumentCount := 0;
			localFrameSize := SHORT(instruction.op2.intValue);
			localFrameSize := ((localFrameSize + 15) DIV 16) * 16;
			frameSize := localFrameSize + (integerSpillCount + floatSpillCount +
				10 + LEN(pendingArguments)) * 8;
			frameSize := ((frameSize + 15) DIV 16) * 16;
			Emit(InstructionSet.StpPre64(InstructionSet.FP, InstructionSet.LR,
				InstructionSet.SP, -16));
			Emit(InstructionSet.AddImmediate64(InstructionSet.FP, InstructionSet.SP, 0, FALSE));
			IF frameSize > 0 THEN
				EmitStackSubtract(frameSize)
			END;
			(* Structured locals contain traced pointers and are expected to start
			   cleared. Zero the source-language local area before its first use. *)
			IF localFrameSize > 0 THEN
				AdjustAddress(InstructionSet.X16, InstructionSet.FP, -localFrameSize);
				EmitConstant(InstructionSet.X17, localFrameSize DIV 8);
				Emit(InstructionSet.StrUnsigned64(InstructionSet.ZR, InstructionSet.X16, 0));
				Emit(InstructionSet.AddImmediate64(InstructionSet.X16, InstructionSet.X16, 8, FALSE));
				Emit(InstructionSet.SubsImmediate64(InstructionSet.X17, InstructionSet.X17, 1, FALSE));
				Emit(InstructionSet.BCond(-12, InstructionSet.NE))
			END;
			FOR i := 0 TO 9 DO
				offset := -(localFrameSize + (integerSpillCount + floatSpillCount) * 8 + (i + 1) * 8);
				AdjustAddress(InstructionSet.X17, InstructionSet.FP, offset);
				Emit(InstructionSet.StrUnsigned64(InstructionSet.X19 + i, InstructionSet.X17, 0))
			END
		END EmitEnter;

		PROCEDURE EmitExit;
		VAR i, offset: SIGNED32;
		BEGIN
			FOR i := 0 TO 9 DO
				offset := -(localFrameSize + (integerSpillCount + floatSpillCount) * 8 + (i + 1) * 8);
				AdjustAddress(InstructionSet.X17, InstructionSet.FP, offset);
				Emit(InstructionSet.LdrUnsigned64(InstructionSet.X19 + i, InstructionSet.X17, 0))
			END;
			Emit(InstructionSet.AddImmediate64(InstructionSet.SP, InstructionSet.FP, 0, FALSE));
			Emit(InstructionSet.LdpPost64(InstructionSet.FP, InstructionSet.LR,
				InstructionSet.SP, 16));
			Emit(InstructionSet.Ret(InstructionSet.LR))
		END EmitExit;

		PROCEDURE EmitCall(CONST instruction: IntermediateCode.Instruction);
		VAR fixup, inlineFixup: BinaryCode.Fixup; pattern: BinaryCode.FixupPatterns;
			allocation, targetRegister: SIGNED32; target: Sections.Section;
			inlineCode: BinaryCode.Section; inlinePC: SIZE;
		BEGIN
			allocation := EmitQueuedArguments(instruction.textPosition,
				SHORT(instruction.op2.intValue));
			IF instruction.op1.mode = IntermediateCode.ModeImmediate THEN
				target := module.allSections.FindByName(instruction.op1.symbol.name);
				IF (target # NIL) & (target.type = Sections.InlineCodeSection) THEN
					inlineCode := target(IntermediateCode.Section).resolved;
					IF inlineCode = NIL THEN
						Error(instruction.textPosition, "inline code section was not generated"); RETURN
					END;
					inlinePC := out.pc;
					out.CopyBits(inlineCode.os.bits, 0, inlineCode.os.bits.GetSize());
					inlineFixup := inlineCode.fixupList.firstFixup;
					WHILE inlineFixup # NIL DO
						fixup := BinaryCode.NewFixup(inlineFixup.mode,
							inlineFixup.offset + inlinePC, inlineFixup.symbol,
							inlineFixup.symbolOffset, inlineFixup.displacement,
							inlineFixup.scale, inlineFixup.pattern);
						out.fixupList.AddFixup(fixup);
						inlineFixup := inlineFixup.nextFixup
					END;
					IF allocation > 0 THEN
						AdjustAddress(InstructionSet.SP, InstructionSet.SP, allocation)
					END;
					RETURN
				END
			END;
			IF instruction.op1.mode # IntermediateCode.ModeImmediate THEN
				targetRegister := OperandRegister(instruction.op1, InstructionSet.X16, instruction.textPosition);
				Emit(InstructionSet.Blr(targetRegister));
				IF allocation > 0 THEN
					AdjustAddress(InstructionSet.SP, InstructionSet.SP, allocation)
				END;
				RETURN
			ELSIF instruction.op1.symbol.name = "" THEN
				Error(instruction.textPosition, "call target not supported by AArch64 lowering"); RETURN
			END;
			target := module.allSections.FindByName(instruction.op1.symbol.name);
			IF target = NIL THEN
				EmitAddress(InstructionSet.X16, instruction.op1);
				Emit(InstructionSet.Blr(InstructionSet.X16))
			ELSE
				NEW(pattern, 1);
				pattern[0].offset := 0;
				pattern[0].bits := 26;
				fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, instruction.op1.symbol,
					instruction.op1.symbolOffset, instruction.op1.offset, -2, pattern);
				out.fixupList.AddFixup(fixup);
				Emit(InstructionSet.Bl(0))
			END;
			IF allocation > 0 THEN
				AdjustAddress(InstructionSet.SP, InstructionSet.SP, allocation)
			END
		END EmitCall;

		PROCEDURE EmitResult(CONST instruction: IntermediateCode.Instruction);
		VAR destination: SIGNED32;
		BEGIN
			IF (instruction.op1.type.form = IntermediateCode.Float) &
				(instruction.op1.mode = IntermediateCode.ModeRegister) &
				(instruction.op1.register >= 0) &
				(instruction.op1.register < LEN(floatVirtualRegisters))
			THEN
				destination := DestinationFloatRegister(instruction.op1,
					instruction.textPosition);
				IF instruction.op1.type.sizeInBits = 32 THEN
					Emit(InstructionSet.FmovFloat32(destination, 0))
				ELSE Emit(InstructionSet.FmovFloat64(destination, 0))
				END
			ELSIF (instruction.op1.mode = IntermediateCode.ModeRegister) &
				(instruction.op1.register >= 0) &
				(instruction.op1.register < LEN(virtualRegisters))
			THEN
				destination := DestinationRegister(instruction.op1,
					instruction.textPosition);
				IF destination # InstructionSet.X0 THEN
					Emit(InstructionSet.MovRegister64(destination, InstructionSet.X0))
				END;
				NormalizeInteger(destination, instruction.op1.type)
			ELSE
				Error(instruction.textPosition, "result destination not supported by initial AArch64 backend")
			END
		END EmitResult;

		PROCEDURE EmitReturnConstant(CONST operand: IntermediateCode.Operand; position: Basic.Position);
		VAR source: SIGNED32;
		BEGIN
			IF (operand.mode = IntermediateCode.ModeImmediate) &
				(operand.type.form = IntermediateCode.Float)
			THEN
				source := FloatOperandRegister(operand, 0, position);
				IF source # 0 THEN
					IF operand.type.sizeInBits = 32 THEN Emit(InstructionSet.FmovFloat32(0, source))
					ELSE Emit(InstructionSet.FmovFloat64(0, source))
					END
				END
			ELSIF (operand.mode = IntermediateCode.ModeImmediate) &
				(operand.type.form IN IntermediateCode.Integer) &
				(operand.symbol.name = "")
			THEN
				EmitConstant(InstructionSet.X0, operand.intValue)
			ELSE
				Error(position, "initial AArch64 backend only supports integer return constants")
			END
		END EmitReturnConstant;

		PROCEDURE EmitReturn(CONST operand: IntermediateCode.Operand; position: Basic.Position);
		VAR source: SIGNED32;
		BEGIN
			IF operand.mode = IntermediateCode.ModeImmediate THEN
				EmitReturnConstant(operand, position)
			ELSIF operand.type.form = IntermediateCode.Float THEN
				source := FloatOperandRegister(operand, 0, position);
				IF source # 0 THEN
					IF operand.type.sizeInBits = 32 THEN Emit(InstructionSet.FmovFloat32(0, source))
					ELSE Emit(InstructionSet.FmovFloat64(0, source))
					END
				END
			ELSIF operand.mode IN {IntermediateCode.ModeRegister, IntermediateCode.ModeMemory} THEN
				source := OperandRegister(operand, InstructionSet.X0, position);
				IF source # InstructionSet.X0 THEN
					Emit(InstructionSet.MovRegister64(InstructionSet.X0, source))
				END
			ELSE
				Error(position, "return operand not supported by initial AArch64 backend")
			END
		END EmitReturn;

		PROCEDURE EmitHeaderPointer(CONST shortName: ARRAY OF CHAR;
			position: Basic.Position);
		VAR name: ARRAY 256 OF CHAR; segmentedName: ObjectFile.SegmentedName;
			identifier: ObjectFile.Identifier; target: Sections.Section;
			pattern: BinaryCode.FixupPatterns; fixup: BinaryCode.Fixup;
		BEGIN
			Strings.Concat(module.moduleName, ".", name);
			Strings.Append(name, shortName);
			ObjectFile.StringToSegmentedName(name, segmentedName);
			target := module.allSections.FindByName(segmentedName);
			IF target = NIL THEN
				Error(position, "symbol referenced by Glue.Header was not found");
				out.PutQWord(0);
				RETURN
			END;
			identifier.name := segmentedName;
			identifier.fingerprint := target.fingerprint;
			NEW(pattern, 1);
			pattern[0].offset := 0;
			pattern[0].bits := 64;
			fixup := BinaryCode.NewFixup(BinaryCode.Absolute, out.pc, identifier,
				0, 0, 0, pattern);
			out.fixupList.AddFixup(fixup);
			out.PutQWord(0)
		END EmitHeaderPointer;

		PROCEDURE EmitAsm(CONST instruction: IntermediateCode.Instruction);
		CONST signature = "Oberon64G.binary";
		VAR i, start, nameLength, length: SIZE; name: ARRAY 256 OF CHAR;
			symbol: SyntaxTree.Symbol; value: SyntaxTree.Expression;
		BEGIN
			length := Strings.Length(instruction.op1.string^);
			IF (Strings.Pos("{SYSTEM.", instruction.op1.string^) >= 0) &
				(Strings.Pos("{SYSTEM.AArch64}", instruction.op1.string^) < 0)
			THEN
				Error(instruction.textPosition, "inline code targets another architecture");
				RETURN
			END;
			IF Strings.Pos("{SYSTEM.AArch64}", instruction.op1.string^) >= 0 THEN
				i := Strings.Pos("}", instruction.op1.string^) + 1
			ELSE i := 0
			END;
			WHILE (i < length) & (instruction.op1.string[i] <= ' ') DO INC(i) END;
			IF i = length THEN RETURN END;
			IF Strings.Pos("MOV X0,", instruction.op1.string^) = i THEN
				start := i + 7;
				WHILE (start < length) & (instruction.op1.string[start] <= ' ') DO INC(start) END;
				nameLength := 0;
				WHILE (start < length) & (instruction.op1.string[start] > ' ') &
					(nameLength < LEN(name) - 1)
				DO
					name[nameLength] := instruction.op1.string[start];
					INC(nameLength); INC(start)
				END;
				name[nameLength] := 0X;
				WHILE (start < length) & (instruction.op1.string[start] <= ' ') DO INC(start) END;
				IF start < length THEN
					Error(instruction.textPosition, "unsupported instruction after AArch64 inline MOV");
					RETURN
				END;
				symbol := instruction.scope.FindSymbol(Basic.MakeString(name));
				IF (symbol # NIL) & (symbol IS SyntaxTree.Constant) THEN
					value := symbol(SyntaxTree.Constant).value;
					IF value.resolved # NIL THEN value := value.resolved END;
					IF value IS SyntaxTree.IntegerValue THEN
						IF (value(SyntaxTree.IntegerValue).value >= 0) &
							(value(SyntaxTree.IntegerValue).value <= 0FFFFH)
						THEN
							Emit(InstructionSet.MovZ64(InstructionSet.X0,
									SHORT(value(SyntaxTree.IntegerValue).value), 0));
								RETURN
						END
					END
				END;
				Error(instruction.textPosition, "AArch64 inline MOV X0 requires a local 16-bit constant");
				RETURN
			END;
			IF Strings.Pos("NOP", instruction.op1.string^) = i THEN
				start := i + 3;
				WHILE (start < length) & (instruction.op1.string[start] <= ' ') DO INC(start) END;
				IF start < length THEN
					Error(instruction.textPosition, "unsupported instruction after AArch64 NOP");
					RETURN
				END;
				Emit(InstructionSet.Nop()); RETURN
			END;
			IF Strings.Pos("AARCH64_CURRENT_PC", instruction.op1.string^) >= 0 THEN
				Emit(InstructionSet.AdrCurrent(InstructionSet.X0));
				RETURN
			END;
			IF Strings.Pos(signature, instruction.op1.string^) < 0 THEN
				Error(instruction.textPosition,
					"inline assembler is not implemented by the initial AArch64 backend");
				RETURN
			END;
			FOR i := 0 TO Strings.Length(signature) - 1 DO
				out.PutByte(ORD(signature[i]))
			END;
			(* Four zero words complete the 24-byte identifier and reserve the
			   static image size and relocation count fields. *)
			FOR i := 0 TO 3 DO out.PutDWord(0) END;
			EmitHeaderPointer("Init0", instruction.textPosition);
			EmitHeaderPointer("dlopen", instruction.textPosition);
			EmitHeaderPointer("dlclose", instruction.textPosition);
			EmitHeaderPointer("dlsym", instruction.textPosition);
			EmitHeaderPointer("argc", instruction.textPosition);
			EmitHeaderPointer("argv", instruction.textPosition);
			EmitHeaderPointer("environ", instruction.textPosition);
			EmitHeaderPointer("cout", instruction.textPosition)
		END EmitAsm;

		PROCEDURE Generate*(VAR instruction: IntermediateCode.Instruction);
		BEGIN
			protectedRegister1 := instruction.op1.register;
			protectedRegister2 := instruction.op2.register;
			protectedRegister3 := instruction.op3.register;
			ReclaimDeadRegisters;
			CASE instruction.opcode OF
				IntermediateCode.nop, IntermediateCode.leave:
					(* Generic frame scaffolding is handled by enter and exit. *)
			|IntermediateCode.pop:
					EmitPop(instruction.op1, instruction.textPosition)
			|IntermediateCode.push:
					QueueArgument(instruction.op1, instruction.textPosition)
			|IntermediateCode.enter:
					EmitEnter(instruction)
			|IntermediateCode.mov:
					IF (instruction.op2.mode = IntermediateCode.ModeRegister) &
						(instruction.op2.register = IntermediateCode.SP) &
						(instruction.op1.mode = IntermediateCode.ModeRegister) &
						(instruction.op1.register >= 0) &
						(instruction.op1.register < LEN(virtualRegisters)) &
						(pendingArgumentCount > 0)
					THEN FlushPendingValues(instruction.textPosition)
					END;
					RememberParameter(instruction.op1, instruction.op2, instruction.textPosition)
			|IntermediateCode.conv:
					EmitConversion(instruction)
			|IntermediateCode.copy:
					EmitCopy(instruction)
			|IntermediateCode.cas:
					EmitCas(instruction)
			|IntermediateCode.add, IntermediateCode.sub:
					EmitArithmetic(instruction)
			|IntermediateCode.mul, IntermediateCode.div, IntermediateCode.mod:
					EmitMulDivMod(instruction)
			|IntermediateCode.neg, IntermediateCode.abs, IntermediateCode.not:
					EmitUnary(instruction)
			|IntermediateCode.shr, IntermediateCode.shl, IntermediateCode.rol, IntermediateCode.ror,
				IntermediateCode.and, IntermediateCode.or, IntermediateCode.xor:
					EmitLogical(instruction)
			|IntermediateCode.br .. IntermediateCode.brlt:
					EmitBranch(instruction)
			|IntermediateCode.return:
					EmitReturn(instruction.op1, instruction.textPosition)
			|IntermediateCode.result:
					EmitResult(instruction)
			|IntermediateCode.exit:
					EmitExit
			|IntermediateCode.trap:
					Emit(InstructionSet.Brk(SHORT(instruction.op1.intValue)))
			|IntermediateCode.call:
					EmitCall(instruction)
			|IntermediateCode.asm:
					EmitAsm(instruction)
			ELSE
				Error(instruction.textPosition, "instruction not supported by initial AArch64 backend")
			END;
			protectedRegister1 := -1; protectedRegister2 := -1; protectedRegister3 := -1
		END Generate;

	END CodeGenerator;

	BackendAArch64 = OBJECT (IntermediateBackend.IntermediateBackend)
	VAR
		cg: CodeGenerator;
		targetSystem: Global.System;
		integerParameterIndex, floatParameterIndex: SIGNED32;

		PROCEDURE & InitBackendAArch64;
		BEGIN
			InitIntermediateBackend;
			SetSimpleMetaData(TRUE);
			SetHasLinkRegister;
			SetName("AArch64");
			SetCodeUnit(8);
			targetSystem := NIL
		END InitBackendAArch64;

		PROCEDURE Initialize*(diagnostics: Diagnostics.Diagnostics; log: Streams.Writer;
			flags: SET; checker: SemanticChecker.Checker; system: Global.System);
		BEGIN
			Initialize^(diagnostics, log, flags, checker, system);
			NEW(cg, diagnostics, optimize)
		END Initialize;

		PROCEDURE GetSystem*(): Global.System;
		VAR variableOffset: INTEGER;
		BEGIN
			IF targetSystem = NIL THEN
				IF preciseGC THEN variableOffset := -64 ELSE variableOffset := 0 END;
				NEW(targetSystem, 8, 8, 64, 8, 64, 64, 64, 128, variableOffset, cooperative);
				Global.SetDefaultDeclarations(targetSystem, 8);
				Global.SetDefaultOperators(targetSystem)
			END;
			RETURN targetSystem
		END GetSystem;

		PROCEDURE ResetParameterRegisters*;
		BEGIN
			integerParameterIndex := 0; floatParameterIndex := 0
		END ResetParameterRegisters;

		PROCEDURE GetParameterRegister*(callingConvention: SyntaxTree.CallingConvention;
			type: IntermediateCode.Type; VAR register: INTEGER): BOOLEAN;
		BEGIN
			IF ((callingConvention = SyntaxTree.CCallingConvention) OR
				(callingConvention = SyntaxTree.WinAPICallingConvention)) &
				(type.form IN IntermediateCode.Integer) & (integerParameterIndex < 8)
			THEN
				register := integerParameterIndex;
				INC(integerParameterIndex);
				RETURN TRUE
			ELSIF ((callingConvention = SyntaxTree.CCallingConvention) OR
				(callingConvention = SyntaxTree.WinAPICallingConvention)) &
				(type.form = IntermediateCode.Float) & (floatParameterIndex < 8)
			THEN
				register := floatParameterIndex;
				INC(floatParameterIndex);
				RETURN TRUE
			END;
			register := -1;
			RETURN FALSE
		END GetParameterRegister;

		PROCEDURE SupportedInstruction*(CONST instruction: IntermediateCode.Instruction;
			VAR moduleName, procedureName: ARRAY OF CHAR): BOOLEAN;
		BEGIN
			RETURN cg.Supported(instruction, moduleName, procedureName)
		END SupportedInstruction;

		PROCEDURE GenerateBinary(module: Sections.Module; dump: Streams.Writer);
		VAR in: Sections.Section; out: BinaryCode.Section; procedure: SyntaxTree.Procedure;
			i, j, initialSectionCount: SIZE;

			PROCEDURE ResolvedSection(section: IntermediateCode.Section): BinaryCode.Section;
			VAR result: BinaryCode.Section; minimumAlignment: SIZE;
			BEGIN
				IF section.resolved = NIL THEN
					NEW(result, section.type, 8, section.name, section.comments # NIL, FALSE);
					(* Static module headers contain 64-bit atomic GC links.
					   Four-byte code alignment is not sufficient for those headers. *)
					minimumAlignment := 4;
					IF (section.type = Sections.VarSection) OR (section.type = Sections.ConstSection) THEN
						minimumAlignment := 8
					END;
					IF ~section.fixed & (section.positionOrAlignment < minimumAlignment) THEN
						result.SetAlignment(FALSE, minimumAlignment)
					ELSE
						result.SetAlignment(section.fixed, section.positionOrAlignment)
					END;
					section.SetResolved(result)
				ELSE
					result := section.resolved
				END;
				RETURN result
			END ResolvedSection;

			PROCEDURE PatchFixups(section: BinaryCode.Section);
			VAR fixup: BinaryCode.Fixup; symbol: Sections.Section;
				input: IntermediateCode.Section; symbolOffset, displacement: SIZE;
			BEGIN
				fixup := section.fixupList.firstFixup;
				WHILE fixup # NIL DO
					symbol := module.allSections.FindByName(fixup.symbol.name);
					IF (symbol # NIL) & (symbol(IntermediateCode.Section).resolved # NIL) THEN
						input := symbol(IntermediateCode.Section);
						symbolOffset := fixup.symbolOffset;
						IF symbolOffset = input.pc THEN
							displacement := input.resolved.pc
						ELSIF symbolOffset # 0 THEN
							displacement := input.instructions[symbolOffset].pc
						ELSE
							displacement := 0
						END;
						fixup.SetSymbol(fixup.symbol.name, fixup.symbol.fingerprint, 0,
							fixup.displacement + displacement)
					END;
					fixup := fixup.nextFixup
				END
			END PatchFixups;

		BEGIN
			cg.SetModule(module);
			FOR i := 0 TO module.allSections.Length() - 1 DO
				in := module.allSections.GetSection(i);
				IF in.type = Sections.InlineCodeSection THEN
					out := ResolvedSection(in(IntermediateCode.Section));
					cg.Section(in(IntermediateCode.Section), out);
					IF in.symbol # NIL THEN
						procedure := in.symbol(SyntaxTree.Procedure);
						IF procedure.procedureScope.body.code # NIL THEN
							procedure.procedureScope.body.code.SetBinaryCode(out.os.bits)
						END
					END
				END
			END;

			initialSectionCount := 0;
			REPEAT
				j := initialSectionCount;
				initialSectionCount := module.allSections.Length();
				FOR i := j TO initialSectionCount - 1 DO
					in := module.allSections.GetSection(i);
					IF (in.type # Sections.InlineCodeSection) &
						(in(IntermediateCode.Section).resolved = NIL)
					THEN
						out := ResolvedSection(in(IntermediateCode.Section));
						cg.Section(in(IntermediateCode.Section), out)
					END
				END
			UNTIL initialSectionCount = module.allSections.Length();

			FOR i := 0 TO module.allSections.Length() - 1 DO
				in := module.allSections.GetSection(i);
				PatchFixups(in(IntermediateCode.Section).resolved)
			END;

			IF cg.error THEN Error("", Basic.invalidPosition, Streams.Invalid, "") END
		END GenerateBinary;

		PROCEDURE ProcessIntermediateCodeModule*(module: Formats.GeneratedModule): Formats.GeneratedModule;
		VAR result: Formats.GeneratedModule;
		BEGIN
			ASSERT(module IS Sections.Module);
			result := ProcessIntermediateCodeModule^(module);
			IF ~error THEN
				GenerateBinary(result(Sections.Module), dump);
				IF dump # NIL THEN
					dump.Ln; dump.String(";------------------ binary code -------------------"); dump.Ln;
					result.Dump(dump); dump.Update
				END
			END;
			RETURN result
		END ProcessIntermediateCodeModule;

		PROCEDURE DefaultObjectFileFormat*(): Formats.ObjectFileFormat;
		BEGIN
			RETURN ObjectFileFormat.Get()
		END DefaultObjectFileFormat;

		PROCEDURE DefaultSymbolFileFormat*(): Formats.SymbolFileFormat;
		BEGIN
			RETURN NIL
		END DefaultSymbolFileFormat;

		PROCEDURE GetDescription*(VAR instructionSet: ARRAY OF CHAR);
		BEGIN
			instructionSet := "AArch64"
		END GetDescription;

	END BackendAArch64;

PROCEDURE Get*(): Backend.Backend;
VAR backend: BackendAArch64;
BEGIN
	NEW(backend);
	RETURN backend
END Get;

END FoxAArch64Backend.
