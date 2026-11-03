MODULE Drawterm9P;

(** Minimal synchronous 9P2000 client for drawterm's direct (-D) export.
    The connection uses one full-duplex inherited descriptor. *)

IMPORT S := SYSTEM, Unix;

CONST
	TVersion* = 100; RVersion* = 101;
	TAttach* = 104; RError* = 107; RAttach* = 105;
	TWalk* = 110; RWalk* = 111;
	TOpen* = 112; ROpen* = 113;
	TRead* = 116; RRead* = 117;
	TWrite* = 118; RWrite* = 119;
	TClunk* = 120; RClunk* = 121;

	NoTag = 0FFFFH;
	RootFid* = 1;
	NoFid = 0FFFFFFFFH;
	BufferSize = 65536;

	ReadOnly* = 0; WriteOnly* = 1; ReadWrite* = 2;

TYPE
	Connection* = OBJECT
	VAR
		fd: SIGNED32;
		nextTag: SIGNED32;
		msize-: SIGNED32;
		buffer: POINTER TO ARRAY OF CHAR;
		lastError: ARRAY 256 OF CHAR;

		PROCEDURE &Init*(descriptor: SIGNED32);
		BEGIN
			fd := descriptor; nextTag := 1; msize := 0;
			NEW(buffer, BufferSize); lastError[0] := 0X
		END Init;

		PROCEDURE SetError(CONST text: ARRAY OF CHAR);
		VAR i: SIZE;
		BEGIN
			i := 0;
			WHILE (i + 1 < LEN(lastError)) & (i < LEN(text)) & (text[i] # 0X) DO
				lastError[i] := text[i]; INC(i)
			END;
			lastError[i] := 0X
		END SetError;

		PROCEDURE Error* (VAR text: ARRAY OF CHAR);
		VAR i: SIZE;
		BEGIN
			i := 0;
			WHILE (i + 1 < LEN(text)) & (lastError[i] # 0X) DO
				text[i] := lastError[i]; INC(i)
			END;
			IF LEN(text) > 0 THEN text[i] := 0X END
		END Error;

		PROCEDURE ReadExact(pos, count: SIZE): BOOLEAN;
		VAR n, done: SIZE;
		BEGIN
			done := 0;
			WHILE done < count DO
				LOOP
					n := Unix.read(fd, S.ADR(buffer[pos + done]), count - done);
					IF n >= 0 THEN EXIT END;
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (n <= 0) OR (n > count - done) THEN
					SetError("drawterm 9P read failed"); RETURN FALSE
				END;
				INC(done, n)
			END;
			RETURN TRUE
		END ReadExact;

		PROCEDURE WriteExact(count: SIZE): BOOLEAN;
		VAR n, done: SIZE;
		BEGIN
			done := 0;
			WHILE done < count DO
				LOOP
					n := Unix.write(fd, S.ADR(buffer[done]), count - done);
					IF n >= 0 THEN EXIT END;
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (n <= 0) OR (n > count - done) THEN
					SetError("drawterm 9P write failed"); RETURN FALSE
				END;
				INC(done, n)
			END;
			RETURN TRUE
		END WriteExact;

		PROCEDURE RemoteError;
		VAR i, n: SIZE;
		BEGIN
			n := Get16(buffer^, 7); i := 0;
			WHILE (i < n) & (i + 1 < LEN(lastError)) & (9 + i < LEN(buffer)) DO
				lastError[i] := buffer[9 + i]; INC(i)
			END;
			lastError[i] := 0X
		END RemoteError;

		PROCEDURE RPC(kind, expected, tag: SIGNED32; length: SIZE): BOOLEAN;
		VAR replyLength: SIZE; replyKind, replyTag: SIGNED32;
		BEGIN
			Put32(buffer^, 0, UNSIGNED32(length));
			buffer[4] := CHR(kind); Put16(buffer^, 5, tag);
			IF ~WriteExact(length) OR ~ReadExact(0, 7) THEN RETURN FALSE END;
			replyLength := SIZE(Get32(buffer^, 0));
			IF (replyLength < 7) OR (replyLength > LEN(buffer)) THEN
				SetError("invalid drawterm 9P message size"); RETURN FALSE
			END;
			IF ~ReadExact(7, replyLength - 7) THEN RETURN FALSE END;
			replyKind := ORD(buffer[4]); replyTag := Get16(buffer^, 5);
			IF replyTag # tag THEN SetError("drawterm 9P tag mismatch"); RETURN FALSE END;
			IF replyKind = RError THEN RemoteError; RETURN FALSE END;
			IF replyKind # expected THEN SetError("unexpected drawterm 9P reply"); RETURN FALSE END;
			RETURN TRUE
		END RPC;

		PROCEDURE Handshake*(): BOOLEAN;
		VAR p, n: SIZE; negotiated: SIGNED32;
		BEGIN
			lastError[0] := 0X; p := 7;
			Put32(buffer^, p, 65536); INC(p, 4);
			PutString(buffer^, p, "9P2000");
			IF ~RPC(TVersion, RVersion, NoTag, p) THEN RETURN FALSE END;
			negotiated := SIGNED32(Get32(buffer^, 7));
			n := Get16(buffer^, 11);
			IF (negotiated < 256) OR (negotiated > LEN(buffer)) OR
				(n # 6) OR ~EqualAt(buffer^, 13, "9P2000") THEN
				SetError("drawterm did not negotiate 9P2000"); RETURN FALSE
			END;
			msize := negotiated;

			p := 7; Put32(buffer^, p, RootFid); INC(p, 4);
			Put32(buffer^, p, NoFid); INC(p, 4);
			PutString(buffer^, p, "oberon"); PutString(buffer^, p, "");
			RETURN TaggedRPC(TAttach, RAttach, p)
		END Handshake;

		PROCEDURE TaggedRPC(kind, expected: SIGNED32; length: SIZE): BOOLEAN;
		VAR tag: SIGNED32;
		BEGIN
			tag := nextTag; INC(nextTag);
			IF nextTag = NoTag THEN nextTag := 1 END;
			RETURN RPC(kind, expected, tag, length)
		END TaggedRPC;

		PROCEDURE Walk*(sourceFid, newFid: SIGNED32; CONST path: ARRAY OF CHAR): BOOLEAN;
		VAR p, countPos, start, i, count: SIZE;
		BEGIN
			p := 7; Put32(buffer^, p, UNSIGNED32(sourceFid)); INC(p, 4);
			Put32(buffer^, p, UNSIGNED32(newFid)); INC(p, 4);
			countPos := p; INC(p, 2); count := 0; i := 0;
			WHILE (i < LEN(path)) & (path[i] # 0X) DO
				WHILE (i < LEN(path)) & (path[i] = "/") DO INC(i) END;
				start := i;
				WHILE (i < LEN(path)) & (path[i] # 0X) & (path[i] # "/") DO INC(i) END;
				IF i > start THEN
					IF (i - start > 65535) OR (p + 2 + i - start > LEN(buffer)) THEN
						SetError("drawterm 9P path is too long"); RETURN FALSE
					END;
					Put16(buffer^, p, SIGNED32(i - start)); INC(p, 2);
					WHILE start < i DO buffer[p] := path[start]; INC(p); INC(start) END;
					INC(count)
				END
			END;
			Put16(buffer^, countPos, SIGNED32(count));
			IF ~TaggedRPC(TWalk, RWalk, p) THEN RETURN FALSE END;
			IF Get16(buffer^, 7) # SIGNED32(count) THEN
				SetError("drawterm 9P partial walk"); RETURN FALSE
			END;
			RETURN TRUE
		END Walk;

		PROCEDURE Open*(fid, mode: SIGNED32): BOOLEAN;
		VAR p: SIZE;
		BEGIN
			p := 7; Put32(buffer^, p, UNSIGNED32(fid)); INC(p, 4);
			buffer[p] := CHR(mode); INC(p);
			RETURN TaggedRPC(TOpen, ROpen, p)
		END Open;

		PROCEDURE Read*(fid: SIGNED32; offset: UNSIGNED64; VAR data: ARRAY OF CHAR;
			count: SIZE; VAR got: SIZE): BOOLEAN;
		VAR p, i, available: SIZE;
		BEGIN
			got := 0;
			IF count > LEN(data) THEN count := LEN(data) END;
			IF (msize > 11) & (count > SIZE(msize - 11)) THEN count := SIZE(msize - 11) END;
			p := 7; Put32(buffer^, p, UNSIGNED32(fid)); INC(p, 4);
			Put64(buffer^, p, offset); INC(p, 8);
			Put32(buffer^, p, UNSIGNED32(count)); INC(p, 4);
			IF ~TaggedRPC(TRead, RRead, p) THEN RETURN FALSE END;
			available := SIZE(Get32(buffer^, 7));
			IF (available > count) OR (11 + available > LEN(buffer)) THEN
				SetError("invalid drawterm 9P read count"); RETURN FALSE
			END;
			IF available > 0 THEN
				FOR i := 0 TO available - 1 DO data[i] := buffer[11 + i] END
			END;
			got := available; RETURN TRUE
		END Read;

		PROCEDURE Write*(fid: SIGNED32; offset: UNSIGNED64; CONST data: ARRAY OF CHAR;
			ofs, count: SIZE): BOOLEAN;
		VAR p, i, written: SIZE;
		BEGIN
			IF (ofs + count > LEN(data)) OR (count + 23 > LEN(buffer)) OR
				((msize > 0) & (count + 23 > SIZE(msize))) THEN
				SetError("drawterm 9P write is too large"); RETURN FALSE
			END;
			p := 7; Put32(buffer^, p, UNSIGNED32(fid)); INC(p, 4);
			Put64(buffer^, p, offset); INC(p, 8);
			Put32(buffer^, p, UNSIGNED32(count)); INC(p, 4);
			IF count > 0 THEN
				FOR i := 0 TO count - 1 DO buffer[p + i] := data[ofs + i] END
			END;
			INC(p, count);
			IF ~TaggedRPC(TWrite, RWrite, p) THEN RETURN FALSE END;
			written := SIZE(Get32(buffer^, 7));
			IF written # count THEN SetError("short drawterm 9P write"); RETURN FALSE END;
			RETURN TRUE
		END Write;

		PROCEDURE Clunk*(fid: SIGNED32): BOOLEAN;
		VAR p: SIZE;
		BEGIN
			p := 7; Put32(buffer^, p, UNSIGNED32(fid)); INC(p, 4);
			RETURN TaggedRPC(TClunk, RClunk, p)
		END Clunk;

	END Connection;


PROCEDURE Put16(VAR data: ARRAY OF CHAR; pos: SIZE; value: SIGNED32);
BEGIN
	data[pos] := CHR(value MOD 256); data[pos + 1] := CHR(value DIV 256 MOD 256)
END Put16;

PROCEDURE Put32(VAR data: ARRAY OF CHAR; pos: SIZE; value: UNSIGNED32);
VAR i: SIZE;
BEGIN
	FOR i := 0 TO 3 DO data[pos + i] := CHR(value MOD 256); value := value DIV 256 END
END Put32;

PROCEDURE Put64(VAR data: ARRAY OF CHAR; pos: SIZE; value: UNSIGNED64);
VAR i: SIZE;
BEGIN
	FOR i := 0 TO 7 DO data[pos + i] := CHR(value MOD 256); value := value DIV 256 END
END Put64;

PROCEDURE Get16(CONST data: ARRAY OF CHAR; pos: SIZE): SIGNED32;
BEGIN
	RETURN SIGNED32(ORD(data[pos])) + 256 * SIGNED32(ORD(data[pos + 1]))
END Get16;

PROCEDURE Get32(CONST data: ARRAY OF CHAR; pos: SIZE): UNSIGNED32;
VAR i: SIGNED32; value: UNSIGNED32;
BEGIN
	value := 0;
	FOR i := 3 TO 0 BY -1 DO value := value * 256 + UNSIGNED32(ORD(data[pos + SIZE(i)])) END;
	RETURN value
END Get32;

PROCEDURE PutString(VAR data: ARRAY OF CHAR; VAR pos: SIZE; CONST text: ARRAY OF CHAR);
VAR start, n: SIZE;
BEGIN
	start := pos; INC(pos, 2); n := 0;
	WHILE (n < LEN(text)) & (text[n] # 0X) DO data[pos] := text[n]; INC(pos); INC(n) END;
	Put16(data, start, SIGNED32(n))
END PutString;

PROCEDURE EqualAt(CONST data: ARRAY OF CHAR; pos: SIZE; CONST text: ARRAY OF CHAR): BOOLEAN;
VAR i: SIZE;
BEGIN
	i := 0;
	WHILE (i < LEN(text)) & (text[i] # 0X) DO
		IF (pos + i >= LEN(data)) OR (data[pos + i] # text[i]) THEN RETURN FALSE END;
		INC(i)
	END;
	RETURN TRUE
END EqualAt;

PROCEDURE EnvironmentFD*(): SIGNED32;
VAR address: ADDRESS; ch: CHAR; value: SIGNED32;
BEGIN
	address := Unix.getenv(ADDRESSOF("A2_DRAWTERM_FD"));
	IF address = 0 THEN RETURN -1 END;
	value := 0; S.GET(address, ch);
	IF (ch < "0") OR (ch > "9") THEN RETURN -1 END;
	WHILE (ch >= "0") & (ch <= "9") DO
		value := value * 10 + ORD(ch) - ORD("0");
		INC(address); S.GET(address, ch)
	END;
	RETURN value
END EnvironmentFD;

PROCEDURE Probe*(descriptor: SIGNED32; VAR error: ARRAY OF CHAR): BOOLEAN;
VAR connection: Connection; control: ARRAY 144 OF CHAR; flush: ARRAY 1 OF CHAR;
	dataPath: ARRAY 64 OF CHAR; got: SIZE; clientId: SIGNED32;

	PROCEDURE Failed(): BOOLEAN;
	BEGIN
		connection.Error(error); RETURN FALSE
	END Failed;

	PROCEDURE CheckPath(CONST path: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		IF ~connection.Walk(RootFid, 2, path) THEN RETURN FALSE END;
		IF ~connection.Clunk(2) THEN RETURN FALSE END;
		RETURN TRUE
	END CheckPath;

	PROCEDURE ClientId(): SIGNED32;
	VAR i: SIZE; value: SIGNED32;
	BEGIN
		i := 0; value := 0;
		WHILE (i < LEN(control)) & (control[i] = " ") DO INC(i) END;
		IF (i = LEN(control)) OR (control[i] < "0") OR (control[i] > "9") THEN RETURN -1 END;
		WHILE (i < LEN(control)) & (control[i] >= "0") & (control[i] <= "9") DO
			value := value * 10 + ORD(control[i]) - ORD("0"); INC(i)
		END;
		RETURN value
	END ClientId;

	PROCEDURE MakeDataPath(id: SIGNED32);
	VAR digits: ARRAY 12 OF CHAR; suffix: ARRAY 6 OF CHAR; i, n, j: SIZE;
	BEGIN
		COPY("dev/draw/", dataPath); i := 0;
		WHILE dataPath[i] # 0X DO INC(i) END;
		n := 0;
		REPEAT digits[n] := CHR(ORD("0") + id MOD 10); id := id DIV 10; INC(n) UNTIL id = 0;
		WHILE n > 0 DO DEC(n); dataPath[i] := digits[n]; INC(i) END;
		COPY("/data", suffix); j := 0;
		WHILE suffix[j] # 0X DO dataPath[i] := suffix[j]; INC(i); INC(j) END;
		dataPath[i] := 0X
	END MakeDataPath;

BEGIN
	NEW(connection, descriptor);
	IF ~connection.Handshake() THEN RETURN Failed() END;
	IF ~connection.Walk(RootFid, 2, "dev/draw/new") THEN RETURN Failed() END;
	IF ~connection.Open(2, ReadWrite) THEN RETURN Failed() END;
	IF ~connection.Read(2, 0, control, LEN(control), got) OR (got # LEN(control)) THEN RETURN Failed() END;
	clientId := ClientId();
	IF clientId < 0 THEN connection.SetError("invalid drawterm control record"); RETURN Failed() END;
	MakeDataPath(clientId);
	IF ~connection.Walk(RootFid, 3, dataPath) THEN RETURN Failed() END;
	IF ~connection.Open(3, WriteOnly) THEN RETURN Failed() END;
	flush[0] := "v";
	IF ~connection.Write(3, 0, flush, 0, 1) THEN RETURN Failed() END;
	IF ~connection.Clunk(3) OR ~connection.Clunk(2) THEN RETURN Failed() END;
	IF ~CheckPath("dev/mouse") THEN RETURN Failed() END;
	IF ~CheckPath("dev/kbd") THEN RETURN Failed() END;
	IF ~CheckPath("dev/snarf") THEN RETURN Failed() END;
	error[0] := 0X; RETURN TRUE
END Probe;

END Drawterm9P.
