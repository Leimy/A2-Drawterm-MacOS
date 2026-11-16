MODULE NativeGUIInheritance;
(** The hosted GUI hierarchy needs full metadata, not the three-tag simple layout. *)
IMPORT WMWindowManager, KernelLog;
TYPE Window* = OBJECT(WMWindowManager.DoubleBufferWindow)
END Window;
PROCEDURE Run*;
VAR window: Window; base: WMWindowManager.Window;
BEGIN
	KernelLog.String("GUI inheritance construction started"); KernelLog.Ln;
	NEW(window, 16, 16, FALSE); base := window;
	KernelLog.String("GUI inheritance construction finished"); KernelLog.Ln;
	ASSERT(base IS WMWindowManager.DoubleBufferWindow);
	ASSERT(base IS Window); window := base(Window);
	ASSERT(window.GetWidth() = 16);
	KernelLog.String("GUI inheritance type metadata passed"); KernelLog.Ln
END Run;
END NativeGUIInheritance.
