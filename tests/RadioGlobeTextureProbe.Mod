MODULE RadioGlobeTextureProbe;
IMPORT RadioGlobeTexture, Raster, Math64, Kernel, KernelLog;

PROCEDURE Run*;
VAR image, single: Raster.Image; x, y, i, p: SIZE; b, g, r: SIGNED32; value, error, maxError: FLOAT64;
BEGIN
	NEW(image); Raster.Create(image, 3, 2, Raster.BGRA8888); image.width := 2; (* Keep a padded row stride. *)
	FOR y := 0 TO 1 DO FOR x := 0 TO 1 DO
		p := y * image.bpr + x * 4;
		FOR i := 0 TO 2 DO image.mem[p + i] := CHR(y * 128 + x * 64 + i * 20) END
	END END;
	RadioGlobeTexture.Sample(image, 0.5, 0.5, b, g, r); ASSERT((b = 96) & (g = 116) & (r = 136));
	RadioGlobeTexture.Sample(image, -0.5, 0, b, g, r); ASSERT((b = 32) & (g = 52) & (r = 72));
	RadioGlobeTexture.Sample(image, 1.5, 0, b, g, r); ASSERT(b = 32);
	RadioGlobeTexture.Sample(image, 2.5, -10, b, g, r); ASSERT(b = 32);
	RadioGlobeTexture.Sample(image, -2, 10, b, g, r); ASSERT(b = 128);
	FOR i := 0 TO 16 DO
		RadioGlobeTexture.Sample(image, i / 16, 0, b, g, r); ASSERT(b = i * 4)
	END;
	NEW(single); Raster.Create(single, 1, 1, Raster.BGRA8888);
	single.mem[0] := 0FFX; single.mem[1] := 0FFX; single.mem[2] := 0FFX;
	RadioGlobeTexture.Sample(single, -100.5, 100, b, g, r); ASSERT((b = 255) & (g = 255) & (r = 255));
	KernelLog.String("TEXTURE PASS bilinear colors, subtexel ramp, seam wrap, pole clamp and padded rows"); KernelLog.Ln;
	maxError := 0;
	FOR i := 0 TO 20000 DO
		value := i; value := value / 10000 - 1;
		error := ABS(RadioGlobeTexture.ArcSin(value) - Math64.arcsin(value)); maxError := MAX(maxError, error);
		ASSERT(error < 0.000003);
		value := i; value := value / 20000 * 2 * Math64.pi - Math64.pi;
		error := ABS(RadioGlobeTexture.ArcTan2(Math64.sin(value), Math64.cos(value)) - value);
		error := MIN(error, ABS(error - 2 * Math64.pi)); ASSERT(error < 0.0000001)
	END;
	ASSERT(RadioGlobeTexture.ArcTan2(0, 0) = 0);
	KernelLog.String("TEXTURE PASS interpolated angles across quadrants and poles"); KernelLog.Ln
END Run;
END RadioGlobeTextureProbe.
