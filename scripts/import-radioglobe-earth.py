#!/usr/bin/env python3
"""Convert RadioGlobe's EARTHTEX BGR source into a PNG, using macOS sips.
Usage: python3 scripts/import-radioglobe-earth.py EARTH_MASK OUTPUT.png [--width 4096]
Optional asset preparation tool; no Python or sips is required at runtime.
"""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('source', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--width', type=int, default=4096)
a = p.parse_args()
with a.source.open('rb') as f:
    assert f.readline() == b'EARTHTEX\n', 'Expected an EARTHTEX source'
    w, h = map(int, f.readline().split())
    assert 0 < a.width <= w <= 16384 and h * 2 == w
    pixels = f.read(w * h * 3 + 1)
    assert len(pixels) == w * h * 3, 'Unexpected BGR data length'
with tempfile.TemporaryDirectory(prefix='a2-earth-') as temporary:
    source = Path(temporary) / 'original.png'
    with source.open('wb') as f:
        def chunk(kind, data):
            f.write(struct.pack('>I', len(data)) + kind + data)
            f.write(struct.pack('>I', zlib.crc32(kind + data)))
        f.write(b'\x89PNG\r\n\x1a\n')
        chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        compressor = zlib.compressobj(6)
        for y in range(h):
            bgr = pixels[y * w * 3:(y + 1) * w * 3]
            rgb = bytearray(w * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = bgr[2::3], bgr[1::3], bgr[0::3]
            data = compressor.compress(b'\0' + rgb)
            if data: chunk(b'IDAT', data)
        chunk(b'IDAT', compressor.flush())
        chunk(b'IEND', b'')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['sips', '-z', str(a.width // 2), str(a.width), str(source),
                    '--out', str(a.output.resolve())], check=True)
