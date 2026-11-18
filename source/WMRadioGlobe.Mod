MODULE WMRadioGlobe; (** Interactive radio globe based on David Leimbach's 9front radioglobe. *)

IMPORT Math64, Raster, WMGraphics, WMRectangles, WMWindowManager, Strings, Kernel, Modules, WMMessages, Commands, Files,
	RadioGlobeTexture, RadioStations, RadioGlobeAudio, WMRadioStations, WMGraphicUtilities, KernelLog, ServiceActivities;

CONST
	Width = 900; Height = 800;
	MinRadius = 80; MaxRadius = 8192;
	FrameMs = 25; ZoomSettleMs = 150;
	MinVelocity = 0.00000872664626; (* 0.0005 degrees/ms, as in libview/orbit.c *)

VAR
	nofWindows, nofWatchers: SIGNED32;

TYPE
	KillerMsg = OBJECT END KillerMsg;

	Orbit = OBJECT
	VAR
		latitude, longitude, velocityLat, velocityLon: FLOAT64;
		radius, oldX, oldY, viewWidth, viewHeight: SIZE;
		dragging, dirty, alive, zooming: BOOLEAN;
		zoomDeadline: Kernel.MilliTimer;
		lastMove, lastStep: SIGNED32;
		selection: SIZE;

		PROCEDURE &New;
		BEGIN
			latitude := Math64.deg2rad(20); radius := 205;
			viewWidth := Width; viewHeight := Height;
			alive := TRUE; dirty := TRUE; selection := -1; lastStep := Kernel.GetTicks()
		END New;

		PROCEDURE Normalize;
		BEGIN
			WHILE longitude > Math64.pi DO longitude := longitude - 2 * Math64.pi END;
			WHILE longitude < -Math64.pi DO longitude := longitude + 2 * Math64.pi END;
			IF latitude > Math64.pi / 2 THEN latitude := Math64.pi / 2; velocityLat := 0 END;
			IF latitude < -Math64.pi / 2 THEN latitude := -Math64.pi / 2; velocityLat := 0 END
		END Normalize;

		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		BEGIN {EXCLUSIVE}
			IF 0 IN keys THEN
				oldX := x; oldY := y; dragging := TRUE;
				velocityLat := 0; velocityLon := 0;
				lastMove := Kernel.GetTicks(); dirty := TRUE
			END
		END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		VAR now, dt: SIGNED32; dx, dy, oldLat, scale: FLOAT64;
		BEGIN {EXCLUSIVE}
			IF dragging & (0 IN keys) THEN
				now := Kernel.GetTicks(); dt := now - lastMove;
				scale := MIN(viewWidth / Width, viewHeight / Height);
				dx := (oldX - x) / (radius * scale); dy := (y - oldY) / (radius * scale);
				oldLat := latitude;
				longitude := longitude + dx; latitude := latitude + dy;
				Normalize;
				IF dt > 0 THEN
					velocityLon := dx / dt; velocityLat := (latitude - oldLat) / dt;
					lastMove := now
				END;
				oldX := x; oldY := y; dirty := TRUE
			END
		END PointerMove;

		PROCEDURE PointerUp*(x, y: SIZE; keys: SET);
		BEGIN {EXCLUSIVE}
			IF dragging & ~(0 IN keys) THEN
				dragging := FALSE; lastStep := Kernel.GetTicks();
				dirty := TRUE
			END
		END PointerUp;

		PROCEDURE WheelMove*(dz: SIZE);
		VAR next: SIZE;
		BEGIN {EXCLUSIVE}
			next := MAX(MinRadius, MIN(MaxRadius, radius + dz * MAX(15, radius DIV 10)));
			IF next # radius THEN
				radius := next; dirty := TRUE; zooming := TRUE;
				Kernel.SetTimer(zoomDeadline, ZoomSettleMs)
			END
		END WheelMove;

		PROCEDURE Resize(width, height: SIZE);
		BEGIN {EXCLUSIVE}
			viewWidth := width; viewHeight := height; dirty := TRUE
		END Resize;

		PROCEDURE Refresh;
		BEGIN {EXCLUSIVE} dirty := TRUE END Refresh;
		PROCEDURE Select(index: SIZE);
		BEGIN {EXCLUSIVE} IF selection # index THEN selection := index; dirty := TRUE END END Select;
		PROCEDURE Selected(): SIZE;
		BEGIN {EXCLUSIVE} RETURN selection END Selected;
		PROCEDURE Center(station: RadioStations.Station; index: SIZE);
		BEGIN {EXCLUSIVE}
			latitude := Math64.deg2rad(station.latitude); longitude := Math64.deg2rad(station.longitude);
			velocityLat := 0; velocityLon := 0; dragging := FALSE; selection := index; dirty := TRUE
		END Center;
		PROCEDURE View(VAR view: RadioStations.View; VAR width, height: SIZE);
		BEGIN {EXCLUSIVE}
			width := viewWidth; height := viewHeight;
			RadioStations.MakeView(latitude, longitude, MAX(1, ENTIER(radius * MIN(width / Width, height / Height))), width, height, view)
		END View;

		PROCEDURE RadioControl(x, y: SIZE; keys: SET): SIGNED32;
		BEGIN {EXCLUSIVE}
			IF (0 IN keys) & (y >= viewHeight - 34) & (y < viewHeight - 6) THEN
				IF (x >= 16) & (x < 116) THEN RETURN 1 END;
				IF (x >= 124) & (x < MIN(184, viewWidth)) THEN RETURN 2 END;
				IF (x >= 192) & (x < MIN(280, viewWidth)) THEN RETURN 3 END;
				IF (x >= 288) & (x < MIN(330, viewWidth)) THEN RETURN 4 END;
				IF (x >= 338) & (x < MIN(380, viewWidth)) THEN RETURN 5 END
			END;
			RETURN 0
		END RadioControl;

		(* While the wheel is quiet, wait for the detail pass without drawing
		   duplicate previews. Check for fresh input at the normal frame cadence. *)
		PROCEDURE DetailDelay(): SIGNED32;
		BEGIN {EXCLUSIVE}
			IF alive & zooming & ~dirty & (dragging OR ((velocityLat = 0) & (velocityLon = 0))) THEN
				RETURN MAX(0, MIN(FrameMs, Kernel.Left(zoomDeadline)))
			END;
			RETURN 0
		END DetailDelay;

		(* Only the active body renders. Input handlers update state, and this
		   snapshot releases the monitor before drawing or swapping buffers. *)
		PROCEDURE NextFrame(VAR lat, lon: FLOAT64; VAR rad, width, height, selected: SIZE; VAR coarse: BOOLEAN): BOOLEAN;
		VAR now: SIGNED32; elapsed, step, friction: FLOAT64;
		BEGIN {EXCLUSIVE}
			AWAIT(~alive OR dirty OR zooming OR (~dragging & ((velocityLat # 0) OR (velocityLon # 0))));
			IF ~alive THEN RETURN FALSE END;
			now := Kernel.GetTicks(); elapsed := MAX(0, now - lastStep); lastStep := now;
			IF ~dragging THEN
				(* Match libview's time-based 0.92 decay per nominal 25ms tick. *)
				WHILE (elapsed > 0) & ((velocityLat # 0) OR (velocityLon # 0)) DO
					step := MIN(FrameMs, elapsed);
					longitude := longitude + velocityLon * step; latitude := latitude + velocityLat * step;
					Normalize;
					friction := Math64.exp(Math64.ln(0.92) * step / FrameMs);
					velocityLon := velocityLon * friction; velocityLat := velocityLat * friction;
					IF (ABS(velocityLon) < MinVelocity) & (ABS(velocityLat) < MinVelocity) THEN
						velocityLon := 0; velocityLat := 0
					END;
					elapsed := elapsed - step
				END
			END;
			lat := latitude; lon := longitude; rad := radius;
			width := viewWidth; height := viewHeight;
			selected := selection;
			IF zooming & Kernel.Expired(zoomDeadline) THEN zooming := FALSE END;
			coarse := zooming OR dragging OR (velocityLat # 0) OR (velocityLon # 0);
			dirty := FALSE; RETURN TRUE
		END NextFrame;


		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} alive := FALSE END Stop;
	END Orbit;

	StatusWatcher = OBJECT(ServiceActivities.DetachedObject)
	VAR orbit: Orbit; alive: BOOLEAN; previous, text: ARRAY 1024 OF CHAR; timer: Kernel.Timer;
		PROCEDURE &Init*(o: Orbit);
		BEGIN orbit := o; alive := TRUE; NEW(timer); IncWatcher END Init;
		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} alive := FALSE END Stop;
		PROCEDURE Alive(): BOOLEAN;
		BEGIN {EXCLUSIVE} RETURN alive END Alive;
	BEGIN {ACTIVE}
		WHILE Alive() DO
			RadioGlobeAudio.GetStatus(text);
			IF text # previous THEN previous := text; orbit.Refresh END;
			timer.Sleep(300)
		END
	FINALLY
		DecWatcher
	END StatusWatcher;

	Frame = RECORD
		texture, backImg: Raster.Image;
		cx, cy, radius, width, height, left, right, stride: SIZE;
		cLat, sLat, cLon, sLon: FLOAT64
	END;

	(* A band starts on a sample row, so the two rows of a motion sample
	   always belong to the same activity. Only the window swaps buffers. *)
	BandWorker = OBJECT
	VAR frame: Frame; first, limit: SIZE; pending, stopping, stopped: BOOLEAN;
		PROCEDURE Start(CONST next: Frame; first, limit: SIZE);
		BEGIN {EXCLUSIVE}
			frame := next; SELF.first := first; SELF.limit := limit; pending := TRUE
		END Start;
		PROCEDURE Wait;
		BEGIN {EXCLUSIVE} AWAIT(~pending) END Wait;
		PROCEDURE Ready(): BOOLEAN;
		BEGIN {EXCLUSIVE} AWAIT(pending OR stopping); RETURN pending END Ready;
		PROCEDURE Complete;
		BEGIN {EXCLUSIVE} pending := FALSE END Complete;
		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} stopping := TRUE; AWAIT(stopped) END Stop;
		PROCEDURE Finished;
		BEGIN {EXCLUSIVE} stopped := TRUE END Finished;
	BEGIN {ACTIVE}
		WHILE Ready() DO DrawBand(frame, first, limit); Complete END;
		Finished
	END BandWorker;

	GlobeWindow = OBJECT (WMWindowManager.DoubleBufferWindow)
	VAR
		texture: Raster.Image;
		orbit: Orbit;
		workers: ARRAY 3 OF BandWorker;
		timer: Kernel.Timer;
		ownsPlayback: BOOLEAN;
		catalogue: RadioStations.Catalogue; browser: WMRadioStations.Window; watcher: StatusWatcher;
		lastRadius, lastWidth, lastHeight, lastSelected: SIZE;
		lastStatus: ARRAY 1024 OF CHAR;
		seen: ARRAY 342, 342 OF BOOLEAN;
		downX, downY: SIZE; downTime: SIGNED32; clicking: BOOLEAN;

		PROCEDURE &New*(CONST filename: ARRAY OF CHAR);
		VAR i: SIZE;
		BEGIN
			Init(Width, Height, TRUE);
			useAlpha := FALSE; (* BGRA buffers, but every pixel is opaque: copy instead of blending. *)
			NEW(orbit); NEW(timer); IncCount;
			FOR i := 0 TO LEN(workers)-1 DO NEW(workers[i]) END;
			NEW(catalogue, filename); NEW(watcher, orbit);
			WMWindowManager.AddWindow(SELF, 80, 80);
			SetTitle(Strings.NewString("RadioGlobe"));
			texture := WMGraphics.LoadImage("RadioGlobeEarth.png", TRUE)
		END New;

		PROCEDURE Render(latitude, longitude: FLOAT64; radius, width, height, selected: SIZE; coarse: BOOLEAN);
		VAR frame: Frame; cx, cy, i, rows, first, limit, next, bandStart, extent: SIZE;
			headerChanged: BOOLEAN;
		BEGIN
			IF (backImg.width # width) OR (backImg.height # height) THEN ReInit(width, height) END;
			cx := width DIV 2; cy := height DIV 2 - 12;
			radius := MAX(1, ENTIER(radius * MIN(width / Width, height / Height)));
			canvas.Fill(WMRectangles.MakeRect(0, 0, width, height), 0001024FFH, WMGraphics.ModeCopy);
			IF texture = NIL THEN
				canvas.DrawString(20, 35, "RadioGlobeEarth.png is missing");
				Swap; Invalidate(WMRectangles.MakeRect(0, 0, width, height)); RETURN
			END;
			ASSERT(texture.fmt.code = Raster.bgra8888);
			ASSERT(backImg.fmt.code = Raster.bgra8888);
			frame.texture := texture; frame.backImg := backImg;
			frame.cx := cx; frame.cy := cy; frame.width := width; frame.height := height;
			frame.radius := radius; frame.stride := 1; IF coarse THEN frame.stride := 2 END;
			frame.cLat := Math64.cos(latitude); frame.sLat := Math64.sin(latitude);
			frame.cLon := Math64.cos(longitude); frame.sLon := Math64.sin(longitude);
			frame.left := MAX(0, cx - radius); frame.right := MIN(width - 1, cx + radius);
			first := MAX(0, cy - radius); limit := MIN(height, cy + radius + 1);
			rows := (limit - first + frame.stride - 1) DIV frame.stride;
			bandStart := first;
			FOR i := 0 TO LEN(workers)-1 DO
				next := first + (rows * (i + 1) DIV (LEN(workers) + 1)) * frame.stride;
				workers[i].Start(frame, bandStart, next); bandStart := next
			END;
			DrawBand(frame, bandStart, limit);
			FOR i := 0 TO LEN(workers)-1 DO workers[i].Wait END;
			canvas.SetColor(WMGraphics.White);
			DrawStations(latitude, longitude, radius, width, height, selected, headerChanged);
			canvas.Fill(WMRectangles.MakeRect(16, height - 34, 116, height - 6), 303060FFH, WMGraphics.ModeCopy);
			canvas.Fill(WMRectangles.MakeRect(124, height - 34, 184, height - 6), 303060FFH, WMGraphics.ModeCopy);
			canvas.Fill(WMRectangles.MakeRect(192, height - 34, 280, height - 6), 303060FFH, WMGraphics.ModeCopy);
			canvas.Fill(WMRectangles.MakeRect(288, height - 34, 330, height - 6), 303060FFH, WMGraphics.ModeCopy);
			canvas.Fill(WMRectangles.MakeRect(338, height - 34, 380, height - 6), 303060FFH, WMGraphics.ModeCopy);
			canvas.DrawString(24, height - 15, "Play radio");
			canvas.DrawString(132, height - 15, "Stop");
			canvas.DrawString(200, height - 15, "Stations");
			canvas.DrawString(292, height - 15, "Prev"); canvas.DrawString(342, height - 15, "Next");
			canvas.DrawString(390, height - 15, "Drag / wheel zoom");
			(* Desktop zoom otherwise bilinearly filters every enlarged motion frame. *)
			HintReduceQuality(coarse);
			Swap;
			IF (lastWidth # width) OR (lastHeight # height) THEN
				Invalidate(WMRectangles.MakeRect(0, 0, width, height))
			ELSE
				(* Cover the previous limb on zoom-out and the selected station ring. *)
				extent := MAX(radius, lastRadius) + 6;
				Invalidate(WMRectangles.MakeRect(MAX(0, cx - extent), MAX(0, cy - extent),
					MIN(width, cx + extent + 1), MIN(height, cy + extent + 1)));
				IF headerChanged THEN Invalidate(WMRectangles.MakeRect(0, 0, width, 46)) END
			END;
			lastWidth := width; lastHeight := height; lastRadius := radius; lastSelected := selected
		END Render;

		PROCEDURE DrawStations(latitude, longitude: FLOAT64; radius, width, height, selected: SIZE; VAR headerChanged: BOOLEAN);
		VAR view: RadioStations.View; i, x, y, xx, yy, dot: SIZE; depth: FLOAT64;
			text: ARRAY 1024 OF CHAR; station: RadioStations.Station;
		BEGIN
			headerChanged := FALSE;
			RadioStations.MakeView(latitude, longitude, radius, width, height, view);
			FOR yy := 0 TO height DIV 6 DO FOR xx := 0 TO width DIV 6 DO seen[xx, yy] := FALSE END END;
			FOR i := 0 TO catalogue.count - 1 DO
				IF RadioStations.Project(catalogue.items[i], view, x, y, depth) &
					(x >= 0) & (x < width) & (y >= 48) & (y < height - 38) THEN
					IF ~seen[x DIV 6, y DIV 6] THEN
						seen[x DIV 6, y DIV 6] := TRUE; dot := 2; IF depth < 0.2 THEN dot := 1 END;
						WMGraphicUtilities.DrawEllipse(canvas, x, y, dot, dot, SIGNED32(0FFD050FFH), SIGNED32(0FFD050FFH), WMGraphics.ModeCopy)
					END
				END
			END;
			IF (selected >= 0) & (selected < catalogue.count) THEN
				station := catalogue.items[selected];
				IF RadioStations.Project(station, view, x, y, depth) & (x >= 0) & (x < width) & (y >= 48) & (y < height - 38) THEN
					WMGraphicUtilities.DrawEllipse(canvas, x, y, 5, 5, WMGraphics.White, 00FF80FFH, WMGraphics.ModeCopy)
				END
			END;
			IF catalogue.count > 0 THEN
				canvas.Fill(WMRectangles.MakeRect(0, 0, width, 46), 000000FFH, WMGraphics.ModeCopy); canvas.SetColor(WMGraphics.White);
				IF (selected >= 0) & (selected < catalogue.count) THEN
					COPY(catalogue.items[selected].name^, text)
				ELSE
					Strings.IntToStr(catalogue.count, text); Strings.AppendX(text, " stations | Hover a marker, click to play; Stations to search")
				END;
				canvas.DrawString(12, 18, text); RadioGlobeAudio.GetStatus(text); canvas.DrawString(12, 38, text);
				headerChanged := (selected # lastSelected) OR (text # lastStatus); lastStatus := text
			END
		END DrawStations;

		PROCEDURE Pick(x, y: SIZE): SIZE;
		VAR view: RadioStations.View; width, height: SIZE;
		BEGIN
			orbit.View(view, width, height);
			IF (x < 0) OR (x >= width) OR (y < 48) OR (y >= height - 38) THEN RETURN -1 END;
			RETURN catalogue.Hit(view, x, y, orbit.Selected())
		END Pick;

		PROCEDURE StartStation(index: SIZE);
		BEGIN
			IF (index >= 0) & (index < catalogue.count) THEN
				orbit.Select(index); ownsPlayback := TRUE;
				KernelLog.String("Radio station selected: "); KernelLog.String(catalogue.items[index].name^); KernelLog.Ln;
				RadioGlobeAudio.RequestPlay(catalogue.items[index].name^, catalogue.items[index].url^)
			END
		END StartStation;

		PROCEDURE SelectStation(station: RadioStations.Station);
		VAR i: SIZE;
		BEGIN
			FOR i := 0 TO catalogue.count - 1 DO
				IF catalogue.items[i] = station THEN orbit.Center(station, i); StartStation(i); RETURN END
			END
		END SelectStation;

		PROCEDURE Browse;
		BEGIN IF (browser = NIL) OR ~browser.IsOpen() THEN NEW(browser, catalogue, SelectStation) END END Browse;

		PROCEDURE StepStation(delta: SIZE);
		VAR index: SIZE;
		BEGIN
			IF catalogue.count = 0 THEN RETURN END;
			index := orbit.Selected();
			IF index < 0 THEN IF delta > 0 THEN index := 0 ELSE index := catalogue.count - 1 END
			ELSE index := (index + delta + catalogue.count) MOD catalogue.count END;
			orbit.Center(catalogue.items[index], index);
			IF ownsPlayback THEN StartStation(index) END
		END StepStation;


		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		VAR action: SIGNED32; index: SIZE;
		BEGIN
			action := orbit.RadioControl(x, y, keys);
			clicking := FALSE;
			IF action = 1 THEN
				index := orbit.Selected();
				IF index >= 0 THEN StartStation(index) ELSE PlayRadio; ownsPlayback := TRUE END
			ELSIF action = 2 THEN RadioGlobeAudio.RequestStop; ownsPlayback := FALSE
			ELSIF action = 3 THEN Browse
			ELSIF action = 4 THEN StepStation(-1)
			ELSIF action = 5 THEN StepStation(1)
			ELSIF 1 IN keys THEN index := Pick(x, y); IF index >= 0 THEN StartStation(index) END
			ELSIF 2 IN keys THEN Browse
			ELSE
				IF 0 IN keys THEN downX := x; downY := y; downTime := Kernel.GetTicks(); clicking := TRUE END;
				orbit.PointerDown(x, y, keys)
			END
		END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		VAR index: SIZE;
		BEGIN
			IF (ABS(x - downX) > 5) OR (ABS(y - downY) > 5) THEN clicking := FALSE END;
			orbit.PointerMove(x, y, keys);
			IF keys = {} THEN index := Pick(x, y); IF index >= 0 THEN orbit.Select(index) END END
		END PointerMove;

		PROCEDURE PointerUp*(x, y: SIZE; keys: SET);
		VAR index: SIZE;
		BEGIN
			orbit.PointerUp(x, y, keys);
			IF clicking & (Kernel.GetTicks() - downTime < 350) & (ABS(x - downX) <= 5) & (ABS(y - downY) <= 5) THEN
				index := Pick(x, y); IF index >= 0 THEN StartStation(index) END
			END;
			clicking := FALSE
		END PointerUp;

		PROCEDURE WheelMove*(dz: SIZE);
		BEGIN orbit.WheelMove(dz) END WheelMove;

		PROCEDURE Resizing*(VAR width, height: SIZE);
		BEGIN
			Resizing^(width, height);
			width := MAX(160, MIN(2048, width)); height := MAX(120, MIN(2048, height))
		END Resizing;

		PROCEDURE Resized*(width, height: SIZE);
		BEGIN
			(* Reallocation belongs to the renderer, never the input sequencer. *)
			IF (width > 0) & (height > 0) & (width <= 2048) & (height <= 2048) THEN
				orbit.Resize(width, height)
			END
		END Resized;

		PROCEDURE Animate;
		VAR lat, lon: FLOAT64; rad, width, height, selected: SIZE; coarse: BOOLEAN; started, delay: SIGNED32;
		BEGIN
			WHILE orbit.NextFrame(lat, lon, rad, width, height, selected, coarse) DO
				started := Kernel.GetTicks(); Render(lat, lon, rad, width, height, selected, coarse);
				delay := FrameMs - (Kernel.GetTicks() - started);
				IF delay > 0 THEN timer.Sleep(delay) END;
				delay := orbit.DetailDelay();
				WHILE delay > 0 DO timer.Sleep(delay); delay := orbit.DetailDelay() END
			END
		END Animate;

		PROCEDURE StopWorkers;
		VAR i: SIZE;
		BEGIN FOR i := 0 TO LEN(workers)-1 DO workers[i].Stop END END StopWorkers;

		PROCEDURE Close*;
		BEGIN
			(* Do not join the renderer while the UI sequencer holds its lock.
			   The active body removes the window after its last frame. *)
			orbit.Stop;
			watcher.Stop;
			IF browser # NIL THEN browser.Close; browser := NIL END;
			IF ownsPlayback THEN RadioGlobeAudio.RequestStop; ownsPlayback := FALSE END
		END Close;

		PROCEDURE Handle*(VAR msg: WMMessages.Message);
		BEGIN
			IF (msg.msgType = WMMessages.MsgExt) & (msg.ext # NIL) & (msg.ext IS KillerMsg) THEN Close
			ELSE Handle^(msg) END
		END Handle;

	BEGIN {ACTIVE}
		Animate;
	FINALLY
		StopWorkers;
		Close^; DecCount
	END GlobeWindow;

PROCEDURE DrawBand(CONST frame: Frame; y, limit: SIZE);
VAR x, target, xx, yy: SIZE; backImg, texture: Raster.Image;
	b, g, r: CHAR; blue, green, red: SIGNED32;
	sx, sy, sz, rr, px, py, pz, lat, lon, light, u, v, cLat, sLat, cLon, sLon: FLOAT64;
	cx, cy, radius, right, width, height, stride: SIZE;
BEGIN
	texture := frame.texture; backImg := frame.backImg; stride := frame.stride;
	cx := frame.cx; cy := frame.cy; radius := frame.radius; right := frame.right;
	width := frame.width; height := frame.height;
	cLat := frame.cLat; sLat := frame.sLat; cLon := frame.cLon; sLon := frame.sLon;
	WHILE y < limit DO
		sy := (cy - y) / radius;
		x := frame.left;
		WHILE x <= right DO
			sx := (x - cx) / radius;
			rr := sx * sx + sy * sy;
			IF rr <= 1 THEN
				sz := Math64.sqrt(1 - rr);
				px := -sLon * sx - sLat * cLon * sy + cLat * cLon * sz;
				py := cLon * sx - sLat * sLon * sy + cLat * sLon * sz;
				pz := cLat * sy + sLat * sz;
				pz := MAX(-1.0, MIN(1.0, pz));
				lat := RadioGlobeTexture.ArcSin(pz); lon := RadioGlobeTexture.ArcTan2(py, px);
				u := (lon / (2 * Math64.pi) + 0.5) * texture.width - 0.5;
				v := (0.5 - lat / Math64.pi) * texture.height - 0.5;
				RadioGlobeTexture.Sample(texture, u, v, blue, green, red);
				light := 0.30 + 0.70 * MAX(0.0, -0.35 * sx + 0.45 * sy + 0.82 * sz);
				target := y * backImg.bpr + x * 4;
				b := CHR(ENTIER(blue * light));
				g := CHR(ENTIER(green * light));
				r := CHR(ENTIER(red * light));
				backImg.mem[target] := b; backImg.mem[target + 1] := g;
				backImg.mem[target + 2] := r; backImg.mem[target + 3] := 0FFX;
				IF stride = 2 THEN
					FOR yy := y TO MIN(y + 1, height - 1) DO
						FOR xx := x TO MIN(x + 1, width - 1) DO
							target := yy * backImg.bpr + xx * 4;
							backImg.mem[target] := b; backImg.mem[target + 1] := g;
							backImg.mem[target + 2] := r; backImg.mem[target + 3] := 0FFX
						END
					END
				END
			END;
			INC(x, stride)
		END;
		INC(y, stride)
	END;
END DrawBand;

PROCEDURE IncCount;
BEGIN {EXCLUSIVE} INC(nofWindows) END IncCount;

PROCEDURE DecCount;
BEGIN {EXCLUSIVE} DEC(nofWindows) END DecCount;

PROCEDURE IncWatcher;
BEGIN {EXCLUSIVE} INC(nofWatchers) END IncWatcher;

PROCEDURE DecWatcher;
BEGIN {EXCLUSIVE} DEC(nofWatchers) END DecWatcher;

PROCEDURE PlayRadio;
VAR file: Files.File; reader: Files.Reader;
	url: ARRAY 8193 OF CHAR;
BEGIN
	url := "https://ice5.somafm.com/groovesalad-128-mp3";
	file := Files.Old("RadioGlobeStation.txt");
	IF file # NIL THEN Files.OpenReader(reader, file, 0); reader.Ln(url) END;
	RadioGlobeAudio.RequestPlay("Custom station", url)
END PlayRadio;

PROCEDURE Cleanup;
VAR msg: WMMessages.Message; killer: KillerMsg; manager: WMWindowManager.WindowManager;
BEGIN {EXCLUSIVE}
	NEW(killer); msg.ext := killer; msg.msgType := WMMessages.MsgExt;
	manager := WMWindowManager.GetDefaultManager();
	manager.Broadcast(msg); AWAIT((nofWindows = 0) & (nofWatchers = 0))
END Cleanup;

PROCEDURE Open*(context: Commands.Context);
VAR window: GlobeWindow; filename: Files.FileName;
BEGIN
	IF ~context.arg.GetString(filename) THEN filename := "RadioGlobeStations.txt" END;
	NEW(window, filename)
END Open;

BEGIN
	Modules.InstallTermHandler(Cleanup)
END WMRadioGlobe.
