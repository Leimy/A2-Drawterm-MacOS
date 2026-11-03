MODULE DarwinDesktop;

(** Small native bring-up application using the standard A2 widget toolkit. *)
IMPORT Strings, KernelLog, Commands, WMComponents, WMStandardComponents, WMWindowManager;

TYPE
	Window = OBJECT(WMComponents.FormWindow)
	VAR status: WMStandardComponents.Label; clicks: SIGNED32;

		PROCEDURE &New;
		VAR panel: WMStandardComponents.Panel; title: WMStandardComponents.Label;
			button: WMStandardComponents.Button;
		BEGIN
			NEW(panel); panel.bounds.SetExtents(520, 320);
			panel.fillColor.Set(SIGNED32(0E8E8E8FFH));
			NEW(title); title.alignment.Set(WMComponents.AlignTop); title.bounds.SetHeight(64);
			title.caption.SetAOC("A2 / Active Oberon on Apple Silicon"); panel.AddContent(title);
			NEW(button); button.takesFocus.Set(TRUE); button.alignment.Set(WMComponents.AlignTop); button.bounds.SetHeight(48);
			button.caption.SetAOC("Click to test A2 events"); button.onClick.Add(Click); panel.AddContent(button);
			NEW(button); button.takesFocus.Set(TRUE); button.alignment.Set(WMComponents.AlignTop); button.bounds.SetHeight(40);
			button.caption.SetAOC("Open A2 Notepad"); button.onClick.Add(OpenEditor); panel.AddContent(button);
			NEW(button); button.takesFocus.Set(TRUE); button.alignment.Set(WMComponents.AlignTop); button.bounds.SetHeight(32);
			button.caption.SetAOC("Zoom in"); button.onClick.Add(ZoomIn); panel.AddContent(button);
			NEW(button); button.takesFocus.Set(TRUE); button.alignment.Set(WMComponents.AlignTop); button.bounds.SetHeight(32);
			button.caption.SetAOC("Zoom out"); button.onClick.Add(ZoomOut); panel.AddContent(button);
			NEW(button); button.takesFocus.Set(TRUE); button.alignment.Set(WMComponents.AlignTop); button.bounds.SetHeight(32);
			button.caption.SetAOC("Reset desktop zoom"); button.onClick.Add(ResetZoom); panel.AddContent(button);
			NEW(status); status.alignment.Set(WMComponents.AlignClient);
			status.caption.SetAOC("Native AArch64 runtime - drawterm display"); panel.AddContent(status);
			Init(520, 320, FALSE); SetContent(panel);
			SetTitle(Strings.NewString("A2 native desktop bring-up"));
			WMWindowManager.AddWindow(SELF, 80, 100)
		END New;

		PROCEDURE OpenEditor(sender, data: ANY);
		VAR res: SIGNED32; message: ARRAY 256 OF CHAR;
		BEGIN
			Commands.Call("Notepad.Open", {}, res, message);
			IF res = 0 THEN KernelLog.String("A2 Notepad opened")
			ELSE KernelLog.String("Notepad: "); KernelLog.String(message) END;
			KernelLog.Ln
		END OpenEditor;

		PROCEDURE ChangeZoom(scale: FLOAT32);
		VAR view: WMWindowManager.ViewPort; manager: WMWindowManager.WindowManager;
			width, height, cx, cy: FLOAT32;
		BEGIN
			manager := WMWindowManager.GetDefaultManager(); manager.lock.AcquireWrite;
			view := WMWindowManager.GetDefaultView();
			IF view = NIL THEN manager.lock.ReleaseWrite; RETURN END;
			width := view.range.r - view.range.l; height := view.range.b - view.range.t;
			cx := (view.range.l + view.range.r) / 2; cy := (view.range.t + view.range.b) / 2;
			width := width * scale; height := height * scale;
			IF (width >= 128) & (height >= 96) & (width <= view.width0 * 8) & (height <= view.height0 * 8) THEN
				view.SetRange(cx - width / 2, cy - height / 2, width, height, FALSE);
				KernelLog.String("desktop zoom: "); KernelLog.Int(ENTIER(width), 0);
				KernelLog.Char("x"); KernelLog.Int(ENTIER(height), 0); KernelLog.Ln
			END;
			manager.lock.ReleaseWrite
		END ChangeZoom;

		PROCEDURE ZoomIn(sender, data: ANY);
		BEGIN ChangeZoom(0.75) END ZoomIn;

		PROCEDURE ZoomOut(sender, data: ANY);
		BEGIN ChangeZoom(1.25) END ZoomOut;

		PROCEDURE ResetZoom(sender, data: ANY);
		VAR view: WMWindowManager.ViewPort; manager: WMWindowManager.WindowManager;
		BEGIN
			manager := WMWindowManager.GetDefaultManager(); manager.lock.AcquireWrite;
			view := WMWindowManager.GetDefaultView();
			IF view # NIL THEN view.SetRange(0, 0, view.width0, view.height0, FALSE) END;
			manager.lock.ReleaseWrite
		END ResetZoom;

		PROCEDURE Click(sender, data: ANY);
		VAR text, number: ARRAY 64 OF CHAR;
		BEGIN
			INC(clicks); COPY("A2 button clicks: ", text); Strings.IntToStr(clicks, number);
			Strings.Append(text, number); status.caption.SetAOC(text);
			KernelLog.String(text); KernelLog.Ln
		END Click;
	END Window;

VAR window: Window;
PROCEDURE Open*;
BEGIN
	IF window = NIL THEN NEW(window) END
END Open;
END DarwinDesktop.
