MODULE WMRadioGlobe; (** A2 globe prototype based on David Leimbach's 9front radioglobe. *)

IMPORT Math64, Raster, WMGraphics, WMRectangles, WMWindowManager, Strings, Kernel, Modules, WMMessages;

CONST
	Width = 600; Height = 500;
	CenterX = Width DIV 2; CenterY = 238;
	MinRadius = 80; MaxRadius = 230;
	LutSize = 8192;
	FrameMs = 25;
	MinVelocity = 0.00000872664626; (* 0.0005 degrees/ms, as in libview/orbit.c *)

VAR
	asinLut, atanLut: ARRAY LutSize + 1 OF FLOAT64;
	nofWindows: SIGNED32;

PROCEDURE FastArcSin(x: FLOAT64): FLOAT64;
VAR index: SIGNED32;
BEGIN
	index := ENTIER((x + 1) * (LutSize DIV 2) + 0.5);
	RETURN asinLut[MAX(0, MIN(LutSize, index))]
END FastArcSin;

PROCEDURE FastArcTan2(y, x: FLOAT64): FLOAT64;
VAR ax, ay, angle: FLOAT64; index: SIGNED32;
BEGIN
	ax := ABS(x); ay := ABS(y);
	IF ax >= ay THEN
		IF ax = 0 THEN RETURN 0 END;
		index := ENTIER(ay / ax * LutSize + 0.5);
		angle := atanLut[MIN(LutSize, index)]
	ELSE
		index := ENTIER(ax / ay * LutSize + 0.5);
		angle := Math64.pi / 2 - atanLut[MIN(LutSize, index)]
	END;
	IF x < 0 THEN
		IF y < 0 THEN angle := angle - Math64.pi ELSE angle := Math64.pi - angle END
	ELSIF y < 0 THEN angle := -angle
	END;
	RETURN angle
END FastArcTan2;

PROCEDURE InitTables;
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO LutSize DO
		asinLut[i] := Math64.arcsin(i / (LutSize DIV 2) - 1);
		atanLut[i] := Math64.arctan(i / LutSize)
	END
END InitTables;

TYPE
	KillerMsg = OBJECT END KillerMsg;

	Orbit = OBJECT
	VAR
		latitude, longitude, velocityLat, velocityLon: FLOAT64;
		radius, oldX, oldY: SIZE;
		dragging, dirty, alive: BOOLEAN;
		lastMove, lastStep: SIGNED32;

		PROCEDURE &New;
		BEGIN
			latitude := Math64.deg2rad(20); radius := 205;
			alive := TRUE; dirty := TRUE; lastStep := Kernel.GetTicks()
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
		VAR now, dt: SIGNED32; dx, dy, oldLat: FLOAT64;
		BEGIN {EXCLUSIVE}
			IF dragging & (0 IN keys) THEN
				now := Kernel.GetTicks(); dt := now - lastMove;
				dx := (oldX - x) / radius; dy := (y - oldY) / radius;
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
		BEGIN {EXCLUSIVE}
			radius := MAX(MinRadius, MIN(MaxRadius, radius + dz * 15)); dirty := TRUE
		END WheelMove;

		(* Only the active body renders. Input handlers update state, and this
		   snapshot releases the monitor before drawing or swapping buffers. *)
		PROCEDURE NextFrame(VAR lat, lon: FLOAT64; VAR rad: SIZE; VAR coarse: BOOLEAN): BOOLEAN;
		VAR now: SIGNED32; elapsed, step, friction: FLOAT64;
		BEGIN {EXCLUSIVE}
			AWAIT(~alive OR dirty OR (~dragging & ((velocityLat # 0) OR (velocityLon # 0))));
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
			coarse := dragging OR (velocityLat # 0) OR (velocityLon # 0);
			dirty := FALSE; RETURN TRUE
		END NextFrame;


		PROCEDURE Stop;
		BEGIN {EXCLUSIVE} alive := FALSE END Stop;
	END Orbit;

	GlobeWindow = OBJECT (WMWindowManager.DoubleBufferWindow)
	VAR
		texture: Raster.Image;
		orbit: Orbit;
		timer: Kernel.Timer;

		PROCEDURE &New*;
		BEGIN
			Init(Width, Height, TRUE);
			useAlpha := FALSE; (* BGRA buffers, but every pixel is opaque: copy instead of blending. *)
			NEW(orbit); NEW(timer); IncCount;
			WMWindowManager.AddWindow(SELF, 80, 80);
			SetTitle(Strings.NewString("RadioGlobe - Earth preview"));
			texture := WMGraphics.LoadImage("RadioGlobeEarth.png", TRUE)
		END New;

		PROCEDURE Render(latitude, longitude: FLOAT64; radius: SIZE; coarse: BOOLEAN);
		VAR x, y, u, v, source, target, stride: SIZE;
			b, g, r: CHAR;
			sx, sy, sz, rr, cLat, sLat, cLon, sLon, px, py, pz, lat, lon, light: FLOAT64;
		BEGIN
			canvas.Fill(WMRectangles.MakeRect(0, 0, Width, Height), 0001024FFH, WMGraphics.ModeCopy);
			IF texture = NIL THEN
				canvas.DrawString(20, 35, "RadioGlobeEarth.png is missing");
				Swap; Invalidate(WMRectangles.MakeRect(0, 0, Width, Height)); RETURN
			END;
			ASSERT(texture.fmt.code = Raster.bgra8888);
			ASSERT(backImg.fmt.code = Raster.bgra8888);
			stride := 1; IF coarse THEN stride := 2 END;
			cLat := Math64.cos(latitude); sLat := Math64.sin(latitude);
			cLon := Math64.cos(longitude); sLon := Math64.sin(longitude);
			y := CenterY - radius;
			WHILE y <= CenterY + radius DO
				sy := (CenterY - y) / radius;
				x := CenterX - radius;
				WHILE x <= CenterX + radius DO
					sx := (x - CenterX) / radius;
					rr := sx * sx + sy * sy;
					IF rr <= 1 THEN
						sz := Math64.sqrt(1 - rr);
						px := -sLon * sx - sLat * cLon * sy + cLat * cLon * sz;
						py := cLon * sx - sLat * sLon * sy + cLat * sLon * sz;
						pz := cLat * sy + sLat * sz;
						pz := MAX(-1.0, MIN(1.0, pz));
						lat := FastArcSin(pz); lon := FastArcTan2(py, px);
						u := ENTIER((lon / (2 * Math64.pi) + 0.5) * texture.width);
						v := ENTIER((0.5 - lat / Math64.pi) * texture.height);
						IF u < 0 THEN u := 0 ELSIF u >= texture.width THEN u := texture.width - 1 END;
						IF v < 0 THEN v := 0 ELSIF v >= texture.height THEN v := texture.height - 1 END;
						light := 0.30 + 0.70 * MAX(0.0, -0.35 * sx + 0.45 * sy + 0.82 * sz);
						source := v * texture.bpr + u * 4;
						target := y * backImg.bpr + x * 4;
						b := CHR(ENTIER(ORD(texture.mem[source]) * light));
						g := CHR(ENTIER(ORD(texture.mem[source + 1]) * light));
						r := CHR(ENTIER(ORD(texture.mem[source + 2]) * light));
						backImg.mem[target] := b; backImg.mem[target + 1] := g;
						backImg.mem[target + 2] := r; backImg.mem[target + 3] := 0FFX;
						IF coarse THEN
							backImg.mem[target + 4] := b; backImg.mem[target + 5] := g;
							backImg.mem[target + 6] := r; backImg.mem[target + 7] := 0FFX;
							target := target + backImg.bpr;
							backImg.mem[target] := b; backImg.mem[target + 1] := g;
							backImg.mem[target + 2] := r; backImg.mem[target + 3] := 0FFX;
							backImg.mem[target + 4] := b; backImg.mem[target + 5] := g;
							backImg.mem[target + 6] := r; backImg.mem[target + 7] := 0FFX
						END
					END;
					INC(x, stride)
				END;
				INC(y, stride)
			END;
			canvas.SetColor(WMGraphics.White);
			canvas.DrawString(16, 482, "Drag to rotate  |  wheel to zoom  |  globe preview (no audio yet)");
			(* Desktop zoom otherwise bilinearly filters every enlarged motion frame. *)
			HintReduceQuality(coarse);
			Swap;
			Invalidate(WMRectangles.MakeRect(0, 0, Width, Height))
		END Render;


		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		BEGIN orbit.PointerDown(x, y, keys) END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		BEGIN orbit.PointerMove(x, y, keys) END PointerMove;

		PROCEDURE PointerUp*(x, y: SIZE; keys: SET);
		BEGIN orbit.PointerUp(x, y, keys) END PointerUp;

		PROCEDURE WheelMove*(dz: SIZE);
		BEGIN orbit.WheelMove(dz) END WheelMove;

		PROCEDURE Animate;
		VAR lat, lon: FLOAT64; rad: SIZE; coarse: BOOLEAN; started, delay: SIGNED32;
		BEGIN
			WHILE orbit.NextFrame(lat, lon, rad, coarse) DO
				started := Kernel.GetTicks(); Render(lat, lon, rad, coarse);
				delay := FrameMs - (Kernel.GetTicks() - started);
				IF delay > 0 THEN timer.Sleep(delay) END
			END
		END Animate;

		PROCEDURE Close*;
		BEGIN
			(* Do not join the renderer while the UI sequencer holds its lock.
			   The active body removes the window after its last frame. *)
			orbit.Stop
		END Close;

		PROCEDURE Handle*(VAR msg: WMMessages.Message);
		BEGIN
			IF (msg.msgType = WMMessages.MsgExt) & (msg.ext # NIL) & (msg.ext IS KillerMsg) THEN Close
			ELSE Handle^(msg) END
		END Handle;

	BEGIN {ACTIVE}
		Animate;
	FINALLY
		Close^; DecCount
	END GlobeWindow;

PROCEDURE IncCount;
BEGIN {EXCLUSIVE} INC(nofWindows) END IncCount;

PROCEDURE DecCount;
BEGIN {EXCLUSIVE} DEC(nofWindows) END DecCount;

PROCEDURE Cleanup;
VAR msg: WMMessages.Message; killer: KillerMsg; manager: WMWindowManager.WindowManager;
BEGIN {EXCLUSIVE}
	NEW(killer); msg.ext := killer; msg.msgType := WMMessages.MsgExt;
	manager := WMWindowManager.GetDefaultManager();
	manager.Broadcast(msg); AWAIT(nofWindows = 0)
END Cleanup;

PROCEDURE Open*;
VAR window: GlobeWindow;
BEGIN NEW(window) END Open;

BEGIN
	InitTables; Modules.InstallTermHandler(Cleanup)
END WMRadioGlobe.
