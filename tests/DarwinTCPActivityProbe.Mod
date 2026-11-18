MODULE DarwinTCPActivityProbe;
IMPORT A := DarwinActivities, Commands, TCP, IP, Sockets, Unix, Modules;

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

PROCEDURE CheckCancellation*(context: Commands.Context);
VAR res: SIGNED32; msg: Modules.Name; buf: ARRAY 1 OF CHAR; n: SIZE;
BEGIN
	Commands.Activate("DarwinTCPActivityProbe.TrapReceive", NIL, {Commands.Wait}, res, msg);
	ASSERT((res = Commands.CommandTrapped) & cleaned & ~escaped);
	ASSERT(parked.State() = TCP.Closed); n := 1;
	ASSERT(Sockets.Recv(peerfd, buf, 0, n, 0) & (n = 0)); Sockets.Close(peerfd);
	parked.Close; context.out.String("PASS cancellation releases the TCP reader and closes the connection"); context.out.Ln
END CheckCancellation;

PROCEDURE Run*(context: Commands.Context);
VAR c: TCP.Connection; peer, mode, res: SIGNED32; s: A.Scheduler; r: Reader; w: Writer;
	n: SIZE; buf: ARRAY 1 OF CHAR;
BEGIN
	FOR mode := 0 TO 2 DO
		Loopback(c, peer); SendByte(peer, "A");
		NEW(s); NEW(r); r.c := c; NEW(w); w.peer := peer; w.mode := mode; w.c := c;
		s.Start(r); s.Start(w);
		ASSERT(s.Dispatch()); ASSERT(~r.finished & ~w.ran);
		ASSERT(s.Dispatch()); ASSERT(w.ran);
		s.Drain; s.Close; ASSERT(r.finished & (r.data[0] = "-") & (r.data[1] = "A"));
		IF mode = 0 THEN
			ASSERT((r.n = 2) & (r.res = TCP.Ok) & (r.data[2] = "2"));
			SendByte(peer, "N"); c.Receive(buf, 0, 1, 1, n, res);
			ASSERT((n = 1) & (res = TCP.Ok) & (buf[0] = "N"))
		ELSE ASSERT((r.n = 1) & (r.res = TCP.NotConnected) & (c.State() = TCP.Closed)) END;
		c.Close; IF mode # 1 THEN Sockets.Close(peer) END
	END;
	context.out.String("PASS TCP.Receive loopback: split reads, sibling progress, partial EOF, local discard and native read"); context.out.Ln
END Run;
END DarwinTCPActivityProbe.
