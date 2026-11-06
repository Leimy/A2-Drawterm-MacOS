MODULE DarwinNetworkProbe;

(* Native AArch64 smoke checks for byte order and the Unix socket-backed stack. *)
IMPORT SYSTEM, Network, IP, DNS, TCP, UDP, Sockets, Unix, KernelLog;

PROCEDURE Endian(): BOOLEAN;
VAR buf: ARRAY 4 OF CHAR; value: UNSIGNED32;
BEGIN
	value := 0A1B2C3D4H;
	Network.Put4(buf, 0, value);
	IF (ORD(buf[0]) # 0D4H) OR (ORD(buf[1]) # 0C3H) OR
		(ORD(buf[2]) # 0B2H) OR (ORD(buf[3]) # 0A1H) OR
		(Network.Get4(buf, 0) # SYSTEM.VAL(SIGNED32, value)) THEN RETURN FALSE END;
	Network.PutNet4(buf, 0, SYSTEM.VAL(SIGNED32, value));
	IF (ORD(buf[0]) # 0A1H) OR (ORD(buf[1]) # 0B2H) OR
		(ORD(buf[2]) # 0C3H) OR (ORD(buf[3]) # 0D4H) OR
		(Network.GetNet4(buf, 0) # SYSTEM.VAL(SIGNED32, value)) THEN RETURN FALSE END;
	Network.Put2(buf, 0, 0BEEFH);
	IF (ORD(buf[0]) # 0EFH) OR (ORD(buf[1]) # 0BEH) OR
		(Network.Get2(buf, 0) # 0BEEFH) THEN RETURN FALSE END;
	Network.PutNet2(buf, 0, 0BEEFH);
	RETURN (ORD(buf[0]) = 0BEH) & (ORD(buf[1]) = 0EFH) &
		(Network.GetNet2(buf, 0) = 0BEEFH)
END Endian;

PROCEDURE LocalhostDNS(): BOOLEAN;
VAR address: IP.Adr; result: INTEGER;
BEGIN
	DNS.HostByName("localhost", address, result);
	RETURN (result = DNS.Ok) & (address.usedProtocol = IP.IPv4) & ~IP.IsNilAdr(address)
END LocalhostDNS;

PROCEDURE LoopbackTCP(): BOOLEAN;
VAR server, peer: INTEGER; address: Sockets.SocketAdr; ip: IP.Adr;
	port, result: SIGNED32; connection: TCP.Connection;
	data: ARRAY 4 OF CHAR; sent, received: SIZE; ok: BOOLEAN;
BEGIN
	server := Sockets.Socket(Unix.AFINET, Unix.SockStream, Unix.IpProtoTCP);
	IF server < 0 THEN RETURN FALSE END;
	ip := IP.StrToAdr("127.0.0.1");
	address := Sockets.NewSocketAdr(ip, 0);
	IF ~Sockets.Bind(server, address) THEN Sockets.Close(server); RETURN FALSE END;
	IF ~Sockets.Listen(server) THEN Sockets.Close(server); RETURN FALSE END;
	address := Sockets.GetSockName(server);
	IF address = NIL THEN Sockets.Close(server); RETURN FALSE END;
	port := Sockets.GetPortNumber(address);
	NEW(connection);
	connection.Open(TCP.NilPort, ip, UNSIGNED32(port), result);
	IF result # TCP.Ok THEN Sockets.Close(server); RETURN FALSE END;
	peer := Sockets.Accept(server);
	IF peer < 0 THEN connection.Close; Sockets.Close(server); RETURN FALSE END;
	data := "A2";
	connection.Send(data, 0, 2, TRUE, result);
	IF result # TCP.Ok THEN connection.Close; Sockets.Close(peer); Sockets.Close(server); RETURN FALSE END;
	IF ~Sockets.AwaitPacket(peer, 1000) THEN connection.Close; Sockets.Close(peer); Sockets.Close(server); RETURN FALSE END;
	received := 2; ok := Sockets.Recv(peer, data, 0, received, 0);
	IF ok & (received = 2) & (data[0] = 'A') & (data[1] = '2') THEN
		data := "OK"; sent := 2; ok := Sockets.Send(peer, data, 0, sent);
		IF ok THEN connection.Receive(data, 0, 2, 2, received, result) END;
		ok := ok & (result = TCP.Ok) & (sent = 2) & (received = 2) &
			(data[0] = 'O') & (data[1] = 'K')
	ELSE ok := FALSE END;
	connection.Close; Sockets.Close(peer); Sockets.Close(server);
	RETURN ok
END LoopbackTCP;

PROCEDURE LoopbackUDP(): BOOLEAN;
VAR receiver, result: INTEGER; sender: UDP.Socket;
	address, from: Sockets.SocketAdr; ip: IP.Adr;
	port: SIGNED32; data: ARRAY 4 OF CHAR; received: SIZE; ok: BOOLEAN;
BEGIN
	receiver := Sockets.Socket(Unix.AFINET, Unix.SockDGram, Unix.IpProtoUDP);
	IF receiver < 0 THEN RETURN FALSE END;
	ip := IP.StrToAdr("127.0.0.1");
	address := Sockets.NewSocketAdr(ip, 0);
	IF ~Sockets.Bind(receiver, address) THEN Sockets.Close(receiver); RETURN FALSE END;
	address := Sockets.GetSockName(receiver);
	IF address = NIL THEN Sockets.Close(receiver); RETURN FALSE END;
	port := Sockets.GetPortNumber(address);
	NEW(sender, UDP.NilPort, result);
	IF result # UDP.Ok THEN Sockets.Close(receiver); RETURN FALSE END;
	received := 0;
	data := "UDP"; sender.Send(ip, UNSIGNED32(port), data, 0, 3, result);
	ok := result = UDP.Ok;
	IF ok THEN ok := Sockets.AwaitPacket(receiver, 1000) END;
	IF ok THEN received := 3; ok := Sockets.RecvFrom(receiver, from, data, 0, received) END;
	ok := ok & (received = 3) & (data[0] = 'U') & (data[1] = 'D') & (data[2] = 'P');
	sender.Close; Sockets.Close(receiver);
	RETURN ok
END LoopbackUDP;

PROCEDURE Run*;
BEGIN
	IF ~Endian() THEN KernelLog.String("NETWORK FAIL endian"); KernelLog.Ln; RETURN END;
	KernelLog.String("NETWORK PASS endian"); KernelLog.Ln;
	IF ~LocalhostDNS() THEN KernelLog.String("NETWORK FAIL localhost DNS"); KernelLog.Ln; RETURN END;
	KernelLog.String("NETWORK PASS localhost DNS"); KernelLog.Ln;
	IF ~LoopbackTCP() THEN KernelLog.String("NETWORK FAIL TCP loopback"); KernelLog.Ln; RETURN END;
	KernelLog.String("NETWORK PASS TCP loopback"); KernelLog.Ln;
	IF ~LoopbackUDP() THEN KernelLog.String("NETWORK FAIL UDP loopback"); KernelLog.Ln; RETURN END;
	KernelLog.String("NETWORK PASS UDP loopback"); KernelLog.Ln
END Run;

END DarwinNetworkProbe.
