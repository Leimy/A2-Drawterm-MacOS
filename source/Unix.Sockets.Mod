MODULE Sockets;	(** AUTHOR "G.F.";  PURPOSE "Interface to Unix sockets" *)

(* derived from NetBase.Mod,  BD / 13.2.96 *)

(*	1998.04.27	g.f.	Linux PPC version	*)
(*	1099.05.17	g.f.	adapted to Threads	*)
(*	1999.11.22	g.f.	Solaris x86 version	*)
(*	2000.02.18	g.f.	adapted to Solaris 8	*)
(*	2001.01.06	g.f.	[c] - flag for new compiler	*)
(*	2007.07.06	g.f.	IP address format converted to IP.Adr *)
(*  	2020.04.06  PDR     perror on socket failure*)

IMPORT S := SYSTEM, Unix, Trace, IP, Objects
	#IF LIGHTWEIGHT THEN
	, Glue
	#END
	;

CONST

	(*listen *)
	Backlog = 5;		(* max number of pending connections *)

TYPE
	SocketAdr* = POINTER TO RECORD
		family*		: SIGNED16;
		port*		: UNSIGNED16;	(* in network byte order! *)
	END;

	SocketAdrV4* = POINTER TO RECORD (SocketAdr)
		v4Adr*		: UNSIGNED32;
		zero*		: ARRAY 8 OF CHAR
	END;

	SocketAdrV6* = POINTER TO RECORD (SocketAdr)
		flowinfo*	: SIGNED32;
		v6Adr*		: ARRAY 16 OF CHAR;
		scopeId*	: SIGNED32;
		srcId*		: SIGNED32
	END;

	NameBuf = POINTER TO RECORD
		buf: ARRAY 64 OF CHAR
	END;

	SocketOption = RECORD END;
	Length = INTEGER;

	Linger = RECORD (SocketOption)
		onoff	: SIGNED32;
		linger	: SIGNED32;
	END;

	Switch = RECORD (SocketOption)
		onoff	: SIGNED32
	END;

VAR
	socket		: PROCEDURE {C} ( af, typ, protocol: INTEGER ): INTEGER;
	setsockopt	: PROCEDURE {C} ( s: INTEGER; level, optname: INTEGER; VAR opt: SocketOption; optlen: Length): INTEGER;
	accept		: PROCEDURE {C} ( s: INTEGER; adrPtr: ADDRESS; VAR adrlen: Length ): INTEGER;
	bind		: PROCEDURE {C} ( s: INTEGER; adr: ADDRESS; adrlen: Length ): INTEGER;
	connect		: PROCEDURE {C} ( s: INTEGER; adr: ADDRESS; adrlen: Length ): INTEGER;
	listen		: PROCEDURE {C} ( s: INTEGER; backlog: INTEGER ): INTEGER;
	recv		: PROCEDURE {C} ( s: INTEGER; buf: ADDRESS; len: SIZE; flags: INTEGER ): SIZE;
	send		: PROCEDURE {C} ( s: INTEGER; buf: ADDRESS; len: SIZE; flags: INTEGER ): SIZE;
	recvfrom	: PROCEDURE {C} ( s: INTEGER; buf: ADDRESS; len: SIZE; flags: INTEGER; from: NameBuf; VAR flen: Length ): SIZE;
	sendto		: PROCEDURE {C} ( s: INTEGER; buf: ADDRESS; len: SIZE; flags: INTEGER; to: ADDRESS; tolen: Length ): SIZE;
	shutdown	: PROCEDURE {C} ( s: INTEGER; how: INTEGER ): INTEGER;

	getpeername	: PROCEDURE {C} ( s: INTEGER; adr: NameBuf; VAR adrlen: Length ): INTEGER;
	getsockname	: PROCEDURE {C} ( s: INTEGER; adr: NameBuf; VAR adrlen: Length ): INTEGER;

	htonl	: PROCEDURE {C} ( hostlong	: UNSIGNED32 ): UNSIGNED32;
	htons	: PROCEDURE {C} ( hostshort	: UNSIGNED16 ): UNSIGNED16;
	ntohl	: PROCEDURE {C} ( netlong	: UNSIGNED32 ): UNSIGNED32;
	ntohs	: PROCEDURE {C} ( netshort	: UNSIGNED16 ): UNSIGNED16;

	PROCEDURE NewSocketAdr*( ip: IP.Adr; port: UNSIGNED32 ): SocketAdr;
	VAR sadr4: SocketAdrV4;  sadr6: SocketAdrV6; i: SIZE;
	BEGIN
		CASE ip.usedProtocol OF
		| -1:
			NEW( sadr4 );
				sadr4.family := Unix.AFINET;
				sadr4.port := IntToNet( SHORT( port ) );
				sadr4.v4Adr := 0;
			RETURN sadr4
		| IP.IPv4:
			NEW( sadr4 );
				sadr4.family := Unix.AFINET;
				sadr4.port := IntToNet( SHORT( port ) );
				sadr4.v4Adr := ip.ipv4Adr;
			RETURN sadr4
		| IP.IPv6:
			NEW( sadr6 );
				sadr6.family := Unix.AFINET6;
				sadr6.port := IntToNet( SHORT( port ) );
				sadr6.flowinfo := 0;
				FOR i := 0 TO 15 DO  sadr6.v6Adr[i] := ip.ipv6Adr[i]  END;
				sadr6.scopeId := 0;
				sadr6.srcId := 0;
			RETURN sadr6
		ELSE
			HALT( 99 )
		END
	END NewSocketAdr;

	PROCEDURE SockAdrToIPAdr*( sadr: SocketAdr ): IP.Adr;
	VAR ip: IP.Adr;  i: SIZE;
	BEGIN
		IF sadr IS SocketAdrV4 THEN
			ip.usedProtocol := IP.IPv4;
			ip.ipv4Adr := sadr(SocketAdrV4).v4Adr;
			ip.ipv6Adr := ""
		ELSE
			ip.usedProtocol := IP.IPv6;
			ip.ipv4Adr := 0;
			FOR i := 0 TO 15 DO
				ip.ipv6Adr[i] := sadr(SocketAdrV6).v6Adr[i]
			END
		END;
		RETURN ip
	END SockAdrToIPAdr;

	PROCEDURE GetPortNumber*( sadr: SocketAdr ): SIGNED32;
	VAR port: SIGNED32;
	BEGIN
		port := NetToInt( sadr.port );
		IF port < 0 THEN port := port + 10000H END;
		RETURN port
	END GetPortNumber;

	(* Keep SocketAdr.family in host form for A2 callers. Darwin's sockaddr
	   starts with two separate bytes, sa_len and sa_family. *)
	PROCEDURE NativeAddress(addr: SocketAdr; VAR bytes: ARRAY OF CHAR): Length;
	VAR size: Length;
	BEGIN
		IF addr IS SocketAdrV4 THEN size := Unix.SockAddrSizeV4 ELSE size := Unix.SockAddrSizeV6 END;
		ASSERT(LEN(bytes) >= size); S.MOVE(ADDRESSOF(addr^), ADDRESSOF(bytes[0]), size);
		IF Unix.Version = "Darwin" THEN bytes[0] := CHR(size); bytes[1] := CHR(addr.family) END;
		RETURN size
	END NativeAddress;

	PROCEDURE BufToSocketAdr( CONST buf: ARRAY OF CHAR; len: INTEGER ): SocketAdr;
	VAR adr4: SocketAdrV4; adr6: SocketAdrV6;
	BEGIN
		IF len = Unix.SockAddrSizeV4 THEN
			NEW( adr4 );
			S.MOVE( ADDRESSOF( buf ), ADDRESSOF( adr4^), len );
			IF Unix.Version = "Darwin" THEN adr4.family := ORD(buf[1]) END;
			RETURN adr4
		ELSE
			NEW( adr6 );
			S.MOVE( ADDRESSOF( buf ), ADDRESSOF( adr6^), len );
			IF Unix.Version = "Darwin" THEN adr6.family := ORD(buf[1]) END;
			RETURN adr6
		END
	END BufToSocketAdr;

	PROCEDURE Accept*( s: INTEGER ): INTEGER;
	VAR len: Length; err, new: INTEGER;
	BEGIN
		len := 0;
		REPEAT
			new := accept( s, 0, len );
			IF new < 0 THEN  err := Unix.errno()  END
		UNTIL (new > 0) OR (err # Unix.EINTR);
		IF new < 0 THEN  Unix.Perror( "Sockets.Accept" )  END;
		RETURN new
	END Accept;

	PROCEDURE Bind*( s: INTEGER; addr: SocketAdr): BOOLEAN;
	VAR err: INTEGER; len: Length; native: ARRAY 64 OF CHAR;
	BEGIN
		len := NativeAddress(addr, native);
		err:= bind(s, ADDRESSOF(native[0]), len);
		RETURN err = 0
	END Bind;

	#IF LIGHTWEIGHT THEN
	VAR setupQueue: PROCEDURE {C}(fd, writing: INTEGER): INTEGER;
		cancelSetup: PROCEDURE {C}(queue: INTEGER): INTEGER;
		getsockopt: PROCEDURE {C}(fd, level, option: INTEGER; VAR value: INTEGER; VAR size: Length): INTEGER;
		setNonblocking: PROCEDURE {C}(fd: INTEGER): INTEGER;
		pollSocket: PROCEDURE {C}(fd, writing: INTEGER): INTEGER;

	PROCEDURE PrepareStream*(fd: INTEGER): BOOLEAN;
	BEGIN RETURN setNonblocking(fd) # 0 END PrepareStream;

	PROCEDURE WaitSocket*(fd: INTEGER; writing: BOOLEAN): BOOLEAN;
	VAR p: Objects.Process; direction: INTEGER;
	BEGIN
		p := Objects.CurrentProcess();
		IF (p # NIL) & (p.awaitSocket # NIL) THEN RETURN p.awaitSocket(fd, writing) END;
		IF writing THEN direction := 1 ELSE direction := 0 END;
		RETURN pollSocket(fd, direction) # 0
	END WaitSocket;

	PROCEDURE SetupQueue*(fd: INTEGER; writing: BOOLEAN): INTEGER;
	BEGIN IF writing THEN RETURN setupQueue(fd, 1) ELSE RETURN setupQueue(fd, 0) END END SetupQueue;

	PROCEDURE CancelSetup*(queue: INTEGER);
	BEGIN ASSERT(cancelSetup(queue) = 0) END CancelSetup;

	PROCEDURE StartConnect*(fd: INTEGER; addr: SocketAdr; VAR pending: BOOLEAN): BOOLEAN;
	VAR size: Length; err: INTEGER; native: ARRAY 64 OF CHAR;
	BEGIN
		size := NativeAddress(addr, native);
		pending := FALSE; IF connect(fd, ADDRESSOF(native[0]), size) = 0 THEN RETURN TRUE END;
		err := Unix.errno(); pending := (err = Unix.EINPROGRESS) OR (err = Unix.EINTR); RETURN FALSE
	END StartConnect;

	PROCEDURE Connected*(fd: INTEGER): BOOLEAN;
	VAR err: INTEGER; size: Length;
	BEGIN
		size := SIZEOF(INTEGER);
		RETURN (getsockopt(fd, Unix.SoLSocket, Unix.SoError, err, size) = 0) & (err = 0)
	END Connected;

	PROCEDURE TryAccept*(fd: INTEGER; VAR pending: BOOLEAN): INTEGER;
	VAR new, err: INTEGER; size: Length;
	BEGIN
		size := 0; pending := FALSE;
		LOOP
			new := accept(fd, 0, size); IF new >= 0 THEN RETURN new END;
			err := Unix.errno(); IF err # Unix.EINTR THEN pending := err = Unix.EAGAIN; RETURN -1 END
		END
	END TryAccept;

	PROCEDURE TransferStream(fd: INTEGER; buf: ADDRESS; VAR len: SIZE; writing: BOOLEAN): BOOLEAN;
	VAR n: SIZE; err: INTEGER;
	BEGIN
		LOOP
			IF writing THEN n := send(fd, buf, len, Unix.MsgNoSignal)
			ELSE n := recv(fd, buf, len, 0) END;
			IF n >= 0 THEN len := n; RETURN TRUE END;
			err := Unix.errno();
			IF err = Unix.EAGAIN THEN
				IF ~WaitSocket(fd, writing) THEN EXIT END
			ELSIF err # Unix.EINTR THEN EXIT END
		END;
		len := 0; RETURN FALSE
	END TransferStream;

	PROCEDURE SendStream*(fd: INTEGER; CONST buf: ARRAY OF CHAR; pos: SIZE; VAR len: SIZE): BOOLEAN;
	BEGIN
		ASSERT((pos >= 0) & (len > 0) & (pos <= LEN(buf)-len));
		RETURN TransferStream(fd, ADDRESSOF(buf[pos]), len, TRUE)
	END SendStream;

	PROCEDURE RecvStream*(fd: INTEGER; VAR buf: ARRAY OF CHAR; pos: SIZE; VAR len: SIZE): BOOLEAN;
	BEGIN
		ASSERT((pos >= 0) & (len > 0) & (pos <= LEN(buf)-len));
		RETURN TransferStream(fd, ADDRESSOF(buf[pos]), len, FALSE)
	END RecvStream;

	PROCEDURE ShutdownReadWrite*(s: INTEGER);
	BEGIN IGNORE shutdown(s, Unix.ShutRDWR) END ShutdownReadWrite;
	#END

	PROCEDURE Close*( s: INTEGER );
	BEGIN
		IGNORE shutdown( s, Unix.ShutRDWR );
		IGNORE Unix.close( s );
	END Close;

	PROCEDURE Connect*( s: INTEGER; addr: SocketAdr ): BOOLEAN;
	VAR err: INTEGER; len: Length; native: ARRAY 64 OF CHAR;
	BEGIN
		len := NativeAddress(addr, native);
		err:= connect(s, ADDRESSOF(native[0]), len);
		IF err = 0 THEN
			RETURN TRUE
		ELSE
			Unix.Perror( "Sockets.Connect: " );
			RETURN FALSE
		END;
		RETURN err = 0
	END Connect;

	PROCEDURE GetSockName*( s: INTEGER ): SocketAdr;
	VAR len: Length; err: INTEGER; buf: NameBuf;
	BEGIN
		NEW( buf );  len := 64;
		err := getsockname( s, buf, len );
		IF err = 0 THEN
			RETURN BufToSocketAdr( buf.buf, len )
		ELSE
			Unix.Perror( "Sockets.GetSockName" );
			RETURN NIL
		END
	END GetSockName;

	PROCEDURE GetPeerName*( s: INTEGER ): SocketAdr;
	VAR err: INTEGER; len: Length; buf: NameBuf;
	BEGIN
		NEW( buf );  len := 64;
		err:= getpeername( s, buf, len );
		IF err = 0 THEN
			RETURN BufToSocketAdr( buf.buf, len )
		ELSE
			Unix.Perror( "Sockets.GetPeerName" );
			RETURN NIL
		END
	END GetPeerName;

	PROCEDURE Listen*( s: INTEGER ): BOOLEAN;
	VAR err: INTEGER;
	BEGIN
		err := listen( s, Backlog );
		RETURN err = 0
	END Listen;

	PROCEDURE Recv*( s: INTEGER; VAR buf: ARRAY OF CHAR; pos: SIZE; VAR len: SIZE; flags: INTEGER ): BOOLEAN;
	VAR res: SIZE; err: INTEGER;
	#IF LIGHTWEIGHT THEN
	VAR p: Objects.Process;
	#END
	BEGIN
		#IF LIGHTWEIGHT THEN
		p := Objects.CurrentProcess();
		IF (p # NIL) & (p.awaitSocket # NIL) & (flags = 0) THEN
			LOOP
				res := recv(s, ADDRESSOF(buf[pos]), len, Unix.MsgDontWait);
				IF res >= 0 THEN len := res; RETURN TRUE END;
				err := Unix.errno();
				IF err = Unix.EAGAIN THEN
					IF ~p.awaitSocket(s, FALSE) THEN EXIT END
				ELSIF err # Unix.EINTR THEN EXIT END
			END;
			len := 0; RETURN FALSE
		END;
		#END
		REPEAT
			res := recv(s, ADDRESSOF(buf[pos]), len, flags);
			IF res < 0 THEN err := Unix.errno() END
		UNTIL (res >= 0) OR (err # Unix.EINTR);
		IF res >= 0 THEN len := res; RETURN TRUE END;
		Unix.Perror("Sockets.Recv"); len := 0; RETURN FALSE
	END Recv;

	PROCEDURE Send*( s: INTEGER; CONST buf: ARRAY OF CHAR; pos: SIZE; VAR len: SIZE ): BOOLEAN;
	VAR err: SIZE;
	BEGIN
		ASSERT( LEN(buf)-pos >= len );
		err := send( s, ADDRESSOF( buf[pos] ), len, 0 );
		IF err >= 0 THEN
			len := err;  RETURN TRUE
		ELSE
			Unix.Perror( "Sockets.Send" );
			len := 0;  RETURN FALSE
		END
	END Send;

	PROCEDURE RecvFrom*( s: INTEGER; VAR from: SocketAdr;
						VAR buf: ARRAY OF CHAR; pos: SIZE;  VAR len: SIZE ): BOOLEAN;
	VAR res: SIZE; err, size: INTEGER; nbuf: NameBuf;
	BEGIN
		NEW( nbuf ); size := 64;
		REPEAT
			res := recvfrom( s, ADDRESSOF(buf[pos]), LEN( buf ) - pos, 0, nbuf, size );
			IF res < 0 THEN  err := Unix.errno()  END
		UNTIL (res >= 0) OR (err # Unix.EINTR);
		IF res >= 0 THEN
			from := BufToSocketAdr( nbuf.buf, size );
			len := res;  RETURN TRUE
		ELSE
			Unix.Perror( "Sockets.RecvFrom" );
			len := 0;  RETURN FALSE
		END
	END RecvFrom;

	PROCEDURE SendTo*( s: INTEGER;  dest: SocketAdr;  CONST buf: ARRAY OF CHAR;  pos, len: SIZE ): BOOLEAN;
	VAR err: SIZE; size: Length; native: ARRAY 64 OF CHAR;
	BEGIN
		ASSERT( LEN(buf) - pos >= len );
		size := NativeAddress(dest, native);
		err:= sendto( s, ADDRESSOF( buf[pos] ), len, 0, ADDRESSOF(native[0]), size );
		IF err >= 0 THEN
			RETURN TRUE
		ELSE
			Unix.Perror( "Sockets.SendTo" );
			RETURN FALSE
		END
	END SendTo;

	PROCEDURE Socket* ( af, typ, protocol: INTEGER ): INTEGER;
	VAR s: INTEGER;
	BEGIN
		s := socket( af, typ, protocol );
	        IF s = -1 THEN
        	    Unix.Perror( "Sockets.Socket" )
	        END; 
		RETURN s
	END Socket;

	PROCEDURE Available*( s: INTEGER ): SIGNED32;
	VAR available, err: INTEGER;
	BEGIN
		available := 0;
		err := Unix.ioctl( s, Unix.FioNRead, ADDRESSOF( available ) );
		IF err = 0 THEN
			RETURN available
		ELSE
			Unix.Perror( "Sockets.Available (ioctl)" );
			RETURN -1
		END
	END Available;

	PROCEDURE Requested*( s: INTEGER ): BOOLEAN;
	CONST
		SLen = Unix.FdSetLen;
		SetBits = SIZEOF( SET32 ) * 8;
	VAR
		res, i: INTEGER;
		readfds: Unix.FdSet;
		timeout: Unix.Timeval;
	BEGIN
		timeout.sec := 0; timeout.usec := 0;
		FOR i := 0 TO SLen - 1  DO readfds[i] := {} END;
		INCL( readfds[s DIV SetBits],  s MOD SetBits );
		res := Unix.select( s+1, ADDRESSOF( readfds ), 0, 0, timeout );
		RETURN res > 0
	END Requested;

	PROCEDURE AwaitPacket*( s: INTEGER; ms: SIGNED32 ): BOOLEAN;
	CONST
		SLen = Unix.FdSetLen;
		SetBits = SIZEOF( SET32 ) * 8;
	VAR
		res, err, i: INTEGER;
		readfds: Unix.FdSet;
		timeout: Unix.Timeval;
	BEGIN
		timeout.sec := ms DIV 1000;  ms := ms MOD 1000;
		timeout.usec := 1000*ms;
		FOR i := 0 TO SLen - 1  DO readfds[i] := {} END;
		INCL( readfds[s DIV SetBits],  s MOD SetBits );
		REPEAT
			res := Unix.select( s+1, ADDRESSOF( readfds ), 0, 0, timeout );
			IF res < 0 THEN  err := Unix.errno()  END
		UNTIL (res >= 0) OR (err # Unix.EINTR);
		RETURN res > 0
	END AwaitPacket;

	PROCEDURE SetLinger* ( s: INTEGER ): BOOLEAN;
	VAR
		linger: Linger;
		err: INTEGER;
	BEGIN
		linger.onoff := 1;  linger.linger := 1;
		err := setsockopt( s, Unix.SoLSocket, Unix.SoLinger, linger, SIZE OF Linger);
		IF err # 0 THEN  Unix.Perror(  "Sockets.SetLinger (setsockopt)" )  END;
		RETURN err = 0
	END SetLinger;

	PROCEDURE KeepAlive* ( s: INTEGER; enable: BOOLEAN ): BOOLEAN;
	VAR
		opt: Switch;
		err: INTEGER;
	BEGIN
		IF enable THEN  opt.onoff := 1  ELSE  opt.onoff := 0  END;
		err := setsockopt( s, Unix.SoLSocket, Unix.SoKeepAlive, opt, SIZE OF Switch );
		IF err # 0 THEN  Unix.Perror(  "Sockets.KeepAlive (setsockopt)" )  END;
		RETURN err = 0
	END KeepAlive;

	PROCEDURE NoDelay* ( s: INTEGER; enable: BOOLEAN ): BOOLEAN;
	VAR
		opt: Switch;
		err: INTEGER;
	BEGIN
		IF enable THEN  opt.onoff := 1  ELSE  opt.onoff := 0  END;
		err := setsockopt( s, Unix.IpProtoTCP, Unix.SoNoDelay, opt, SIZE OF Switch );
		IF err # 0 THEN  Unix.Perror(  "Sockets.NoDelay (setsockopt)" )  END;
		RETURN err = 0
	END NoDelay;

	PROCEDURE NetToInt* (x: UNSIGNED16): UNSIGNED16;
	BEGIN
		RETURN SIGNED16(ntohs(x))
	END NetToInt;

	PROCEDURE IntToNet* (x: UNSIGNED16): UNSIGNED16;
	BEGIN
		RETURN SIGNED16(htons(x))
	END IntToNet;

	PROCEDURE NetToLInt* (x: SIGNED32): SIGNED32;
	BEGIN
		RETURN SIGNED32(ntohl(x))
	END NetToLInt;

	PROCEDURE LIntToNet* (x: SIGNED32): SIGNED32;
	BEGIN
		RETURN SIGNED32(htonl(x))
	END LIntToNet;

	PROCEDURE Init;
	VAR slib: ADDRESS;
	BEGIN
		#IF LIGHTWEIGHT THEN
		slib := Glue.dlopen(ADDRESSOF("@executable_path/libA2Activities.dylib"), 2); ASSERT(slib # 0);
		Unix.Dlsym(slib, "activity_nonblocking", ADDRESSOF(setNonblocking));
		Unix.Dlsym(slib, "activity_poll_socket", ADDRESSOF(pollSocket));
		Unix.Dlsym(slib, "activity_setup_queue", ADDRESSOF(setupQueue));
		Unix.Dlsym(slib, "activity_cancel_setup", ADDRESSOF(cancelSetup));
		Unix.Dlsym(Unix.libc, "getsockopt", ADDRESSOF(getsockopt));
		#END
		IF Unix.Version = "Solaris" THEN
			slib := Unix.Dlopen( "libsocket.so.1", 2 );
			IF slib = 0 THEN  slib := Unix.Dlopen( "libsocket.so", 2 )  END;
			IF slib = 0 THEN  Trace.StringLn( "Unix.Dlopen( 'libsocket.so' ) failed")  END;
		ELSE
			slib := Unix.libc
		END;
		Unix.Dlsym( slib, "accept", ADDRESSOF( accept ) );
		Unix.Dlsym( slib, "bind", ADDRESSOF( bind ) );
		Unix.Dlsym( slib, "connect", ADDRESSOF( connect ) );
		Unix.Dlsym( slib, "shutdown", ADDRESSOF( shutdown ) );
		Unix.Dlsym( slib, "getpeername", ADDRESSOF( getpeername ) );
		Unix.Dlsym( slib, "htonl", ADDRESSOF( htonl ) );
		Unix.Dlsym( slib, "htons", ADDRESSOF( htons ) );
		Unix.Dlsym( slib, "listen", ADDRESSOF( listen ) );
		Unix.Dlsym( slib, "ntohl", ADDRESSOF( ntohl ) );
		Unix.Dlsym( slib, "ntohs", ADDRESSOF( ntohs ) );
		Unix.Dlsym( slib, "recv", ADDRESSOF( recv ) );
		Unix.Dlsym( slib, "recvfrom", ADDRESSOF( recvfrom ) );
		Unix.Dlsym( slib, "send", ADDRESSOF( send ) );
		Unix.Dlsym( slib, "sendto", ADDRESSOF( sendto ) );
		Unix.Dlsym( slib, "setsockopt", ADDRESSOF( setsockopt ) );
		Unix.Dlsym( slib, "socket", ADDRESSOF( socket ) );
		Unix.Dlsym( slib, "getsockname", ADDRESSOF( getsockname ) );
	END Init;

BEGIN
	Init
END Sockets.
