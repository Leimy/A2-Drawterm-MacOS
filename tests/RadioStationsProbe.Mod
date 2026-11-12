MODULE RadioStationsProbe;
IMPORT RadioStations, Commands, KernelLog, Math64;

PROCEDURE Run*(context: Commands.Context);
VAR filename: ARRAY 1024 OF CHAR; catalogue: RadioStations.Catalogue;
	view: RadioStations.View; x, y: SIZE; depth: FLOAT64;
BEGIN
	ASSERT(context.arg.GetString(filename)); NEW(catalogue, filename);
	ASSERT(catalogue.count = 3); ASSERT(catalogue.rejected = 3);
	ASSERT(catalogue.items[0].name^ = "Test One");
	ASSERT(catalogue.items[0].url^ = "http://example.invalid/a;data");
	RadioStations.MakeView(Math64.deg2rad(20), 0, 205, 600, 500, view);
	ASSERT(RadioStations.Project(catalogue.items[0], view, x, y, depth));
	ASSERT((ABS(x - 300) <= 1) & (ABS(y - 238) <= 1) & (depth > 0.999));
	ASSERT(~RadioStations.Project(catalogue.items[2], view, x, y, depth));
	ASSERT(catalogue.Hit(view, 300, 238, -1) = 0);
	ASSERT(catalogue.Hit(view, 300, 238, 1) = 1);
	ASSERT(catalogue.Hit(view, 0, 0, -1) = -1);
	RadioStations.MakeView(Math64.deg2rad(20), Math64.pi, 400, 800, 600, view);
	ASSERT(RadioStations.Project(catalogue.items[2], view, x, y, depth));
	ASSERT((ABS(x - 400) <= 1) & (ABS(y - 288) <= 1));
	KernelLog.String("STATIONS PASS parsing, projection, back-face rejection, sticky picking"); KernelLog.Ln
END Run;

PROCEDURE Data*;
VAR catalogue: RadioStations.Catalogue;
BEGIN
	NEW(catalogue, "RadioGlobeStations.txt"); ASSERT(catalogue.count = 9297); ASSERT(catalogue.rejected = 0);
	NEW(catalogue, "RadioGlobeStationsTop.txt"); ASSERT(catalogue.count = 899); ASSERT(catalogue.rejected = 0);
	KernelLog.String("STATIONS PASS original 9front catalogues"); KernelLog.Ln
END Data;

END RadioStationsProbe.
