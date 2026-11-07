MODULE WMRadioGlobe; (** A2 globe prototype based on David Leimbach's 9front radioglobe. *)

IMPORT Math64, Raster, WMGraphics, WMRectangles, WMWindowManager, Strings;

CONST
	Width = 600; Height = 500;
	CenterX = Width DIV 2; CenterY = 238;
	MinRadius = 80; MaxRadius = 230;
	LutSize = 8192;

VAR
	asinLut, atanLut: ARRAY LutSize + 1 OF FLOAT64;

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
	GlobeWindow = OBJECT (WMWindowManager.DoubleBufferWindow)
	VAR
		texture: Raster.Image;
		latitude, longitude: FLOAT64;
		radius, oldX, oldY: SIZE;
		dragging: BOOLEAN;

		PROCEDURE &New*;
		BEGIN
			Init(Width, Height, TRUE);
			WMWindowManager.AddWindow(SELF, 80, 80);
			SetTitle(Strings.NewString("RadioGlobe - Earth preview"));
			texture := WMGraphics.LoadImage("RadioGlobeEarth.png", TRUE);
			latitude := Math64.deg2rad(20); longitude := 0;
			radius := 205;
			Render(FALSE)
		END New;

		PROCEDURE Render(coarse: BOOLEAN);
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
			Swap;
			Invalidate(WMRectangles.MakeRect(0, 0, Width, Height))
		END Render;

		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		BEGIN oldX := x; oldY := y; dragging := FALSE END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		BEGIN
			IF 0 IN keys THEN
				dragging := TRUE;
				longitude := longitude + (oldX - x) / radius;
				latitude := MAX(-1.4, MIN(1.4, latitude + (y - oldY) / radius));
				Render(TRUE)
			END;
			oldX := x; oldY := y
		END PointerMove;

		PROCEDURE PointerUp*(x, y: SIZE; keys: SET);
		BEGIN
			IF dragging & ~(0 IN keys) THEN dragging := FALSE; Render(FALSE) END
		END PointerUp;

		PROCEDURE WheelMove*(dz: SIZE);
		BEGIN
			radius := MAX(MinRadius, MIN(MaxRadius, radius + dz * 15));
			Render(FALSE)
		END WheelMove;
	END GlobeWindow;

PROCEDURE Open*;
VAR window: GlobeWindow;
BEGIN NEW(window) END Open;

BEGIN
	InitTables
END WMRadioGlobe.
