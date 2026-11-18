MODULE DarwinTCPActivityProbe;
IMPORT A := DarwinActivities, Commands, TCP, IP, Sockets, Unix, Modules, Kernel;

CONST PayloadSize = 16 * 1024 * 1024;

PROCEDURE Loopback(VAR c: TCP.Connection; VAR peer: SIGNED32);
VAR server, res: SIGNED32; ip: IP.Adr; addr: Sockets.SocketAdr;
BEGIN
	ip := IP.StrToAdr("127.0.0.1"); ASSERT(~IP.IsNilAdr(ip));
	server := Sockets.Socket(Unix.AFINET, Unix.SockStream, Unix.IpProtoTCP); ASSERT(server >= 0);
	ASSERT(Sockets.Bind(server, Sockets.NewSocketAdr(ip, 0))); ASSERT(Sockets.Listen(server));
	addr := Sockets.GetSockName(server); ASSERT(addr # NIL);
	NEW(c); c.Open(TCP.NilPort, ip, UNSIGNED32(Sockets.GetPortNumber(addr)), res); ASSERT(res = TCP.Ok);
	peer := Sockets.Accept(server); ASSERT(peer >= 0); Sockets.Close(server)
END Loopback;

PROCEDURE SendByte(peer: SIGNED32; ch: CHAR);
VAR buf: ARRAY 1 OF CHAR; n: SIZE;
BEGIN buf[0] := ch; n := 1; ASSERT(Sockets.Send(peer, buf, 0, n)); ASSERT(n = 1) END SendByte;

TYPE
	DelayedPeer = OBJECT
	VAR fd: SIGNED32;
		PROCEDURE &Init(peer: SIGNED32);
		BEGIN fd := peer END Init;
	BEGIN {ACTIVE}
		Unix.ThrSleep(30); SendByte(fd, "N")
	END DelayedPeer;

	Reader = OBJECT(A.Activity)
	VAR c: TCP.Connection; n: SIZE; res: SIGNED32; data: ARRAY 5 OF CHAR; finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN
			data := "----"; c.Receive(data, 1, 2, 2, n, res); finished := TRUE
		END Run;
	END Reader;

	Writer = OBJECT(A.Activity)
	VAR c: TCP.Connection; peer, mode: SIGNED32; ran: BOOLEAN;
		PROCEDURE Run*;
		BEGIN
			CASE mode OF
			| 0: SendByte(peer, "2")
			| 1: Sockets.Close(peer)
			| 2: c.Discard
			END;
			ran := TRUE
		END Run;
	END Writer;

TYPE
	TrapOnEntry = OBJECT
	BEGIN {ACTIVE} HALT(73)
	END TrapOnEntry;

VAR parked: TCP.Connection; peerfd: SIGNED32; cleaned, escaped: BOOLEAN;

PROCEDURE TrapReceive*(context: Commands.Context);
VAR child: TrapOnEntry; buf: ARRAY 1 OF CHAR; n: SIZE; res: SIGNED32;
BEGIN
	Loopback(parked, peerfd); NEW(child);
	parked.Receive(buf, 0, 1, 1, n, res); escaped := TRUE
FINALLY cleaned := TRUE
END TrapReceive;

PROCEDURE TrapSend*(context: Commands.Context);
VAR child: TrapOnEntry; data: POINTER TO ARRAY OF CHAR; res: SIGNED32;
BEGIN
	Loopback(parked, peerfd); NEW(data, PayloadSize); NEW(child);
	parked.Send(data^, 0, LEN(data^), TRUE, res); escaped := TRUE
FINALLY cleaned := TRUE
END TrapSend;

PROCEDURE TrapAccept*(context: Commands.Context);
VAR child: TrapOnEntry; client: TCP.Connection; res: INTEGER;
BEGIN
	NEW(parked); parked.Open(0, IP.Nil4Adr, 0, res); ASSERT(res = TCP.Ok);
	NEW(child); parked.Accept(client, res); escaped := TRUE
FINALLY cleaned := TRUE
END TrapAccept;

PROCEDURE TrapConnect*(context: Commands.Context);
VAR child: TrapOnEntry; res: INTEGER; listener: TCP.Connection;
BEGIN
	NEW(listener); listener.Open(0, IP.Nil4Adr, 0, res); ASSERT(res = TCP.Ok);
	NEW(parked); NEW(child); parked.Open(0, IP.StrToAdr("127.0.0.1"), listener.lport, res); escaped := TRUE
FINALLY listener.Close; cleaned := TRUE
END TrapConnect;

PROCEDURE CheckCancellation*(context: Commands.Context);
VAR res: SIGNED32; msg: Modules.Name; dial, accepted: TCP.Connection; buf: ARRAY 1 OF CHAR; n: SIZE;
BEGIN
	Commands.Activate("DarwinTCPActivityProbe.TrapReceive", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & cleaned & ~escaped);
	ASSERT(parked.State() = TCP.Closed); n := 1;
	ASSERT(Sockets.Recv(peerfd, buf, 0, n, 0) & (n = 0)); Sockets.Close(peerfd);
	parked.Close; context.out.String("PASS cancellation releases the TCP reader and closes the connection"); context.out.Ln;
	cleaned := FALSE;
	Commands.Activate("DarwinTCPActivityProbe.TrapSend", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & cleaned & ~escaped & (parked.State() = TCP.Closed));
	Sockets.Close(peerfd); parked.Close;
	context.out.String("PASS cancellation unwinds a parked TCP sender"); context.out.Ln;
	cleaned := FALSE;
	Commands.Activate("DarwinTCPActivityProbe.TrapAccept", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & cleaned & ~escaped & (parked.State() = TCP.Listen));
	NEW(dial); dial.Open(0, IP.StrToAdr("127.0.0.1"), parked.lport, res); ASSERT(res = TCP.Ok);
	parked.Accept(accepted, res); ASSERT(res = TCP.Ok);
	accepted.Close; dial.Close; parked.Close;
	cleaned := FALSE;
	Commands.Activate("DarwinTCPActivityProbe.TrapConnect", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & cleaned & ~escaped & (parked.State() = TCP.Unused));
	context.out.String("PASS setup cancellation: listener reusable and interrupted connect unwound"); context.out.Ln
END CheckCancellation;

TYPE
	BulkSender = OBJECT(A.Activity)
	VAR c: TCP.Connection; payload: POINTER TO ARRAY OF CHAR; res: INTEGER; finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN c.Send(payload^, 1, LEN(payload^) - 1, TRUE, res); finished := TRUE END Run;
	END BulkSender;

	PeerDrain = OBJECT(A.Activity)
	VAR peer: SIGNED32; total: SIZE; buf: ARRAY 8192 OF CHAR;
		PROCEDURE Run*;
		VAR n, i: SIZE;
		BEGIN
			WHILE total <= PayloadSize DO
				n := LEN(buf); ASSERT(Sockets.Recv(peer, buf, 0, n, 0) & (n > 0));
				FOR i := 0 TO n-1 DO
					IF total = PayloadSize THEN ASSERT(buf[i] = "!")
					ELSE ASSERT(buf[i] = CHR(total MOD 251)) END;
					INC(total)
				END
			END
		END Run;
	END PeerDrain;

PROCEDURE CheckSend(context: Commands.Context);
VAR c: TCP.Connection; peer, mode: SIGNED32; s: A.Scheduler; big, last: BulkSender;
	drain: PeerDrain; reader: Reader; i: SIZE; payload: POINTER TO ARRAY OF CHAR;
BEGIN
	NEW(payload, PayloadSize + 1);
	FOR i := 0 TO PayloadSize-1 DO payload[i+1] := CHR(i MOD 251) END;
	FOR mode := 0 TO 1 DO
		Loopback(c, peer); NEW(s); NEW(big); big.c := c; big.payload := payload;
		s.Start(big); ASSERT(s.Dispatch() & ~big.finished);
		IF mode = 0 THEN
			NEW(last); last.c := c; NEW(last.payload, 2); last.payload[1] := "!";
			s.Start(last); ASSERT(s.Dispatch() & ~last.finished);
			NEW(drain); drain.peer := peer; s.Start(drain); s.Drain;
			ASSERT(big.finished & (big.res = TCP.Ok) & last.finished & (last.res = TCP.Ok));
			ASSERT(drain.total = PayloadSize + 1)
		ELSE
			NEW(reader); reader.c := c; s.Start(reader); ASSERT(s.Dispatch() & ~reader.finished);
			c.Discard; s.Drain;
			ASSERT(big.finished & (big.res = TCP.ConnectionReset));
			ASSERT(reader.finished & (reader.res = TCP.NotConnected) & (c.State() = TCP.Closed))
		END;
		s.Close; c.Close; Sockets.Close(peer)
	END;
	context.out.String("PASS TCP.Send: parked writer, ordered 16 MiB transfer and full-duplex discard"); context.out.Ln
END CheckSend;

TYPE
	Acceptor = OBJECT(A.Activity)
	VAR listener, client: TCP.Connection; res: INTEGER; finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN listener.Accept(client, res); finished := TRUE END Run;
	END Acceptor;

	Dialer = OBJECT(A.Activity)
	VAR client: TCP.Connection; ip: IP.Adr; port: UNSIGNED32; res: INTEGER; finished: BOOLEAN;
		PROCEDURE Run*;
		BEGIN client.Open(0, ip, port, res); finished := TRUE END Run;
	END Dialer;

PROCEDURE CheckSetup(context: Commands.Context; bindIP, loopIP: IP.Adr; af: INTEGER);
VAR listener: TCP.Connection; s: A.Scheduler; accept, queued: Acceptor; dial: Dialer;
	res, reserved: INTEGER; n: SIZE; buf: ARRAY 1 OF CHAR; adr: Sockets.SocketAdr;
BEGIN
	NEW(listener); listener.Open(0, bindIP, 0, res); ASSERT(res = TCP.Ok);
	NEW(s); NEW(accept); accept.listener := listener; s.Start(accept);
	ASSERT(s.Dispatch() & ~accept.finished);
	NEW(dial); NEW(dial.client); dial.ip := loopIP; dial.port := listener.lport; s.Start(dial); s.Drain;
	ASSERT(dial.finished & (dial.res = TCP.Ok) & accept.finished & (accept.res = TCP.Ok));
	ASSERT((accept.client.fport = dial.client.lport) & (accept.client.lport = listener.lport));
	buf[0] := "K"; dial.client.Send(buf, 0, 1, TRUE, res); ASSERT(res = TCP.Ok);
	buf[0] := 0X; accept.client.Receive(buf, 0, 1, 1, n, res); ASSERT((res = TCP.Ok) & (buf[0] = "K"));
	dial.client.Close; accept.client.Close;
	NEW(dial); NEW(dial.client); dial.ip := loopIP; dial.port := listener.lport;
	s.Start(dial); ASSERT(s.Dispatch() & ~dial.finished); Kernel.GC; dial.client.Close; s.Drain;
	ASSERT(dial.finished & (dial.res = TCP.NotConnected) & (dial.client.State() = TCP.Closed));
	(* The kernel may already have queued the cancelled handshake. Use a fresh listener. *)
	listener.Close; NEW(listener); listener.Open(0, bindIP, 0, res); ASSERT(res = TCP.Ok);
	NEW(accept); accept.listener := listener; s.Start(accept); ASSERT(s.Dispatch() & ~accept.finished);
	NEW(queued); queued.listener := listener; s.Start(queued); ASSERT(s.Dispatch() & ~queued.finished);
	Kernel.GC; listener.Close; s.Drain;
	ASSERT(accept.finished & (accept.res = TCP.NotConnected) & (accept.client = NIL));
	ASSERT(queued.finished & (queued.res = TCP.NotConnected) & (queued.client = NIL));
	IF af = Unix.AFINET THEN
		reserved := Sockets.Socket(af, Unix.SockStream, Unix.IpProtoTCP); ASSERT(reserved >= 0);
		ASSERT(Sockets.Bind(reserved, Sockets.NewSocketAdr(loopIP, 0)));
		adr := Sockets.GetSockName(reserved); ASSERT(adr # NIL);
		NEW(dial); NEW(dial.client); dial.ip := loopIP; dial.port := Sockets.GetPortNumber(adr);
		s.Start(dial); s.Drain; ASSERT(dial.finished & (dial.res = TCP.ConnectionRefused));
		Sockets.Close(reserved)
	END;
	s.Close;
	context.out.String("PASS TCP setup IPv"); context.out.Int(loopIP.usedProtocol, 0); context.out.String(": single-worker loopback, Close interrupts queued accepts and a pending connect"); context.out.Ln
END CheckSetup;

CONST Clients = 24;
TYPE
	Batch = OBJECT
	VAR worker: Unix.Thread_t; done, accepted: SIZE;
		PROCEDURE Arrived;
		BEGIN {EXCLUSIVE} INC(accepted) END Arrived;
		PROCEDURE WaitAccepted(n: SIZE);
		BEGIN {EXCLUSIVE} AWAIT(accepted >= n) END WaitAccepted;
		PROCEDURE Finish;
		BEGIN {EXCLUSIVE} ASSERT(Unix.ThrThis() = worker); INC(done) END Finish;
		PROCEDURE Join;
		BEGIN {EXCLUSIVE} AWAIT(done = 2 * Clients + 1) END Join;
	END Batch;

	Echo = OBJECT
	VAR c: TCP.Connection; batch: Batch;
		PROCEDURE &Init(c: TCP.Connection; batch: Batch);
		BEGIN SELF.c := c; SELF.batch := batch END Init;
	VAR data: ARRAY 1 OF CHAR; n: SIZE; res: INTEGER;
	BEGIN {ACTIVE}
		c.Receive(data, 0, 1, 1, n, res); ASSERT((res = TCP.Ok) & (n = 1));
		c.Send(data, 0, 1, TRUE, res); ASSERT(res = TCP.Ok);
		c.Close; batch.Finish
	END Echo;

	Server = OBJECT
	VAR listener: TCP.Connection; batch: Batch;
		PROCEDURE &Init(listener: TCP.Connection; batch: Batch);
		BEGIN SELF.listener := listener; SELF.batch := batch END Init;
	VAR client: TCP.Connection; echo: Echo; i, res: INTEGER;
	BEGIN {ACTIVE}
		FOR i := 1 TO Clients DO
			listener.Accept(client, res); ASSERT(res = TCP.Ok);
			NEW(echo, client, batch); batch.Arrived
		END;
		listener.Close; batch.Finish
	END Server;

	Client = OBJECT
	VAR port: UNSIGNED32; tag: CHAR; batch: Batch;
		PROCEDURE &Init(port: UNSIGNED32; tag: CHAR; batch: Batch);
		BEGIN SELF.port := port; SELF.tag := tag; SELF.batch := batch END Init;
	VAR c: TCP.Connection; data: ARRAY 1 OF CHAR; n: SIZE; res: INTEGER;
	BEGIN {ACTIVE}
		NEW(c); c.Open(0, IP.StrToAdr("127.0.0.1"), port, res); ASSERT(res = TCP.Ok);
		batch.WaitAccepted(Clients); data[0] := tag; c.Send(data, 0, 1, TRUE, res); ASSERT(res = TCP.Ok);
		data[0] := 0X; c.Receive(data, 0, 1, 1, n, res);
		ASSERT((res = TCP.Ok) & (n = 1) & (data[0] = tag));
		c.Close; batch.Finish
	END Client;

PROCEDURE FanIn*(context: Commands.Context);
VAR listener: TCP.Connection; batch: Batch; server: Server; client: Client; i, res: INTEGER;
BEGIN
	NEW(batch); batch.worker := Unix.ThrThis();
	NEW(listener); listener.Open(0, IP.Nil4Adr, 0, res); ASSERT(res = TCP.Ok);
	NEW(server, listener, batch);
	(* Keep every session live while admitting connections within the listen backlog. *)
	FOR i := 1 TO Clients DO
		NEW(client, listener.lport, CHR(i), batch); batch.WaitAccepted(i)
	END;
	batch.Join;
	context.out.String("PASS 24 TCP clients, 24 echo handlers and a listener on one pthread"); context.out.Ln
END FanIn;

PROCEDURE CheckAvailable(context: Commands.Context);
VAR c: TCP.Connection; peer, res: INTEGER; n: SIZE; data: ARRAY 4 OF CHAR;
BEGIN
	Loopback(c, peer); ASSERT(c.Available() = 0);
	data := "abc"; n := LEN(data); ASSERT(Sockets.Send(peer, data, 0, n) & (n = LEN(data)));
	(* Receive one byte, so the remaining three are known to be on this endpoint. *)
	c.Receive(data, 0, 1, 1, n, res); ASSERT((res = TCP.Ok) & (n = 1));
	ASSERT(c.Available() = 3);
	c.Receive(data, 0, 3, 3, n, res); ASSERT((res = TCP.Ok) & (n = 3) & (c.Available() = 0));
	c.Close; Sockets.Close(peer);
	context.out.String("PASS TCP.Available reports unread bytes after a partial read"); context.out.Ln
END CheckAvailable;

PROCEDURE Run*(context: Commands.Context);
VAR c: TCP.Connection; peer, mode, res: SIGNED32; s: A.Scheduler; r: Reader; w: Writer; native: DelayedPeer;
	n: SIZE; buf: ARRAY 1 OF CHAR;
BEGIN
	CheckAvailable(context);
	CheckSetup(context, IP.Nil4Adr, IP.StrToAdr("127.0.0.1"), Unix.AFINET);
	CheckSetup(context, IP.Nil6Adr, IP.StrToAdr("::1"), Unix.AFINET6); CheckSend(context);
	FOR mode := 0 TO 2 DO
		Loopback(c, peer); SendByte(peer, "A");
		NEW(s); NEW(r); r.c := c; NEW(w); w.peer := peer; w.mode := mode; w.c := c;
		s.Start(r);
		(* The first byte may still be in transit. Discard only after the reader
		   has consumed it and parked waiting for the second byte. *)
		REPEAT
			IF ~s.Dispatch() THEN Unix.ThrSleep(1) END;
			ASSERT(~r.finished)
		UNTIL r.data[1] = "A";
		s.Start(w);
		ASSERT(s.Dispatch()); ASSERT(w.ran);
		s.Drain; s.Close; ASSERT(r.finished & (r.data[0] = "-") & (r.data[1] = "A"));
		IF mode = 0 THEN
			ASSERT((r.n = 2) & (r.res = TCP.Ok) & (r.data[2] = "2"));
			NEW(native, peer); c.Receive(buf, 0, 1, 1, n, res);
			ASSERT((n = 1) & (res = TCP.Ok) & (buf[0] = "N"))
		ELSE ASSERT((r.n = 1) & (r.res = TCP.NotConnected) & (c.State() = TCP.Closed)) END;
		c.Close; IF mode # 1 THEN Sockets.Close(peer) END
	END;
	context.out.String("PASS TCP.Receive loopback: split reads, sibling progress, partial EOF, local discard and native read"); context.out.Ln
END Run;
END DarwinTCPActivityProbe.
