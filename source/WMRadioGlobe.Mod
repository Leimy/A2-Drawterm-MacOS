MODULE WMRadioGlobe; (** A2 globe prototype based on David Leimbach's 9front radioglobe. *)

IMPORT Math64, Raster, WMGraphics, WMRectangles, WMWindowManager, Strings;

CONST
	Width = 600; Height = 500;
	CenterX = Width DIV 2; CenterY = 238;
	MinRadius = 80; MaxRadius = 230;

TYPE
	GlobeWindow = OBJECT (WMWindowManager.BufferWindow)
	VAR
		texture: Raster.Image;
		latitude, longitude: FLOAT64;
		radius, oldX, oldY: SIZE;

		PROCEDURE &New*;
		BEGIN
			Init(Width, Height, FALSE);
			WMWindowManager.AddWindow(SELF, 80, 80);
			SetTitle(Strings.NewString("RadioGlobe - Earth preview"));
			texture := WMGraphics.LoadImage("RadioGlobeEarth.png", TRUE);
			latitude := Math64.deg2rad(20); longitude := 0;
			radius := 205;
			Render
		END New;

		PROCEDURE Render;
		VAR x, y, u, v: SIZE; red, green, blue, alpha: Raster.Color;
			sx, sy, sz, rr, cLat, sLat, cLon, sLon, px, py, pz, lat, lon, light: FLOAT64;
			pixel, sample: Raster.Pixel;
			readMode, writeMode: Raster.Mode;
		BEGIN
			canvas.Fill(WMRectangles.MakeRect(0, 0, Width, Height), 0001024FFH, WMGraphics.ModeCopy);
			IF texture = NIL THEN
				canvas.DrawString(20, 35, "RadioGlobeEarth.png is missing");
				Invalidate(WMRectangles.MakeRect(0, 0, Width, Height)); RETURN
			END;
			Raster.InitMode(readMode, Raster.srcCopy);
			Raster.InitMode(writeMode, Raster.srcCopy);
			cLat := Math64.cos(latitude); sLat := Math64.sin(latitude);
			cLon := Math64.cos(longitude); sLon := Math64.sin(longitude);
			FOR y := CenterY - radius TO CenterY + radius DO
				sy := (CenterY - y) / radius;
				FOR x := CenterX - radius TO CenterX + radius DO
					sx := (x - CenterX) / radius;
					rr := sx * sx + sy * sy;
					IF rr <= 1 THEN
						sz := Math64.sqrt(1 - rr);
						px := -sLon * sx - sLat * cLon * sy + cLat * cLon * sz;
						py := cLon * sx - sLat * sLon * sy + cLat * sLon * sz;
						pz := cLat * sy + sLat * sz;
						pz := MAX(-1.0, MIN(1.0, pz));
						lat := Math64.arcsin(pz); lon := Math64.arctan2(py, px);
						u := ENTIER((lon / (2 * Math64.pi) + 0.5) * texture.width);
						v := ENTIER((0.5 - lat / Math64.pi) * texture.height);
						IF u < 0 THEN u := 0 ELSIF u >= texture.width THEN u := texture.width - 1 END;
						IF v < 0 THEN v := 0 ELSIF v >= texture.height THEN v := texture.height - 1 END;
						Raster.Get(texture, u, v, sample, readMode);
						Raster.GetRGBA(sample, red, green, blue, alpha);
						light := 0.30 + 0.70 * MAX(0.0, -0.35 * sx + 0.45 * sy + 0.82 * sz);
						Raster.SetRGB(pixel, ENTIER(red * light), ENTIER(green * light), ENTIER(blue * light));
						Raster.Put(img, x, y, pixel, writeMode)
					END
				END
			END;
			canvas.SetColor(WMGraphics.White);
			canvas.DrawString(16, 482, "Drag to rotate  |  wheel to zoom  |  globe preview (no audio yet)");
			Invalidate(WMRectangles.MakeRect(0, 0, Width, Height))
		END Render;

		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		BEGIN oldX := x; oldY := y END PointerDown;

		PROCEDURE PointerMove*(x, y: SIZE; keys: SET);
		BEGIN
			IF 0 IN keys THEN
				longitude := longitude + (oldX - x) / radius;
				latitude := MAX(-1.4, MIN(1.4, latitude + (y - oldY) / radius));
				Render
			END;
			oldX := x; oldY := y
		END PointerMove;

		PROCEDURE WheelMove*(dz: SIZE);
		BEGIN
			radius := MAX(MinRadius, MIN(MaxRadius, radius + dz * 15));
			Render
		END WheelMove;
	END GlobeWindow;

PROCEDURE Open*;
VAR window: GlobeWindow;
BEGIN NEW(window) END Open;

END WMRadioGlobe.
