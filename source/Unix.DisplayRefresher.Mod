MODULE DisplayRefresher; (** AUTHOR "staubesv"; PURPOSE "Force redraw of default viewport when receiving a X11 expore event"; *)

IMPORT
	Modules, KernelLog, Inputs, WMMessages, WMWindowManager
	#IF AARCH64 THEN
	, DrawtermInput, DrawtermDisplay, WindowManager
	#END;

VAR
	manager : WMWindowManager.WindowManager;
	viewport : WMWindowManager.ViewPort;
	#IF AARCH64 THEN
	onResize* : PROCEDURE;
	#END;

(* Message preview handler for window manager. MUST NOT TRAP!!! *)
PROCEDURE Handle(VAR msg : WMMessages.Message; VAR discard : BOOLEAN);
VAR meta : BOOLEAN;

BEGIN
	discard := FALSE;
	IF msg.msgType = WMMessages.MsgKey THEN
		meta := (msg.flags * Inputs.Meta # {}) OR ((msg.flags * Inputs.Alt # {}) & (msg.flags * Inputs.Shift # {}));
		IF ~meta & (msg.y =  0FFC6H) THEN
			manager.RefreshView(viewport);
		END;
	END;
END Handle;

#IF AARCH64 THEN
PROCEDURE Resize;
VAR resized : BOOLEAN;
BEGIN
	resized := FALSE;
	manager.lock.AcquireWrite;
	IF (viewport IS WindowManager.ViewPort) & DrawtermDisplay.display.Resize() THEN
		viewport(WindowManager.ViewPort).ResizeDisplay;
		Inputs.main.SetLimits(DrawtermDisplay.display.width - 1, DrawtermDisplay.display.height - 1, 0);
		manager.RefreshView(viewport);
		resized := TRUE;
		KernelLog.String("drawterm resized: "); KernelLog.Int(DrawtermDisplay.display.width, 0);
		KernelLog.Char("x"); KernelLog.Int(DrawtermDisplay.display.height, 0); KernelLog.Ln
	END;
	manager.lock.ReleaseWrite;
	IF resized & (onResize # NIL) THEN onResize END
END Resize;
#END

PROCEDURE Install*;
BEGIN
	manager := WMWindowManager.GetDefaultManager();
	viewport := WMWindowManager.GetDefaultView();
	IF (manager # NIL) & (viewport # NIL) THEN
		#IF AARCH64 THEN
		DrawtermInput.resizeHandler := Resize;
		#END;
		manager.InstallMessagePreview(Handle);
		Refresh;
		KernelLog.String("DisplayRefresher installed.")
	ELSE
		KernelLog.String("DisplayRefresher installation failed (could not find window manager or viewport) ")
	END;
	KernelLog.Ln
END Install;

PROCEDURE Refresh*;
BEGIN
	manager.RefreshView(viewport);
END Refresh;


PROCEDURE Cleanup;
BEGIN
	IF (manager # NIL) THEN manager.RemoveMessagePreview(Handle); END;
END Cleanup;

BEGIN
	Modules.InstallTermHandler(Cleanup)
END DisplayRefresher.

DisplayRefresher.Install ~
DisplayRefresher.Refresh ~

System.Free DisplayRefresher ~
