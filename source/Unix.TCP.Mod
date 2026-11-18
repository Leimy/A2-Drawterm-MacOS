(* Aos, Copyright 2001, Pieter Muller, ETH Zurich *)

MODULE TCP;   (** AUTHOR "pjm, mvt, G.F."; PURPOSE "TCP protocol"; *)
(*  2020.04.06  PDR     fixing Open for IPv6*) 

IMPORT Out := KernelLog, IP, Streams,  Unix, Sockets, Objects;

CONST
	NilPort* = 0;

	(** Error codes *)
	Ok* = 0;
	ConnectionRefused* = 3701;
	ConnectionReset* = 3702;
	WrongInterface* = 3703;
	TimedOut* = 3704;
	NotConnected* = 3705;
	NoInterface* = 3706;
	InterfaceClosed* = 3707;


	(** TCP connection states *)
	NumStates* = 4;
	Closed* = 0;
	Listen* = 1;
	Established* = 2;
	Unused* = 4;   (* no real state, only used in this implementation *)

	OpenStates* = {Listen, Established};
	ClosedStates* = {Unused, Closed};
	HalfClosedStates* = ClosedStates + {};
	FinStates* = {Unused, Closed};

VAR
	trace: BOOLEAN;

TYPE
	Sender = OBJECT
		VAR
			conn: Connection;

			PROCEDURE &New( c: Connection );
			BEGIN
				conn := c
			END New;

			PROCEDURE SendPacket( CONST data: ARRAY OF CHAR;  ofs, len: SIZE ): BOOLEAN;
			VAR n: SIZE;
			BEGIN
				#IF ~LIGHTWEIGHT THEN
				{EXCLUSIVE}
				#END
				WHILE len > 0 DO
					n := len;
					#IF LIGHTWEIGHT THEN
					IF ~Sockets.SendStream(conn.socket, data, ofs, n) OR (n = 0) THEN RETURN FALSE END;
					#ELSE
					IF ~Sockets.Send( conn.socket, data, ofs, n ) OR (n = 0) THEN  RETURN FALSE  END;
					#END
					DEC( len, n );  INC( ofs, n )
				END;
				RETURN TRUE
			END SendPacket;

	END Sender;


#IF LIGHTWEIGHT THEN
TYPE
	(* Serialize operations in each direction. Shutdown wakes parked callers;
	   the last operation to finish releases the descriptor. *)
	IOState = OBJECT
	VAR reading, writing, opening: BOOLEAN; queue: INTEGER;
		PROCEDURE &Init;
		BEGIN queue := -1 END Init;

		PROCEDURE BeginOpen(c: Connection);
		BEGIN {EXCLUSIVE}
			ASSERT((c.state = Unused) & ~opening); opening := TRUE
		END BeginOpen;

		PROCEDURE EndOpen(c: Connection; fd: INTEGER; next: SIGNED8): BOOLEAN;
		BEGIN {EXCLUSIVE}
			opening := FALSE;
			IF (c.state = Closed) OR (next = Unused) THEN RETURN FALSE END;
			c.socket := fd; c.state := next; RETURN TRUE
		END EndOpen;

		PROCEDURE WaitSetup(c: Connection; fd: INTEGER; write: BOOLEAN): BOOLEAN;
		VAR q: INTEGER; ready, completed: BOOLEAN;
		BEGIN
			q := -1;
			BEGIN {EXCLUSIVE}
				IF c.state # Closed THEN
					ASSERT(queue < 0); q := Sockets.SetupQueue(fd, write); queue := q
				END
			END;
			IF q >= 0 THEN ready := Sockets.WaitSocket(q, FALSE) END;
			completed := TRUE
		FINALLY
			BEGIN {EXCLUSIVE}
				IF q >= 0 THEN queue := -1; IGNORE Unix.close(q) END;
				ready := ready & (c.state # Closed)
			END;
			IF ~completed THEN HALT(18) END;
			RETURN ready
		END WaitSetup;

		PROCEDURE Acquire(c: Connection; send: BOOLEAN): BOOLEAN;
		BEGIN {EXCLUSIVE}
			IF send THEN
				AWAIT(~writing OR (c.state # Established));
				IF c.state # Established THEN RETURN FALSE END; writing := TRUE
			ELSE
				AWAIT(~reading OR ~(c.state IN OpenStates));
				IF ~(c.state IN OpenStates) THEN RETURN FALSE END; reading := TRUE
			END;
			RETURN TRUE
		END Acquire;

		PROCEDURE Finish(c: Connection; send, failed: BOOLEAN);
		BEGIN {EXCLUSIVE}
			IF send THEN writing := FALSE ELSE reading := FALSE END;
			IF failed & (c.state IN OpenStates) THEN
				c.state := Closed; Sockets.ShutdownReadWrite(c.socket)
			END;
			IF (c.state = Closed) & ~reading & ~writing THEN IGNORE Unix.close(c.socket) END
		END Finish;

		PROCEDURE Close(c: Connection);
		BEGIN {EXCLUSIVE}
			IF queue >= 0 THEN Sockets.CancelSetup(queue) END;
			IF opening THEN c.state := Closed
			ELSIF c.state IN OpenStates THEN
				c.state := Closed;
				IF reading OR writing THEN Sockets.ShutdownReadWrite(c.socket) ELSE Sockets.Close(c.socket) END
			END
		END Close;
	END IOState;
#END

TYPE
	(** Connection object.
		NOTE: Only one process should access a Connection!  *)
	Connection* = OBJECT (Streams.Connection)
			VAR
				int-	: IP.Interface;	(*! Unix port: dummy, only 'int.localAdr' contains valid data *)

				lport-	: UNSIGNED32;
				fip-	: IP.Adr;  (* foreign protocol address *)
				fport-	: UNSIGNED32;
				state*	: SIGNED8;   (* TCP state *)

				socket	: SIGNED32;
				sender: Sender;

				(* the next variables are for interface compatibility only *)
				irs-		: SIGNED32;	(* initial receive sequence number *)
				rcvnxt-	: SIGNED32;	(* receive next *)
				iss-		: SIGNED32;	(* initial send sequence number *)
				sndnxt-	: SIGNED32;	(* send next *)


				#IF LIGHTWEIGHT THEN
				VAR io: IOState;
				#END

				PROCEDURE & Init*;
				BEGIN
					state := Unused;
					NEW( sender, SELF );
					#IF LIGHTWEIGHT THEN
					NEW(io);
					#END
					irs := 0; iss := 0;  rcvnxt := 0;  sndnxt := 0
				END Init;



				(** Open a TCP connection (only use once per Connection instance).
					Use TCP.NilPort for lport to automatically assign an unused local port.*)
				PROCEDURE Open*( lport: UNSIGNED32;  fip: IP.Adr;  fport: UNSIGNED32;  VAR res: INTEGER );
				VAR localAdr, foreignAdr: Sockets.SocketAdr; fd, af: INTEGER; next: SIGNED8; ok: BOOLEAN;
				#IF LIGHTWEIGHT THEN
				VAR pending, owned, completed: BOOLEAN;
				#END
				BEGIN
					#IF ~LIGHTWEIGHT THEN
					{EXCLUSIVE}
					#END
					fd := -1; next := Unused; ok := FALSE; res := NotConnected;
					ASSERT((state = Unused) & (lport < 10000H) & (fport < 10000H));
					#IF LIGHTWEIGHT THEN
					io.BeginOpen(SELF); owned := TRUE;
					#END
					IF fip.usedProtocol = IP.IPv6 THEN af := Unix.AFINET6 ELSE af := Unix.AFINET END;
					fd := Sockets.Socket(af, Unix.SockStream, Unix.IpProtoTCP);
					IF fd >= 0 THEN
						IF ~IP.IsNilAdr(fip) & (fport # NilPort) THEN
							foreignAdr := Sockets.NewSocketAdr(fip, fport); res := ConnectionRefused;
							#IF LIGHTWEIGHT THEN
							IF Sockets.PrepareStream(fd) THEN
								ok := Sockets.StartConnect(fd, foreignAdr, pending);
								IF pending THEN ok := io.WaitSetup(SELF, fd, TRUE) & Sockets.Connected(fd) END
							END;
							#ELSE
							ok := Sockets.Connect(fd, foreignAdr);
							#END
							IF ok THEN next := Established ELSE Out.String("connect failed"); Out.Ln END
						ELSE
							ASSERT((fport = NilPort) & IP.IsNilAdr(fip));
							localAdr := Sockets.NewSocketAdr(fip, lport);
							IF Sockets.Bind(fd, localAdr) & Sockets.Listen(fd)
							#IF LIGHTWEIGHT THEN
								& Sockets.PrepareStream(fd)
							#END
							THEN next := Listen END
						END;
						IF next # Unused THEN
							localAdr := Sockets.GetSockName(fd);
							IF localAdr # NIL THEN
								IGNORE Sockets.SetLinger(fd); SELF.fip := fip; SELF.fport := fport;
								SELF.lport := Sockets.GetPortNumber(localAdr);
								NEW(int, Sockets.SockAdrToIPAdr(localAdr)); res := Ok
							ELSE next := Unused; res := NotConnected END
						END
					END;
					#IF LIGHTWEIGHT THEN
					completed := TRUE
				FINALLY
					IF owned THEN
						IF ~completed THEN next := Unused END;
						IF io.EndOpen(SELF, fd, next) THEN fd := -1
						ELSIF (state = Closed) OR (res = Ok) THEN res := NotConnected END
					END;
					IF fd >= 0 THEN Sockets.Close(fd) END;
					IF ~completed THEN HALT(18) END;
					#ELSE
					IF next # Unused THEN socket := fd; state := next
					ELSIF fd >= 0 THEN Sockets.Close(fd) END;
					#END
					IF trace THEN Out.String("Open: local port="); Out.Int(SELF.lport, 0);
						Out.String(" result="); Out.Int(res, 0); Out.Ln END
				END Open;


				(** Send data on a TCP connection. *)
				PROCEDURE Send*( CONST data: ARRAY OF CHAR;  ofs, len: SIZE;  propagate: BOOLEAN;  VAR res: INTEGER );
				#IF LIGHTWEIGHT THEN
				VAR acquired, completed: BOOLEAN;
				#END
				BEGIN
					IF trace THEN  Out.String( "Send: socket=" );  Out.Int( socket, 0 )  END;
					#IF LIGHTWEIGHT THEN
					acquired := io.Acquire(SELF, TRUE);
					IF acquired THEN
					#ELSE
					IF state = Established THEN
					#END
						IF sender.SendPacket( data, ofs, len ) THEN
							res := Ok
						ELSE
							res := ConnectionReset
						END
					ELSE
						res := NotConnected (* Send on a Connection with state=Listen *)
					END;
					INC( sndnxt );
					#IF LIGHTWEIGHT THEN
					completed := TRUE
				FINALLY
					IF acquired THEN io.Finish(SELF, TRUE, ~completed) END;
					IF ~completed THEN HALT(18) END
					#END
				END Send;

				PROCEDURE ReadBytes(VAR data: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
				VAR x: SIZE;
				BEGIN
					IF trace THEN Out.String("Receive: socket="); Out.Int(socket, 0); Out.String(" min="); Out.Int(min, 0) END;
					REPEAT
						x := size;
						#IF LIGHTWEIGHT THEN
						IF ~Sockets.RecvStream(socket, data, ofs, x) OR (x = 0) THEN res := NotConnected; RETURN END;
						#ELSE
						IF ~Sockets.Recv(socket, data, ofs, x, 0) OR (x = 0) THEN res := NotConnected; RETURN END;
						#END
						DEC(size, x); INC(len, x); INC(ofs, x)
					UNTIL len >= min;
					INC(rcvnxt)
				END ReadBytes;

				(** Receive data on a TCP connection. The data parameter specifies the buffer.
					The ofs parameters specify the position in the buffer where data should be received (usually 0),
					and the size parameters specifies how many bytes of data can be received in the buffer.
					The min parameter specifies the minimum number of bytes to receive before Receive returns
					and must by <= size. The len parameter returns the number of bytes received, and the
					res parameter returns 0 if ok, or a non-zero error code otherwise (e.g. if the connection is closed
					by the communication partner, or by a call of the Close method). *)

				#IF LIGHTWEIGHT THEN
				PROCEDURE Receive*(VAR data: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
				VAR acquired, completed: BOOLEAN;
				BEGIN
					ASSERT((ofs >= 0) & (size >= 0) & (ofs <= LEN(data)-size) & (min <= size));
					len := 0; res := Ok;
					IF size > 0 THEN
						acquired := io.Acquire(SELF, FALSE);
						IF acquired THEN ReadBytes(data, ofs, size, min, len, res)
						ELSE res := NotConnected; INC(rcvnxt) END
					END;
					completed := TRUE
				FINALLY
					IF acquired THEN io.Finish(SELF, FALSE, ~completed OR (res # Ok)) END;
					IF ~completed THEN HALT(18) END (* rethrow after releasing the reader *)
				END Receive;
				#ELSE
				PROCEDURE Receive*(VAR data: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
				BEGIN {EXCLUSIVE}
					ASSERT((ofs >= 0) & (size >= 0) & (ofs <= LEN(data)-size) & (min <= size));
					len := 0; res := Ok;
					IF size = 0 THEN RETURN END;
					IF state IN OpenStates THEN
						ReadBytes(data, ofs, size, min, len, res);
						IF res # Ok THEN Sockets.Close(socket); state := Closed END
					ELSE res := NotConnected; INC(rcvnxt) END
				END Receive;
				#END

				(** Enable or disable delayed send (Nagle algorithm).
					If enabled, the sending of a segment is delayed if it is not filled by one call to Send, in order to be able
					to be filled by further calls to Send. This is the default option.
					If disabled, a segment is sent immediatly after a call to Send, even if it is not filled.
					This option is normally chosen by applications like telnet or VNC client, which send verly little data but
					shall not be delayed.*)
				PROCEDURE DelaySend*( enable: BOOLEAN );
				VAR ignore: BOOLEAN;
				BEGIN {EXCLUSIVE}
					ignore := Sockets.NoDelay( socket, ~enable )
				END DelaySend;

				(** Enable or disable keep-alive. (default: disabled) *)
				PROCEDURE KeepAlive*( enable: BOOLEAN );
				VAR ignore: BOOLEAN;
				BEGIN {EXCLUSIVE}
					ignore := Sockets.KeepAlive( socket, enable )
				END KeepAlive;


				(** Return number of bytes that may be read without blocking. *)
				PROCEDURE Available*( ): SIGNED32;
				VAR available: SIGNED32;
				BEGIN {EXCLUSIVE}
					IF state IN {Established, Listen} THEN
						IF Sockets.Requested( socket ) THEN
							available := Sockets.Available( socket );
							IF available >= 0 THEN
								RETURN available
							END;
						END
					END;
					RETURN  0
				END Available;

				(** Return connection state. *)
				PROCEDURE State*( ): SIGNED32;
				BEGIN
					RETURN state
				END State;

				(** Wait until the connection state is either in the good or bad set, up to "ms" milliseconds. *)
				PROCEDURE AwaitState*( good, bad: SET;  ms: SIGNED32;  VAR res: INTEGER );
				BEGIN
					WHILE (ms > 0) & ~(state IN (good+bad)) DO  Objects.Sleep( 10 );  DEC( ms, 10 )  END;
					IF state IN good THEN
						res := Ok
					ELSIF state IN bad THEN
						res := NotConnected
					ELSE
						res := TimedOut
					END
				END AwaitState;

				(** Close a TCP connection (half-close). *)
				PROCEDURE Close*;
				BEGIN
					#IF LIGHTWEIGHT THEN
					io.Close(SELF)
					#ELSE
					Sockets.Close(socket); state := Closed
					#END
				END Close;

				(** Discard a TCP connection (shutdown). *)
				PROCEDURE Discard*;
				BEGIN
					Close
				END Discard;

				(** Accept a client waiting on a listening connection. Blocks until a client is available or the
					  connection is closed. *)
				PROCEDURE Accept*( VAR client: Connection;  VAR res: INTEGER );
				VAR newsocket: SIGNED32;  peerAdr: Sockets.SocketAdr;
				#IF LIGHTWEIGHT THEN
				VAR acquired, pending, completed: BOOLEAN;
				#END
				BEGIN
					#IF ~LIGHTWEIGHT THEN
					{EXCLUSIVE}
					#END
					newsocket := -1; client := NIL; res := NotConnected;
					IF state = Listen THEN
						#IF LIGHTWEIGHT THEN
						acquired := io.Acquire(SELF, FALSE);
						IF acquired THEN
							REPEAT
								newsocket := Sockets.TryAccept(socket, pending)
							UNTIL ~pending OR ~io.WaitSetup(SELF, socket, FALSE);
							IF (newsocket >= 0) & ~Sockets.PrepareStream(newsocket) THEN
								Sockets.Close(newsocket); newsocket := -1
							END
						END;
						#ELSE
						newsocket := Sockets.Accept(socket);
						#END
						IF newsocket >= 0 THEN
							peerAdr := Sockets.GetPeerName(newsocket);
							IF peerAdr # NIL THEN
								NEW(client); client.int := int; client.lport := lport;
								client.fip := Sockets.SockAdrToIPAdr(peerAdr);
								client.fport := Sockets.GetPortNumber(peerAdr);
								client.socket := newsocket; client.state := Established;
								newsocket := -1; res := Ok
							END
						END
					END;
					#IF LIGHTWEIGHT THEN
					completed := TRUE
				FINALLY
					IF acquired THEN io.Finish(SELF, FALSE, FALSE) END;
					#END
					IF newsocket >= 0 THEN Sockets.Close(newsocket) END;
					IF trace THEN Out.String("Accept: socket="); Out.Int(socket, 0); Out.String(" result="); Out.Int(res, 0); Out.Ln END;
					#IF LIGHTWEIGHT THEN
					IF ~completed THEN HALT(18) END
					#END
				END Accept;

				(** Return TRUE iff a listening connection has clients waiting to be accepted. *)
				PROCEDURE Requested*( ): BOOLEAN;
				BEGIN {EXCLUSIVE}
					RETURN (state = Listen) & Sockets.Requested( socket )
				END Requested;


			END Connection;




	(** Aos command - display all errors *)
	PROCEDURE DisplayErrors*( par: ANY ): ANY;
	BEGIN
		RETURN NIL;
	END DisplayErrors;


	(** Aos command - discard and finalize all connections *)
	PROCEDURE DiscardAll*( par: ANY ): ANY;
	BEGIN
		RETURN NIL;
	END DiscardAll;


	(** Temporary trace procedure. *)
	PROCEDURE ToggleTrace*;
	BEGIN
		trace := ~trace;
		Out.Enter;
		Out.String( "TCP trace " );
		IF trace THEN  Out.String( "on" )  ELSE  Out.String( "off" )  END;
		Out.Exit
	END ToggleTrace;


END TCP.

