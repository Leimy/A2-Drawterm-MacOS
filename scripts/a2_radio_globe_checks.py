"""Framebuffer and inertia checks driven through the real A2 mouse event path."""
import hashlib
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import time


class RadioGlobeChecks:
    def __init__(self, capture=None, texture=None, quality=False):
        self.capture = capture
        self.check_deadline = None
        # sips is bundled with macOS; the test needs no imaging package.
        texture = texture or Path(__file__).resolve().parents[1] / 'data/RadioGlobeEarth.png'
        with tempfile.TemporaryDirectory(prefix='a2-globe-texture-') as work:
            bmp = Path(work) / 'earth.bmp'
            subprocess.run(['sips', '-s', 'format', 'bmp', str(texture), '--out', str(bmp)],
                           check=True, stdout=subprocess.DEVNULL)
            data = bmp.read_bytes()
        offset = struct.unpack_from('<I', data, 10)[0]
        self.tw, height = struct.unpack_from('<ii', data, 18)
        bits = struct.unpack_from('<H', data, 28)[0]
        assert bits in (24, 32) and struct.unpack_from('<I', data, 30)[0] == 0
        self.th = abs(height)
        stride = ((self.tw * bits + 31) // 32) * 4
        self.texture = []
        for y in range(self.th):
            row = offset + (self.th - 1 - y if height > 0 else y) * stride
            pixel_size = bits // 8
            rgb = bytearray(self.tw * 3)
            for channel in range(3):
                rgb[channel::3] = data[row + 2 - channel:row + self.tw * pixel_size:pixel_size]
            self.texture.append(rgb)
        self.lat, self.lon = math.radians(20), 0
        self.radius = 205
        self.index = 0
        self.due = 0
        self.snapshot = None
        # Each wait follows the action. Long holds deliberately remove momentum
        # from the reference-image checks; short releases exercise inertia.
        self.actions = [
            ('image', 'initial', 0.1),
            ('mouse', (400, 330, 1), 0.1), ('mouse', (400, 100, 1), 0.25),
            ('mouse', (400, 100, 0), 1.5), ('rotate', (0, -230), 0),
            ('image', 'southern pole', 0),
            ('mouse', (400, 100, 1), 0.1), ('mouse', (400, 550, 1), 0.25),
            ('mouse', (400, 550, 0), 1.5), ('rotate', (0, 450), 0),
            ('image', 'northern pole', 0),
            ('mouse', (500, 320, 1), 0.1), ('mouse', (100, 320, 1), 0.25),
            ('mouse', (100, 320, 0), 1.5), ('rotate', (400, 0), 0),
            ('mouse', (500, 320, 1), 0.1), ('mouse', (100, 320, 1), 0.25),
            ('mouse', (100, 320, 0), 1.5), ('rotate', (400, 0), 0),
            ('image', 'longitude seam', 0),
            ('mouse', (370, 320, 1), 0.06), ('mouse', (430, 320, 1), 0.06),
            ('mouse', (430, 320, 0), 0.8), ('remember', None, 0.5),
            ('changed', 'released globe keeps spinning', 3),
            ('remember', None, 0.3), ('unchanged', 'friction brings the globe to rest', 0),
            ('mouse', (370, 320, 1), 0.06), ('mouse', (430, 320, 1), 0.06),
            ('mouse', (430, 320, 0), 0.15), ('mouse', (430, 320, 1), 0.8),
            ('remember', None, 0.3), ('unchanged', 'grabbing stops the spin', 0),
            ('mouse', (430, 320, 0), 0.2),
            ('mouse', (370, 320, 1), 0.06), ('mouse', (430, 320, 1), 0.06),
            ('mouse', (430, 320, 0), 0.1),
            ('mouse', (672, 70, 1), 0.06), ('mouse', (672, 70, 0), 1.5),
            ('closed', None, 0),
        ]

        geometry = []
        def drag(x, y, endx, endy):
            geometry.extend([('mouse', (x, y, 0), 0.6),
                             ('mouse', (x, y, 1), 0.6),
                             ('mouse', (endx, endy, 1), 0.6),
                             ('mouse', (endx, endy, 0), 1.5)])
        drag(681, 330, 881, 330)
        geometry.append(('shape', (800, 500), 0))
        drag(881, 330, 481, 330)
        drag(300, 581, 300, 681)
        geometry.append(('shape', (400, 600), 0))
        drag(481, 330, 681, 330)
        drag(300, 681, 300, 581)
        geometry.append(('shape', (600, 500), 0))
        # Zoom beyond every side of the content area, verify that
        # rendering is clipped safely at the framebuffer boundaries.
        for _ in range(13):
            geometry.extend([('mouse', (380, 318, 16), 0.15),
                             ('mouse', (380, 318, 0), 0.15)])
        geometry.append(('clipped', None, 1))
        # Run geometry after the existing projection/inertia checks, before close.
        self.actions[-6:-6] = geometry

        # Establish hover/focus before starting a new drag, as a real pointer does.
        expanded = []
        for action in self.actions:
            if action[0] == 'mouse' and action[1][2] == 1 and (not expanded or expanded[-1][0] != 'mouse' or expanded[-1][1][2] != 1):
                x, y, _ = action[1]
                expanded.append(('mouse', (x, y, 0), 0.6))
            if action[0] == 'mouse':
                action = (action[0], action[1], max(0.6, action[2]))
            expanded.append(action)
            if action[0] == 'mouse' and action[1][2] == 1 and action[1] in ((400, 100, 1), (400, 550, 1), (100, 320, 1)):
                expanded.append(('mouse', action[1], 0.6))
        self.actions = expanded

        if quality:
            self.actions = [('image', 'initial', 0.1), ('mouse', (380, 318, 0), 0.5)]
            radius = 205
            for _ in range(28):
                self.actions.extend([('mouse', (380, 318, 16), 0.12),
                                     ('mouse', (380, 318, 0), 0.12)])
                radius += max(15, radius // 10)
            self.actions.extend([('radius', radius, 1), ('image', 'close zoom', 0),
                                 ('mouse', (672, 70, 0), 0.6),
                                 ('mouse', (672, 70, 1), 0.6),
                                 ('mouse', (672, 70, 0), 1.5), ('closed', None, 0)])

    def check_image(self, pixels, width, label):
        bad = total = 0
        cl, sl = math.cos(self.lat), math.sin(self.lat)
        co, so = math.cos(self.lon), math.sin(self.lon)
        for y in range(60, 430, 11):
            for x in range(110, 490, 11):
                sx, sy = (x - 300) / self.radius, (238 - y) / self.radius
                rr = sx * sx + sy * sy
                if rr > 0.94:
                    continue
                sz = math.sqrt(1 - rr)
                px = -so*sx - sl*co*sy + cl*co*sz
                py = co*sx - sl*so*sy + cl*so*sz
                pz = cl*sy + sl*sz
                u = (math.atan2(py, px)/(2*math.pi) + 0.5)*self.tw - 0.5
                v = max(0, min(self.th - 1, (0.5 - math.asin(max(-1, min(1, pz)))/math.pi)*self.th - 0.5))
                x0, y0 = math.floor(u), math.floor(v)
                fx, fy = u - x0, v - y0
                light = 0.30 + 0.70 * max(0, -0.35*sx + 0.45*sy + 0.82*sz)
                pos = ((y + 80)*width + x + 80)*3
                actual = pixels[pos:pos + 3]
                expected = []
                for channel in range(3):
                    def texel(x, y):
                        return self.texture[min(self.th - 1, y)][(x % self.tw)*3 + channel]
                    value = ((texel(x0, y0)*(1-fx) + texel(x0+1, y0)*fx)*(1-fy) +
                             (texel(x0, y0+1)*(1-fx) + texel(x0+1, y0+1)*fx)*fy)
                    expected.append(value*light)
                # Independent exact trig and floating interpolation versus AO's
                # interpolated trig tables and 8-bit fixed-point color weights.
                error = max(abs(actual[c] - expected[c]) for c in range(3))
                bad += error > 3
                total += 1
        if bad > total * 0.03:
            raise RuntimeError(f'RadioGlobe {label}: {bad}/{total} samples disagree with independent spherical projection')
        print(f'PASS: RadioGlobe {label} projection ({total-bad}/{total} samples)')

    def check_geometry(self, pixels, screen_width, kind, dimensions):
        def pixel(x, y):
            pos = ((y + 80)*screen_width + x + 80)*3
            return bytes(pixels[pos:pos+3])
        background = bytes((0, 16, 36))
        if kind == 'clipped':
            if any(pixel(x, y) == background for x, y in
                   ((0, 238), (599, 238), (300, 0), (300, 499))):
                raise RuntimeError('Globe zoom did not extend beyond all window edges')
            print('PASS: globe zoom extends beyond viewport and clips at all four edges')
            if self.capture:
                name = self.capture.with_name(self.capture.stem + '-close-zoom.ppm')
                name.write_bytes(f'P6\n{screen_width} {len(pixels)//(screen_width*3)}\n255\n'.encode() + pixels)
            return
        w, h = dimensions
        cx, cy = w//2, h//2 - 12
        radius = int(205*min(w/600, h/500))
        for angle in range(0, 360, 15):
            a = math.radians(angle)
            for delta in (-4, 4):
                x = round(cx + (radius + delta)*math.cos(a))
                y = round(cy + (radius + delta)*math.sin(a))
                if (pixel(x, y) == background) != (delta > 0):
                    raise RuntimeError(f'Globe is not circular after resize to {w}x{h}')
        print(f'PASS: circular globe after resize to {w}x{h}')

    def step(self, pixels, width, mouse_ready):
        if self.index == len(self.actions):
            return None, True
        if time.monotonic() < self.due:
            return None, False
        kind, value, wait = self.actions[self.index]
        if kind == 'mouse' and not mouse_ready:
            return None, False
        digest = hashlib.sha256(b''.join(pixels[(y*width+250)*3:(y*width+350)*3]
                                       for y in range(180, 440))).digest()
        if kind in ('shape', 'clipped'):
            try:
                self.check_geometry(pixels, width, kind, value)
            except RuntimeError:
                if self.check_deadline is None:
                    self.check_deadline = time.monotonic() + 5
                if time.monotonic() < self.check_deadline:
                    self.due = time.monotonic() + 0.1
                    return None, False
                raise
        elif kind == 'image':
            try:
                self.check_image(pixels, width, value)
            except RuntimeError:
                if self.check_deadline is None:
                    self.check_deadline = time.monotonic() + 5
                if time.monotonic() < self.check_deadline:
                    self.due = time.monotonic() + 0.1
                    return None, False
                raise
            if self.capture:
                name = self.capture.with_name(self.capture.stem + '-' + value.replace(' ', '-') + '.ppm')
                name.write_bytes(f'P6\n{width} {len(pixels)//(width*3)}\n255\n'.encode() + pixels)
        elif kind == 'radius':
            self.radius = value
        elif kind == 'rotate':
            self.lon += value[0] / 205
            self.lat = max(-math.pi/2, min(math.pi/2, self.lat + value[1] / 205))
        elif kind == 'remember':
            self.snapshot = digest
        elif kind in ('changed', 'unchanged'):
            if (digest != self.snapshot) != (kind == 'changed'):
                raise RuntimeError('RadioGlobe: ' + value + ' failed')
            print('PASS: RadioGlobe ' + value)
        elif kind == 'closed':
            samples = {bytes(pixels[(y*width+x)*3:(y*width+x)*3+3])
                       for y in (450, 480, 520) for x in (250, 300, 350)}
            background = bytes(pixels[(200*width+800)*3:(200*width+800)*3+3])
            # The startup window is uncovered above y=423; sample below it.
            if samples != {background}:
                if self.check_deadline is None:
                    self.check_deadline = time.monotonic() + 5
                if time.monotonic() < self.check_deadline:
                    self.due = time.monotonic() + 0.1
                    return None, False
                raise RuntimeError('RadioGlobe did not close during inertial motion')
            print('PASS: RadioGlobe closed during inertial motion')
        self.check_deadline = None
        self.index += 1
        self.due = time.monotonic() + wait
        return (value if kind == 'mouse' else None), False
