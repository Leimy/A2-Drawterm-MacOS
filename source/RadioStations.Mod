MODULE RadioStations;
IMPORT Files, Streams, Strings, RealConversions, Math64, KernelLog;

TYPE
	Station* = OBJECT
	VAR name*, url*: Strings.String; latitude*, longitude*, x*, y*, z*: FLOAT64;
	END Station;
	View* = RECORD cx*, cy*, radius*: SIZE; clat, slat, clon, slon: FLOAT64 END;
	Array* = POINTER TO ARRAY OF Station;
	Catalogue* = OBJECT
	VAR items*: Array; count*, rejected*: SIZE;

		PROCEDURE &Init*(CONST filename: ARRAY OF CHAR);
		VAR file: Files.File; reader: Files.Reader; row: Streams.StringReader;
			line: ARRAY 16384 OF CHAR; lat, lon: ARRAY 64 OF CHAR;
			name: ARRAY 513 OF CHAR; url: ARRAY 8193 OF CHAR;
			latitude, longitude, a, b: FLOAT64; station: Station;
			larger: Array; i: SIZE;
		BEGIN
			NEW(items, 256); file := Files.Old(filename);
			IF file = NIL THEN KernelLog.String("Radio station file not found: "); KernelLog.String(filename); KernelLog.Ln; RETURN END;
			Files.OpenReader(reader, file, 0);
			WHILE reader.res = Streams.Ok DO
				reader.Ln(line); Streams.OpenStringReader(row, line); row.SkipWhitespace;
				IF (row.Peek() # "#") & (row.Peek() # 0X) & (row.res = Streams.Ok) THEN
					IF row.GetString(lat) & row.GetString(lon) & row.GetString(name) & row.GetString(url) &
						RealConversions.StringToReal(lat, latitude) & RealConversions.StringToReal(lon, longitude) &
						~Math64.isnonfinite(latitude) & ~Math64.isnonfinite(longitude) &
						(ABS(latitude) <= 90) & (ABS(longitude) <= 180) & (name # "") &
						((Strings.Pos("http://", url) = 0) OR (Strings.Pos("https://", url) = 0)) & (count < 20000) THEN
						NEW(station); station.name := Strings.NewString(name); station.url := Strings.NewString(url);
						station.latitude := latitude; station.longitude := longitude;
						a := Math64.deg2rad(latitude); b := Math64.deg2rad(longitude);
						station.x := Math64.cos(a) * Math64.cos(b); station.y := Math64.cos(a) * Math64.sin(b); station.z := Math64.sin(a);
						IF count = LEN(items) THEN
							NEW(larger, LEN(items) * 2); FOR i := 0 TO count - 1 DO larger[i] := items[i] END; items := larger
						END;
						items[count] := station; INC(count)
					ELSE INC(rejected)
					END
				END
			END;
			KernelLog.String("Radio stations loaded: "); KernelLog.Int(count, 0);
			KernelLog.String(" rejected: "); KernelLog.Int(rejected, 0); KernelLog.Ln
		END Init;

		PROCEDURE Hit*(CONST view: View; x, y, current: SIZE): SIZE;
		VAR i, px, py, dx, dy, distance, best, bestDistance: SIZE; depth: FLOAT64;
		BEGIN
			IF (current >= 0) & (current < count) & Project(items[current], view, px, py, depth) THEN
				dx := px - x; dy := py - y;
				IF (ABS(dx) <= 6) & (ABS(dy) <= 6) & (dx * dx + dy * dy <= 36) THEN RETURN current END
			END;
			best := -1; bestDistance := 196;
			FOR i := 0 TO count - 1 DO
				IF Project(items[i], view, px, py, depth) THEN
					dx := px - x; dy := py - y;
					IF (ABS(dx) <= 14) & (ABS(dy) <= 14) THEN
						distance := dx * dx + dy * dy;
						IF distance < bestDistance THEN bestDistance := distance; best := i END
					END
				END
			END;
			RETURN best
		END Hit;
	END Catalogue;

PROCEDURE MakeView*(latitude, longitude: FLOAT64; radius, width, height: SIZE; VAR view: View);
BEGIN
	view.cx := width DIV 2; view.cy := height DIV 2 - 12; view.radius := radius;
	view.clat := Math64.cos(latitude); view.slat := Math64.sin(latitude);
	view.clon := Math64.cos(longitude); view.slon := Math64.sin(longitude)
END MakeView;

PROCEDURE Project*(station: Station; CONST view: View; VAR x, y: SIZE; VAR depth: FLOAT64): BOOLEAN;
VAR right, up: FLOAT64;
BEGIN
	depth := view.clat * view.clon * station.x + view.clat * view.slon * station.y + view.slat * station.z;
	IF depth <= 0 THEN RETURN FALSE END;
	right := -view.slon * station.x + view.clon * station.y;
	up := -view.slat * view.clon * station.x - view.slat * view.slon * station.y + view.clat * station.z;
	x := view.cx + ENTIER(right * view.radius); y := view.cy - ENTIER(up * view.radius);
	RETURN TRUE
END Project;

PROCEDURE FormatHint*(station: Station): Strings.String;
VAR text: ARRAY 8706 OF CHAR;
BEGIN
	COPY(station.name^, text); Strings.AppendX(text, " "); Strings.AppendX(text, station.url^); Strings.LowerCase(text);
	IF Strings.Pos(".m3u8", text) >= 0 THEN RETURN Strings.NewString("HLS") END;
	IF (Strings.Pos(".opus", text) >= 0) OR (Strings.Pos(" opus", text) >= 0) THEN RETURN Strings.NewString("Opus") END;
	IF (Strings.Pos(".flac", text) >= 0) OR (Strings.Pos(" flac", text) >= 0) THEN RETURN Strings.NewString("FLAC") END;
	IF (Strings.Pos(".aac", text) >= 0) OR (Strings.Pos(" aac", text) >= 0) OR (Strings.Pos("-aac", text) >= 0) OR (Strings.Pos("/aac", text) >= 0) THEN RETURN Strings.NewString("AAC") END;
	IF (Strings.Pos(".ogg", text) >= 0) OR (Strings.Pos(" ogg", text) >= 0) OR (Strings.Pos("vorbis", text) >= 0) THEN RETURN Strings.NewString("Vorbis/?") END;
	RETURN Strings.NewString("MP3/?")
END FormatHint;

END RadioStations.
