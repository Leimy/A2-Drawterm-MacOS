MODULE NativeWindowControls;
(** Exercise actual window-manager input dispatch in a booted desktop. *)
IMPORT Commands, Inputs, Kernel, KernelLog, WMWindowManager, WindowManager, WMPieMenu;

PROCEDURE Run*(context: Commands.Context);
VAR manager: WMWindowManager.WindowManager; view: WMWindowManager.ViewPort;
    window: WMWindowManager.DoubleBufferWindow; owner: WMWindowManager.Window; timer: Kernel.Timer;
    mouse: Inputs.AbsMouseMsg; key: Inputs.KeyboardMsg;
    right, top: SIZE;

    PROCEDURE Wait;
    BEGIN timer.Sleep(250) END Wait;

    PROCEDURE Pointer(x, y: SIZE; buttons: SET);
    BEGIN
        mouse.x := SIGNED32(x); mouse.y := SIGNED32(y); mouse.keys := buttons;
        Inputs.mouse.Handle(mouse); Wait
    END Pointer;

    PROCEDURE Key(sym: SIGNED32; flags: SET);
    BEGIN
        key.keysym := sym; key.flags := flags; key.ch := 0X;
        Inputs.keyboard.Handle(key); Wait
    END Key;

BEGIN
    NEW(timer); manager := WMWindowManager.GetDefaultManager(); view := WMWindowManager.GetDefaultView();
    WindowManager.ResetZoom(NIL);
    NEW(window, 480, 300, FALSE); WMWindowManager.AddWindow(window, 60, 100);
    manager.SetFocus(window); Wait;
    right := window.bounds.r; top := window.bounds.t;
    (* Command is also used by drawterm to emulate a right mouse button.
       Even with Meta held, right-click must not reset the application's size. *)
    Key(Inputs.KsMetaL, {Inputs.LeftMeta});
    Pointer(200, 200, {}); Pointer(200, 200, {2}); Pointer(200, 200, {});
    Key(Inputs.KsMetaL, {Inputs.Release});
    ASSERT((window.GetWidth() = 480) & (window.GetHeight() = 300));
    KernelLog.String('PASS: Meta+right-click preserves window dimensions'); KernelLog.Ln;

    (* Exercise the visible title-bar buttons, including restoration. *)
    Pointer(right - 30, top - 10, {}); Pointer(right - 30, top - 10, {0}); Pointer(right - 30, top - 10, {});
    ASSERT(window.windowState = WMWindowManager.WindowState.Maximized);
    Pointer(window.bounds.r - 30, window.bounds.t - 10, {});
    Pointer(window.bounds.r - 30, window.bounds.t - 10, {0}); Pointer(window.bounds.r - 30, window.bounds.t - 10, {});
    ASSERT(window.windowState = WMWindowManager.WindowState.Normal);
    ASSERT((window.GetWidth() = 480) & (window.GetHeight() = 300));
    KernelLog.String('PASS: title-bar maximize and restore'); KernelLog.Ln;

    manager.SetFocus(window);
    Pointer(900, 600, {}); Pointer(900, 600, {2});
    owner := manager.GetPositionOwner(960, 600); ASSERT(owner IS WMPieMenu.Menu);
    Pointer(900, 540, {2}); Pointer(900, 540, {});
    ASSERT(window.windowState = WMWindowManager.WindowState.Maximized);
    KernelLog.String('PASS: desktop pie maximizes the previously focused window'); KernelLog.Ln;
    manager.Remove(window); Wait;

    (* A full press/release must zoom once, not twice. *)
    WindowManager.ResetZoom(NIL);
    Key(Inputs.KsMetaL, {Inputs.LeftMeta});
    Key(Inputs.KsPageUp, {Inputs.LeftMeta});
    Key(Inputs.KsPageUp, {Inputs.LeftMeta, Inputs.Release});
    Key(Inputs.KsMetaL, {Inputs.Release});
    ASSERT(ABS((view.range.r - view.range.l) - view.width0 / 2) < 1);
    Key(ORD(')'), {Inputs.LeftCtrl, Inputs.LeftShift});
    Key(ORD(')'), {Inputs.LeftCtrl, Inputs.LeftShift, Inputs.Release});
    ASSERT((view.range.l = 0) & (view.range.t = 0));
    ASSERT(ABS((view.range.r - view.range.l) - view.width0) < 1);
    KernelLog.String('PASS: zoom key release and Ctrl+Shift+0 reset'); KernelLog.Ln;
    Key(Inputs.KsShiftL, {Inputs.Release});

    (* The desktop reset pie must work while zoomed/panned. *)
    manager.lock.AcquireWrite;
    view(WindowManager.ViewPort).SetRange(300, 200, view.width0 / 2, view.height0 / 2, FALSE);
    manager.lock.ReleaseWrite;
    Pointer(900, 600, {}); Pointer(900, 600, {2});
    Pointer(960, 600, {2}); Pointer(960, 600, {});
    ASSERT((view.range.l = 0) & (view.range.t = 0));
    ASSERT(ABS((view.range.r - view.range.l) - view.width0) < 1);
    KernelLog.String('PASS: zoomed desktop pie resets scale and origin'); KernelLog.Ln;
    KernelLog.String('WINDOW CONTROLS PASS'); KernelLog.Ln
END Run;
END NativeWindowControls.
