MODULE BootConsole;	(** AUTHOR "G.F."; PURPOSE "Boot console"; *)

IMPORT S := SYSTEM, Trace, Unix, Machine, Modules, Objects, Commands, KernelLog,
	DrawtermDisplay, DrawtermInput, OberonInput,
	WindowManager, DisplayRefresher
	#IF DESKTOP THEN
	, DarwinDesktop, MainMenu, DrawtermClipboard
	#ELSE
	, ConcurrentSieve, DrawtermInputMonitor
	#END;

TYPE
	Module = Modules.Module;
	CommandProc = PROCEDURE;



	PROCEDURE LoadModule( CONST name: Modules.Name );
	VAR
		m: Module;  res: INTEGER;  msg: ARRAY 256 OF CHAR;
	BEGIN
		m := Modules.ThisModule( name, res, msg );
		IF m = NIL THEN
			Trace.String( "could not load module " );  Trace.String( name );  Trace.Ln
		END
	END LoadModule;


	PROCEDURE Command( CONST cmd: Modules.Name );
	VAR
		res: INTEGER;
		s: ARRAY 256 OF CHAR;
	BEGIN
		Commands.Call( cmd, {}, res, s );
		IF res # 0 THEN  Trace.String( s ); Trace.Ln  END
	END Command;


	(** Return the named command. *)
	PROCEDURE ThisCommand( m: Module;  CONST name: Modules.Name ): CommandProc;
	VAR cmd: Modules.Command; i: SIGNED32;  found: BOOLEAN;
	BEGIN
		i := 0;  found := FALSE;
		WHILE ~found & (i # LEN( m.command^ )) DO
			IF m.command[i].name = name THEN  found := TRUE;  cmd := m.command[i]  ELSE  INC( i )  END
		END;
		IF (cmd.entryAdr # 0) & (cmd.argTdAdr = 0) & (cmd.retTdAdr = 0) THEN
			RETURN S.VAL( CommandProc, cmd.entryAdr )
		ELSE
			RETURN NIL
		END
	END ThisCommand;


	PROCEDURE Execute( CONST modName, procName: Modules.Name );
	VAR m: Module;  cmd: PROCEDURE;  res: INTEGER;
		msg: ARRAY 256 OF CHAR;
	BEGIN
		m := Modules.ThisModule( modName, res, msg );
		IF m # NIL THEN
			cmd := ThisCommand( m, procName );
			IF cmd # NIL THEN  cmd
			ELSE
				Trace.String( "BootConsole.Execute:  module '" );  Trace.String( modName );
				Trace.String( "' has no command '" );  Trace.String( procName );  Trace.Char( "'" );
				Trace.Ln;
			END
		ELSE
			Trace.String( "BootConsole.Execute:  could not load module " );  Trace.String( modName );
			Trace.Ln;
			Trace.String( msg );  Trace.Ln
		END
	END Execute;



(*	PROCEDURE InitializeCoreModules;
	TYPE Body = PROCEDURE;
	VAR m: Modules.Module;  body: Body;  trace: BOOLEAN;
	BEGIN
		m := Modules.root;  trace :=  Glue.debug # {};
		LOOP
			IF m.name = "BootConsole" THEN  EXIT   END;   (* initialize modules belonging to bootfile only *)
			IF trace THEN
				Trace.String( "#### Initializing " );  Trace.String( m.name );
				Trace.String( "     code: [" ); Trace.Hex( Modules.CodeAddress(m), -8 );
				Trace.String( ".." ); Trace.Hex( Modules.CodeAddress(m) + Modules.CodeLength(m), -8 );
				Trace.Char( ']' ); Trace.Ln
			END;
			body := S.VAL( Body, Modules.CodeAddress(m) );
			body;
			m := m.next
		END
	END InitializeCoreModules;	*)


	PROCEDURE StartSystem;
	BEGIN
		KernelLog.String( Machine.version );  KernelLog.Ln;
		LoadModule( "Clock" );
		#IF ~AARCH64 THEN
		Execute( "XDisplay",  "Install" );
		Execute( "KbdMouse",  "Init" );

		Command( "WindowManager.Install" );
		Command( "DisplayRefresher.Install" );

		Command( "Autostart.Run" );
		#ELSE
			Trace.StringLn( "Native runtime ready" );
			DrawtermDisplay.Install;
			DrawtermInput.Install;
			OberonInput.Install;
			#IF DESKTOP THEN
				DrawtermClipboard.Install;
				WindowManager.Replace(SIGNED32(8080FFFFH), FALSE, FALSE);
				DarwinDesktop.Open;
				MainMenu.Open;
				DisplayRefresher.onResize := MainMenu.Relocate;
				DisplayRefresher.Install;
				KernelLog.String("drawterm paint: transfers="); KernelLog.Int(DrawtermDisplay.display.transfers, 0);
				KernelLog.String(" updates="); KernelLog.Int(DrawtermDisplay.display.updates, 0);
				KernelLog.String(" uploads="); KernelLog.Int(DrawtermDisplay.display.uploads, 0);
				KernelLog.String(" ready="); KernelLog.Boolean(DrawtermDisplay.display.ready); KernelLog.Ln;
				IF DrawtermDisplay.display.ready THEN
					Trace.StringLn( "drawterm desktop initialized" )
				END
			#ELSE
				ConcurrentSieve.Demo;
				DrawtermInputMonitor.Install;
			#END;
			#IF ~DESKTOP THEN
				IF (DrawtermDisplay.display # NIL) & DrawtermDisplay.display.ready THEN
					Objects.Sleep(100);
					DrawtermDisplay.display.Fill(0FF8000H, 12, 12, 48, 48);
					DrawtermDisplay.display.Update;
					KernelLog.String("drawterm multiplexed update ready"); KernelLog.Ln
				END
			#END;
		#END;
	END StartSystem;

	PROCEDURE InitSignalHandling;
	BEGIN
		Unix.HandleSignal( Unix.SIGHUP );
		Unix.HandleSignal( Unix.SIGINT );
		Unix.HandleSignal( Unix.SIGQUIT );
		Unix.HandleSignal( Unix.SIGILL );
		Unix.HandleSignal( Unix.SIGTRAP );

		Unix.HandleSignal( Unix.SIGABRT );
		Unix.HandleSignal( Unix.SIGBUS );
		Unix.HandleSignal( Unix.SIGFPE );
		Unix.HandleSignal( Unix.SIGBUS );
		Unix.HandleSignal( Unix.SIGPIPE );
		Unix.HandleSignal( Unix.SIGALRM );
		Unix.HandleSignal( Unix.SIGTERM );
	END InitSignalHandling;

	PROCEDURE Start*;
	BEGIN
		Machine.VerboseLog;
	(*	InitializeCoreModules;	*)

		(* make current Frame the last one in FindRoots() *)
		S.PUT( S.GetFramePointer(), ADDRESS( 0 ) );
		
		Trace.StringLn( "BootConsole.Start" );
		InitSignalHandling;
		StartSystem;
		#IF ~COOP THEN
			(*	Keep main thread running.
				If the thread is blocked by a mutex (Objects.MainThreadSleep)
				the signals SIGHUP, SIGINT and SIGQUIT don't branch into SignalHandler
				but terminate A2 (at least in Solaris).	*)
			LOOP  Objects.Sleep( 100 )  END;
		#END;
	END Start;

BEGIN
	#IF AARCH64 THEN
		Start
	#END
END BootConsole.
