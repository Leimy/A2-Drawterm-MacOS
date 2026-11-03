MODULE NativeDesktopHello;

IMPORT KernelLog, Texts, TextUtilities;

PROCEDURE Run*;
BEGIN
	KernelLog.String("native A2 desktop compiler demo ran"); KernelLog.Ln
END Run;

PROCEDURE Copy*;
BEGIN
	Texts.clipboard.AcquireWrite;
	Texts.clipboard.Delete(0, Texts.clipboard.GetLength());
	TextUtilities.StrToText(Texts.clipboard, 0, "copied from native A2");
	Texts.clipboard.ReleaseWrite
END Copy;

END NativeDesktopHello.
