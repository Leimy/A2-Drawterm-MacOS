MODULE RadioGlobeTexture;
IMPORT Raster, Math64;
CONST LutSize = 8192;
VAR asinLut, atanLut: ARRAY LutSize + 1 OF FLOAT64;

PROCEDURE ArcSin*(x: FLOAT64): FLOAT64;
VAR position, fraction: FLOAT64; index: SIZE;
BEGIN
	x := MAX(-1.0, MIN(1.0, x)); position := (x + 1) * (LutSize DIV 2); index := ENTIER(position);
	(* Avoid lookup-table curvature errors close to either pole. *)
	IF ABS(x) > 0.99 THEN RETURN Math64.arcsin(x) END;
	fraction := position - index;
	RETURN asinLut[index] + fraction * (asinLut[index + 1] - asinLut[index])
END ArcSin;

PROCEDURE ArcTan2*(y, x: FLOAT64): FLOAT64;
VAR ax, ay, angle, position, fraction: FLOAT64; index: SIZE;
BEGIN
	ax := ABS(x); ay := ABS(y);
	IF ax >= ay THEN
		IF ax = 0 THEN RETURN 0 END;
		position := ay / ax * LutSize
	ELSE position := ax / ay * LutSize
	END;
	index := MIN(LutSize - 1, ENTIER(position)); fraction := position - index;
	angle := atanLut[index] + fraction * (atanLut[index + 1] - atanLut[index]);
	IF ay > ax THEN angle := Math64.pi / 2 - angle END;
	IF x < 0 THEN
		IF y < 0 THEN angle := angle - Math64.pi ELSE angle := Math64.pi - angle END
	ELSIF y < 0 THEN angle := -angle
	END;
	RETURN angle
END ArcTan2;

(** Sample an opaque BGRA image in texel coordinates. Integer coordinates are
    texel centers. Wrap longitude and clamp latitude; use 8-bit fractional weights. *)
PROCEDURE Sample*(image: Raster.Image; u, v: FLOAT64; VAR b, g, r: SIGNED32);
VAR x, y, nextX, nextY, top, bottom, a, c: SIZE;
	fx, fy, w00, w10, w01, w11: SIGNED32;
BEGIN
	x := ENTIER(u); fx := ENTIER((u - x) * 256);
	v := MAX(0.0, MIN(image.height - 1, v)); y := ENTIER(v); fy := ENTIER((v - y) * 256);
	x := x MOD image.width; nextX := (x + 1) MOD image.width; nextY := MIN(y + 1, image.height - 1);
	top := y * image.bpr; bottom := nextY * image.bpr; a := x * 4; c := nextX * 4;
	w00 := (256 - fx) * (256 - fy); w10 := fx * (256 - fy);
	w01 := (256 - fx) * fy; w11 := fx * fy;
	b := (ORD(image.mem[top + a]) * w00 + ORD(image.mem[top + c]) * w10 +
		ORD(image.mem[bottom + a]) * w01 + ORD(image.mem[bottom + c]) * w11 + 32768) DIV 65536;
	g := (ORD(image.mem[top + a + 1]) * w00 + ORD(image.mem[top + c + 1]) * w10 +
		ORD(image.mem[bottom + a + 1]) * w01 + ORD(image.mem[bottom + c + 1]) * w11 + 32768) DIV 65536;
	r := (ORD(image.mem[top + a + 2]) * w00 + ORD(image.mem[top + c + 2]) * w10 +
		ORD(image.mem[bottom + a + 2]) * w01 + ORD(image.mem[bottom + c + 2]) * w11 + 32768) DIV 65536
END Sample;

PROCEDURE Init;
VAR i: SIZE;
BEGIN
	FOR i := 0 TO LutSize DO
		asinLut[i] := Math64.arcsin(i / (LutSize DIV 2) - 1);
		atanLut[i] := Math64.arctan(i / LutSize)
	END
END Init;
BEGIN Init
END RadioGlobeTexture.
