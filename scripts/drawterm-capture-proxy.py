#!/usr/bin/env python3
"""Transparent drawterm proxy; save full-width draw uploads as a diagnostic PPM."""
import os, signal, struct, subprocess, sys, threading
from pathlib import Path
drawterm = os.environ.get('A2_REAL_DRAWTERM', str(Path(__file__).resolve().parents[1] / 'build/native-desktop/drawterm'))
child = subprocess.Popen([drawterm, *sys.argv[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def stop(signum=None, frame=None):
    child.terminate()
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
rows = {}; width = 0; xorigin = 0; yorigin = None

def capture(packet):
    global width, xorigin, yorigin
    if packet[4] != 118 or len(packet) < 23: return
    fid, = struct.unpack_from('<I', packet, 7)
    if fid != 3: return
    data = packet[23:]
    if data[:1] == b'y' and len(data) >= 21:
        image, x0, y0, x1, y1 = struct.unpack_from('<Iiiii', data, 1)
        if image != 0: return
        width = x1-x0; xorigin = x0
        yorigin = y0 if yorigin is None else min(yorigin,y0)
        pixels = data[21:]
        if len(pixels) != width*(y1-y0)*4: raise ValueError('invalid draw payload')
        for y in range(y0,y1):
            bgra = pixels[(y-y0)*width*4:(y-y0+1)*width*4]
            rgb = bytearray(width*3)
            rgb[0::3] = bgra[2::4]; rgb[1::3] = bgra[1::4]; rgb[2::3] = bgra[0::4]
            rows[y] = rgb
    elif data == b'v' and rows:
        height = max(rows)-yorigin+1
        if len(rows) != height: return
        path = os.environ['A2_DRAW_CAPTURE']
        with open(path+'.tmp','wb') as f:
            f.write(f'P6\n{width} {height}\n255\n'.encode())
            for y in range(yorigin,yorigin+height): f.write(rows[y])
        os.replace(path+'.tmp',path)

def outgoing():
    try:
        buf = bytearray()
        while True:
            data = os.read(0,65536)
            if not data: break
            child.stdin.write(data); child.stdin.flush(); buf.extend(data)
            while len(buf)>=4:
                size, = struct.unpack_from('<I',buf)
                if len(buf)<size: break
                capture(buf[:size]); del buf[:size]
    except (BrokenPipeError, OSError):
        pass
    finally:
        try: child.stdin.close()
        except OSError: pass
threading.Thread(target=outgoing,daemon=True).start()
try:
    while True:
        data=os.read(child.stdout.fileno(),65536)
        if not data: break
        pending = memoryview(data)
        while pending:
            pending = pending[os.write(1,pending):]
except (BrokenPipeError, OSError):
    pass
finally:
    child.terminate()
    try: child.wait(timeout=2)
    except subprocess.TimeoutExpired: child.kill(); child.wait()
