MODULE NativeScaleBenchmark;
(** Isolate desktop magnification cost; times exclude rendering and drawterm transport. *)
IMPORT Commands, Kernel, Raster, WMRasterScale, WMRectangles;
PROCEDURE Run*(context: Commands.Context);
VAR src, dst: Raster.Image; q, scale, i, start: SIGNED32;
BEGIN
 NEW(src); Raster.Create(src, 600, 500, Raster.BGRA8888);
 FOR i := 0 TO 600*500*4-1 DO src.mem[i] := 0FFX END;
 FOR scale := 1 TO 3 DO
  NEW(dst); Raster.Create(dst, 600*scale, 500*scale, Raster.BGRA8888);
  FOR q := 0 TO 1 DO
   start := Kernel.GetTicks();
   FOR i := 1 TO 10 DO
    WMRasterScale.Scale(src, WMRectangles.MakeRect(0,0,600,500), dst,
      WMRectangles.MakeRect(0,0,600*scale,500*scale), WMRectangles.MakeRect(0,0,600*scale,500*scale), WMRasterScale.ModeCopy, q)
   END;
   context.out.String("Scale "); context.out.Int(scale,0); context.out.String(" quality "); context.out.Int(q,0);
   context.out.String(" ms/10 frames "); context.out.Int(Kernel.GetTicks()-start,0); context.out.Ln
  END
 END
END Run;
END NativeScaleBenchmark.
