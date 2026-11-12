MODULE WMRadioStations;
IMPORT RadioStations, RadioGlobeAudio, WMComponents, WMStandardComponents, WMEditors,
	WMStringGrids, WMGrids, WMWindowManager, WMGraphics, WMMessages, Modules, Strings, KernelLog;

TYPE
	Select* = PROCEDURE {DELEGATE}(station: RadioStations.Station);
	Killer = OBJECT END Killer;
	Window* = OBJECT(WMComponents.FormWindow)
	VAR catalogue: RadioStations.Catalogue; choose: Select; open: BOOLEAN;
		search: WMEditors.Editor; grid: WMStringGrids.StringGrid; summary: WMStandardComponents.Label;
		lastQuery: ARRAY 513 OF CHAR;

		PROCEDURE &New*(stations: RadioStations.Catalogue; callback: Select);
		VAR panel, toolbar: WMStandardComponents.Panel; button: WMStandardComponents.Button;
			label: WMStandardComponents.Label; spacings: WMGrids.Spacings;
		BEGIN
			catalogue := stations; choose := callback; open := TRUE; IncCount;
			NEW(panel); panel.bounds.SetExtents(660, 420); panel.fillColor.Set(SIGNED32(0EEEEEEFFH));
			NEW(toolbar); toolbar.alignment.Set(WMComponents.AlignTop); toolbar.bounds.SetHeight(26); panel.AddContent(toolbar);
			NEW(button); button.caption.SetAOC("Play"); button.bounds.SetWidth(70); button.alignment.Set(WMComponents.AlignLeft);
			button.onClick.Add(Play); toolbar.AddContent(button);
			NEW(button); button.caption.SetAOC("Stop"); button.bounds.SetWidth(70); button.alignment.Set(WMComponents.AlignLeft);
			button.onClick.Add(Stop); toolbar.AddContent(button);
			NEW(label); label.caption.SetAOC(" Search:"); label.bounds.SetWidth(75); label.alignment.Set(WMComponents.AlignLeft); toolbar.AddContent(label);
			NEW(search); search.multiLine.Set(FALSE); search.fillColor.Set(SIGNED32(0FFFFFFFFH));
			search.alignment.Set(WMComponents.AlignClient); search.onEnter.Add(Filter); toolbar.AddContent(search);
			NEW(summary); summary.alignment.Set(WMComponents.AlignBottom); summary.bounds.SetHeight(24); panel.AddContent(summary);
			NEW(grid); grid.alignment.Set(WMComponents.AlignClient); grid.fixedRows.Set(1);
			grid.SetSelectionMode(WMGrids.GridSelectRows); panel.AddContent(grid);
			NEW(spacings, 3); spacings[0] := 400; spacings[1] := 80; spacings[2] := 160; grid.SetColSpacings(spacings);
			Init(660, 420, FALSE); SetContent(panel); SetTitle(Strings.NewString("RadioGlobe stations"));
			Filter(NIL, NIL); WMWindowManager.DefaultAddWindow(SELF); search.SetFocus;
			KernelLog.String("Radio station browser opened"); KernelLog.Ln
		END New;

		PROCEDURE Filter(sender, data: ANY);
		VAR query, name: ARRAY 513 OF CHAR; coordinates, number: ARRAY 64 OF CHAR;
			i, row: SIZE; station: RadioStations.Station; playUnique: BOOLEAN;
		BEGIN
			search.GetAsString(query); Strings.LowerCase(query);
			grid.model.Acquire;
			grid.model.SetNofCols(3); grid.model.SetNofRows(catalogue.count + 1);
			grid.model.SetCellText(0, 0, Strings.NewString("Station"));
			grid.model.SetCellText(1, 0, Strings.NewString("Format hint"));
			grid.model.SetCellText(2, 0, Strings.NewString("Latitude / longitude"));
			row := 1;
			FOR i := 0 TO catalogue.count - 1 DO
				station := catalogue.items[i]; COPY(station.name^, name); Strings.LowerCase(name);
				IF (query = "") OR (Strings.Pos(query, name) >= 0) THEN
					grid.model.SetCellText(0, row, station.name); grid.model.SetCellData(0, row, station);
					grid.model.SetCellText(1, row, RadioStations.FormatHint(station));
					Strings.FloatToStr(station.latitude, 0, 2, 0, coordinates); Strings.AppendX(coordinates, " / ");
					Strings.FloatToStr(station.longitude, 0, 2, 0, number); Strings.AppendX(coordinates, number);
					grid.model.SetCellText(2, row, Strings.NewString(coordinates)); INC(row)
				END
			END;
			grid.model.SetNofRows(row); grid.model.Release;
			IF row > 1 THEN grid.SetSelection(0, 1, 2, 1) END;
			Strings.IntToStr(row - 1, coordinates);
			IF row = 2 THEN Strings.AppendX(coordinates, " station | Enter again to play, or click Play")
			ELSE Strings.AppendX(coordinates, " stations | Enter to search; select a row, then Play") END;
			summary.caption.SetAOC(coordinates); grid.Invalidate;
			KernelLog.String("Radio station search: "); KernelLog.String(query); KernelLog.String(" matches="); KernelLog.Int(row - 1, 0); KernelLog.Ln;
			playUnique := (query # "") & (query = lastQuery) & (row = 2); lastQuery := query;
			IF playUnique THEN Play(NIL, NIL) END
		END Filter;

		PROCEDURE Play(sender, data: ANY);
		VAR left, top, right, bottom: SIZE; entry: ANY;
		BEGIN
			grid.Acquire; grid.GetSelection(left, top, right, bottom);
			grid.model.Acquire; entry := grid.model.GetCellData(0, top); grid.model.Release; grid.Release;
			IF (entry # NIL) & (entry IS RadioStations.Station) & (choose # NIL) THEN choose(entry(RadioStations.Station)) END
		END Play;
		PROCEDURE Stop(sender, data: ANY);
		BEGIN RadioGlobeAudio.RequestStop END Stop;
		PROCEDURE IsOpen*(): BOOLEAN;
		BEGIN RETURN open END IsOpen;
		PROCEDURE Close*;
		BEGIN IF open THEN open := FALSE; choose := NIL; Close^; DecCount END END Close;
		PROCEDURE Handle*(VAR message: WMMessages.Message);
		BEGIN
			IF (message.msgType = WMMessages.MsgExt) & (message.ext # NIL) & (message.ext IS Killer) THEN Close
			ELSE Handle^(message) END
		END Handle;
	END Window;

VAR windows: SIGNED32;
PROCEDURE IncCount;
BEGIN {EXCLUSIVE} INC(windows) END IncCount;
PROCEDURE DecCount;
BEGIN {EXCLUSIVE} DEC(windows) END DecCount;
PROCEDURE Cleanup;
VAR message: WMMessages.Message; killer: Killer; manager: WMWindowManager.WindowManager;
BEGIN {EXCLUSIVE}
	NEW(killer); message.ext := killer; message.msgType := WMMessages.MsgExt;
	manager := WMWindowManager.GetDefaultManager(); manager.Broadcast(message); AWAIT(windows = 0)
END Cleanup;
BEGIN Modules.InstallTermHandler(Cleanup)
END WMRadioStations.
