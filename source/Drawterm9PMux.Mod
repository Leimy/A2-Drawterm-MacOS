MODULE Drawterm9PMux;

(** Concurrent 9P2000 client for drawterm's direct (-D) export. *)

IMPORT S := SYSTEM, Unix;

CONST
	TVersion* = 100; RVersion* = 101; TAttach* = 104; RAttach* = 105; RError* = 107;
	TWalk* = 110; RWalk* = 111; TOpen* = 112; ROpen* = 113;
	TRead* = 116; RRead* = 117; TWrite* = 118; RWrite* = 119;
	TClunk* = 120; RClunk* = 121;
	NoTag = 0FFFFH; RootFid* = 1; NoFid = 0FFFFFFFFH; BufferSize = 65536;
	ReadOnly* = 0; WriteOnly* = 1; ReadWrite* = 2;

TYPE
	Request = OBJECT
	VAR next: Request; tag, expected: SIGNED32; buffer: POINTER TO ARRAY OF CHAR;
		done, ok: BOOLEAN; error: ARRAY 256 OF CHAR;

		PROCEDURE &Init*(size: SIZE);
		BEGIN NEW(buffer, size); done := FALSE; ok := FALSE; error[0] := 0X END Init;

		PROCEDURE Complete(kind: SIGNED32; message: POINTER TO ARRAY OF CHAR; length: SIZE);
		VAR i, n: SIZE;
		BEGIN {EXCLUSIVE}
			IF kind = expected THEN ok := TRUE
			ELSIF kind = RError THEN
				n := Get16(message^, 7); i := 0;
				WHILE (i < n) & (i + 1 < LEN(error)) & (9 + i < LEN(message)) DO
					error[i] := message[9 + i]; INC(i)
				END; error[i] := 0X
			ELSE COPY("unexpected drawterm 9P reply", error)
			END;
			IF ok THEN
				IF length > LEN(buffer) THEN ok := FALSE; COPY("drawterm 9P reply is too large", error)
				ELSIF length > 0 THEN FOR i := 0 TO length - 1 DO buffer[i] := message[i] END
				END
			END;
			done := TRUE
		END Complete;

		PROCEDURE Fail(CONST text: ARRAY OF CHAR);
		BEGIN {EXCLUSIVE} COPY(text, error); done := TRUE; ok := FALSE END Fail;

		PROCEDURE Wait(): BOOLEAN;
		BEGIN {EXCLUSIVE} AWAIT(done); RETURN ok END Wait;
	END Request;

	Connection* = OBJECT
	VAR fd: SIGNED32; nextTag: SIGNED32; msize-: SIGNED32;
		sync: POINTER TO ARRAY OF CHAR; pending: Request;
		multiplexed, failed: BOOLEAN; lastError: ARRAY 256 OF CHAR;

		PROCEDURE &Init*(descriptor: SIGNED32);
		BEGIN
			fd := descriptor; nextTag := 1; msize := 0; pending := NIL;
			multiplexed := FALSE; failed := FALSE; NEW(sync, BufferSize); lastError[0] := 0X
		END Init;

		PROCEDURE SetError(CONST text: ARRAY OF CHAR);
		BEGIN {EXCLUSIVE} COPY(text, lastError) END SetError;

		PROCEDURE Error*(VAR text: ARRAY OF CHAR);
		BEGIN {EXCLUSIVE} COPY(lastError, text) END Error;

		PROCEDURE ReadExact(VAR data: ARRAY OF CHAR; pos, count: SIZE): BOOLEAN;
		VAR n, done: SIZE;
		BEGIN
			done := 0;
			WHILE done < count DO
				LOOP
					n := Unix.read(fd, S.ADR(data[pos + done]), count - done);
					IF n >= 0 THEN EXIT END;
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (n <= 0) OR (n > count - done) THEN RETURN FALSE END;
				INC(done, n)
			END; RETURN TRUE
		END ReadExact;

		PROCEDURE WriteExact(CONST data: ARRAY OF CHAR; count: SIZE): BOOLEAN;
		VAR n, done: SIZE;
		BEGIN
			done := 0;
			WHILE done < count DO
				LOOP
					n := Unix.write(fd, S.ADR(data[done]), count - done);
					IF n >= 0 THEN EXIT END;
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (n <= 0) OR (n > count - done) THEN RETURN FALSE END;
				INC(done, n)
			END; RETURN TRUE
		END WriteExact;

		PROCEDURE SyncRPC(kind, expected, tag: SIGNED32; length: SIZE): BOOLEAN;
		VAR replyLength: SIZE;
		BEGIN
			Put32(sync^, 0, UNSIGNED32(length)); sync[4] := CHR(kind); Put16(sync^, 5, tag);
			IF ~WriteExact(sync^, length) THEN
				SetError("drawterm 9P transport failed"); RETURN FALSE
			END;
			IF ~ReadExact(sync^, 0, 7) THEN
				SetError("drawterm 9P transport failed"); RETURN FALSE
			END;
			replyLength := SIZE(Get32(sync^, 0));
			IF replyLength < 7 THEN
				SetError("invalid drawterm 9P message"); RETURN FALSE
			END;
			IF replyLength > LEN(sync) THEN
				SetError("invalid drawterm 9P message"); RETURN FALSE
			END;
			IF ~ReadExact(sync^, 7, replyLength - 7) THEN
				SetError("invalid drawterm 9P message"); RETURN FALSE
			END;
			IF Get16(sync^, 5) # tag THEN SetError("drawterm 9P tag mismatch"); RETURN FALSE END;
			IF ORD(sync[4]) = RError THEN CopyRemoteError(sync^); RETURN FALSE END;
			IF ORD(sync[4]) # expected THEN SetError("unexpected drawterm 9P reply"); RETURN FALSE END;
			RETURN TRUE
		END SyncRPC;

		PROCEDURE CopyRemoteError(CONST data: ARRAY OF CHAR);
		VAR i, n: SIZE; text: ARRAY 256 OF CHAR;
		BEGIN
			n := Get16(data, 7); i := 0;
			WHILE (i < n) & (i + 1 < LEN(text)) & (9 + i < LEN(data)) DO
				text[i] := data[9 + i]; INC(i)
			END; text[i] := 0X; SetError(text)
		END CopyRemoteError;

		PROCEDURE Submit(request: Request; kind, expected: SIGNED32; length: SIZE);
		BEGIN {EXCLUSIVE}
			IF failed THEN request.Fail("drawterm 9P connection failed"); RETURN END;
			request.tag := nextTag; request.expected := expected; INC(nextTag);
			IF nextTag = NoTag THEN nextTag := 1 END;
			Put32(request.buffer^, 0, UNSIGNED32(length)); request.buffer[4] := CHR(kind);
			Put16(request.buffer^, 5, request.tag);
			request.next := pending; pending := request;
			IF ~WriteExact(request.buffer^, length) THEN
				Remove(request); request.Fail("drawterm 9P write failed")
			END
		END Submit;

		PROCEDURE Remove(request: Request);
		VAR p: Request;
		BEGIN
			IF pending = request THEN pending := request.next
			ELSE p := pending; WHILE (p # NIL) & (p.next # request) DO p := p.next END;
				IF p # NIL THEN p.next := request.next END
			END
		END Remove;

		PROCEDURE Take(tag: SIGNED32): Request;
		VAR p, q: Request;
		BEGIN {EXCLUSIVE}
			p := pending; q := NIL;
			WHILE (p # NIL) & (p.tag # tag) DO q := p; p := p.next END;
			IF p # NIL THEN IF q = NIL THEN pending := p.next ELSE q.next := p.next END END;
			RETURN p
		END Take;

		PROCEDURE FailAll;
		VAR p: Request;
		BEGIN {EXCLUSIVE}
			failed := TRUE; p := pending; pending := NIL;
			WHILE p # NIL DO p.Fail("drawterm 9P read failed"); p := p.next END
		END FailAll;

		PROCEDURE RPC(request: Request; kind, expected: SIGNED32; length: SIZE): BOOLEAN;
		BEGIN
			Submit(request, kind, expected, length);
			IF request.Wait() THEN RETURN TRUE END;
			SetError(request.error); RETURN FALSE
		END RPC;

		PROCEDURE Handshake*(): BOOLEAN;
		VAR p, n: SIZE; negotiated: SIGNED32;
		BEGIN
			p := 7; Put32(sync^, p, BufferSize); INC(p, 4); PutString(sync^, p, "9P2000");
			IF ~SyncRPC(TVersion, RVersion, NoTag, p) THEN RETURN FALSE END;
			negotiated := SIGNED32(Get32(sync^, 7)); n := Get16(sync^, 11);
			IF (negotiated < 256) OR (negotiated > BufferSize) OR (n # 6) OR
				~EqualAt(sync^, 13, "9P2000") THEN SetError("drawterm did not negotiate 9P2000"); RETURN FALSE END;
			msize := negotiated; p := 7; Put32(sync^, p, RootFid); INC(p, 4);
			Put32(sync^, p, NoFid); INC(p, 4); PutString(sync^, p, "oberon"); PutString(sync^, p, "");
			IF ~SyncRPC(TAttach, RAttach, 1, p) THEN RETURN FALSE END;
			BEGIN {EXCLUSIVE} nextTag := 2; multiplexed := TRUE END;
			RETURN TRUE
		END Handshake;

		PROCEDURE Walk*(sourceFid, newFid: SIGNED32; CONST path: ARRAY OF CHAR): BOOLEAN;
		VAR r: Request; p, cp, start, i, count: SIZE;
		BEGIN
			(* Rwalk returns a 13-byte qid for every path element, so its reply can be
			   larger than the encoded path in the request. *)
			NEW(r, 32 + 14 * LEN(path)); p := 7; Put32(r.buffer^, p, UNSIGNED32(sourceFid)); INC(p,4);
			Put32(r.buffer^, p, UNSIGNED32(newFid)); INC(p,4); cp := p; INC(p,2); count := 0; i := 0;
			WHILE (i < LEN(path)) & (path[i] # 0X) DO
				WHILE (i < LEN(path)) & (path[i] = "/") DO INC(i) END; start := i;
				WHILE (i < LEN(path)) & (path[i] # 0X) & (path[i] # "/") DO INC(i) END;
				IF i > start THEN Put16(r.buffer^, p, SIGNED32(i-start)); INC(p,2);
					WHILE start < i DO r.buffer[p] := path[start]; INC(p); INC(start) END; INC(count) END
			END; Put16(r.buffer^, cp, SIGNED32(count));
			IF ~RPC(r, TWalk, RWalk, p) THEN RETURN FALSE END;
			IF Get16(r.buffer^, 7) # SIGNED32(count) THEN SetError("drawterm 9P partial walk"); RETURN FALSE END;
			RETURN TRUE
		END Walk;

		PROCEDURE Open*(fid, mode: SIGNED32): BOOLEAN;
		VAR r: Request; p: SIZE;
		BEGIN NEW(r, 24); p := 7; Put32(r.buffer^,p,UNSIGNED32(fid)); INC(p,4);
			r.buffer[p] := CHR(mode); INC(p); RETURN RPC(r, TOpen, ROpen, p)
		END Open;

		PROCEDURE Read*(fid: SIGNED32; offset: UNSIGNED64; VAR data: ARRAY OF CHAR; count: SIZE; VAR got: SIZE): BOOLEAN;
		VAR r: Request; p, i, available: SIZE;
		BEGIN
			got := 0; IF count > LEN(data) THEN count := LEN(data) END;
			IF count > SIZE(msize-11) THEN count := SIZE(msize-11) END;
			NEW(r, 23 + count); p := 7; Put32(r.buffer^,p,UNSIGNED32(fid)); INC(p,4);
			Put64(r.buffer^,p,offset); INC(p,8); Put32(r.buffer^,p,UNSIGNED32(count)); INC(p,4);
			IF ~RPC(r,TRead,RRead,p) THEN RETURN FALSE END; available := SIZE(Get32(r.buffer^,7));
			IF (available > count) OR (11+available > LEN(r.buffer)) THEN SetError("invalid drawterm 9P read count"); RETURN FALSE END;
			IF available > 0 THEN FOR i := 0 TO available-1 DO data[i] := r.buffer[11+i] END END;
			got := available; RETURN TRUE
		END Read;

		PROCEDURE Write*(fid: SIGNED32; offset: UNSIGNED64; CONST data: ARRAY OF CHAR; ofs,count: SIZE): BOOLEAN;
		VAR r: Request; p,i,written: SIZE;
		BEGIN
			IF (ofs+count > LEN(data)) OR (count+23 > SIZE(msize)) THEN SetError("drawterm 9P write is too large"); RETURN FALSE END;
			NEW(r,count+23); p:=7; Put32(r.buffer^,p,UNSIGNED32(fid)); INC(p,4); Put64(r.buffer^,p,offset); INC(p,8);
			Put32(r.buffer^,p,UNSIGNED32(count)); INC(p,4);
			IF count>0 THEN FOR i:=0 TO count-1 DO r.buffer[p+i]:=data[ofs+i] END END; INC(p,count);
			IF ~RPC(r,TWrite,RWrite,p) THEN RETURN FALSE END; written:=SIZE(Get32(r.buffer^,7));
			IF written#count THEN SetError("short drawterm 9P write"); RETURN FALSE END; RETURN TRUE
		END Write;

		PROCEDURE Clunk*(fid: SIGNED32): BOOLEAN;
		VAR r: Request; p: SIZE;
		BEGIN NEW(r,16); p:=7; Put32(r.buffer^,p,UNSIGNED32(fid)); INC(p,4); RETURN RPC(r,TClunk,RClunk,p) END Clunk;

		PROCEDURE ReceiveLoop;
		VAR message: POINTER TO ARRAY OF CHAR; length: SIZE; r: Request;
		BEGIN
			NEW(message, SIZE(msize));
			LOOP
				IF ~ReadExact(message^,0,7) THEN FailAll; EXIT END;
				length:=SIZE(Get32(message^,0));
				IF length<7 THEN FailAll; EXIT END;
				IF length>LEN(message) THEN FailAll; EXIT END;
				IF ~ReadExact(message^,7,length-7) THEN FailAll; EXIT END;
				r:=Take(Get16(message^,5)); IF r#NIL THEN r.Complete(ORD(message[4]),message,length) END
			END
		END ReceiveLoop;

	BEGIN {ACTIVE}
		BEGIN {EXCLUSIVE} AWAIT(multiplexed) END;
		ReceiveLoop
	END Connection;

PROCEDURE Put16(VAR d: ARRAY OF CHAR; p: SIZE; v: SIGNED32); BEGIN d[p]:=CHR(v MOD 256); d[p+1]:=CHR(v DIV 256 MOD 256) END Put16;
PROCEDURE Put32(VAR d: ARRAY OF CHAR; p: SIZE; v: UNSIGNED32); VAR i:SIZE; BEGIN FOR i:=0 TO 3 DO d[p+i]:=CHR(v MOD 256); v:=v DIV 256 END END Put32;
PROCEDURE Put64(VAR d: ARRAY OF CHAR; p: SIZE; v: UNSIGNED64); VAR i:SIZE; BEGIN FOR i:=0 TO 7 DO d[p+i]:=CHR(v MOD 256); v:=v DIV 256 END END Put64;
PROCEDURE Get16(CONST d: ARRAY OF CHAR; p: SIZE): SIGNED32; BEGIN RETURN SIGNED32(ORD(d[p]))+256*SIGNED32(ORD(d[p+1])) END Get16;
PROCEDURE Get32(CONST d: ARRAY OF CHAR; p: SIZE): UNSIGNED32; VAR i:SIGNED32; v:UNSIGNED32; BEGIN v:=0; FOR i:=3 TO 0 BY -1 DO v:=v*256+UNSIGNED32(ORD(d[p+SIZE(i)])) END; RETURN v END Get32;
PROCEDURE PutString(VAR d: ARRAY OF CHAR; VAR p: SIZE; CONST s: ARRAY OF CHAR); VAR q,n:SIZE; BEGIN q:=p; INC(p,2); n:=0; WHILE (n<LEN(s))&(s[n]#0X) DO d[p]:=s[n];INC(p);INC(n) END;Put16(d,q,SIGNED32(n)) END PutString;
PROCEDURE EqualAt(CONST d: ARRAY OF CHAR; p: SIZE; CONST s: ARRAY OF CHAR):BOOLEAN; VAR i:SIZE; BEGIN i:=0; WHILE (i<LEN(s))&(s[i]#0X) DO IF (p+i>=LEN(d))OR(d[p+i]#s[i]) THEN RETURN FALSE END;INC(i) END;RETURN TRUE END EqualAt;

PROCEDURE EnvironmentFD*(): SIGNED32;
VAR address: ADDRESS; ch: CHAR; value: SIGNED32;
BEGIN
	address := Unix.getenv(ADDRESSOF("A2_DRAWTERM_FD")); IF address = 0 THEN RETURN -1 END;
	value := 0; S.GET(address, ch); IF (ch < "0") OR (ch > "9") THEN RETURN -1 END;
	WHILE (ch >= "0") & (ch <= "9") DO value := value * 10 + ORD(ch) - ORD("0"); INC(address); S.GET(address, ch) END;
	RETURN value
END EnvironmentFD;

END Drawterm9PMux.
