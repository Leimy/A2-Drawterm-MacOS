"""Record a real-time demo from committed A2 framebuffer updates, without audio."""
import hashlib
from pathlib import Path
import subprocess
import time


class RadioGlobeVideo:
    width, height, fps = 800, 600, 20
    crop_x, crop_y = 16, 32

    def __init__(self, output, encoder):
        self.output, self.encoder = Path(output).resolve(), encoder
        if self.output.exists():
            raise ValueError(f'Video already exists: {self.output}')
        self.actions = [(380, 318, 0, 1.2)]
        def drag(start, finish):
            self.actions.extend([(start, 320, 0, 0.2), (start, 320, 1, 0.12)])
            for i in range(1, 17):
                self.actions.append((round(start + (finish - start)*i/16), 320, 1, 0.05))
            self.actions.extend([(finish, 320, 0, 1.6), (finish, 320, 1, 0.5), (finish, 320, 0, 0.2)])
        drag(480, 300)
        drag(330, 410)
        for button in (16, 8):
            for _ in range(12):
                self.actions.extend([(380, 318, button, 0.10), (380, 318, 0, 0.10)])
            self.actions.append((380, 318, 0, 1.5))
        self.index = self.frames = 0
        self.due = self.started = None
        self.latest = None
        self.process = None
        self.poster = None
        self.changed = set()

    def commit(self, pixels, screen_width):
        if self.started is None:
            return
        self.latest = b''.join(pixels[((self.crop_y+y)*screen_width+self.crop_x)*3:
                                     ((self.crop_y+y)*screen_width+self.crop_x+self.width)*3]
                               for y in range(self.height))

    def step(self, pixels, screen_width, mouse_ready):
        now = time.monotonic()
        if self.started is None:
            self.output.parent.mkdir(parents=True, exist_ok=True)
            self.process = subprocess.Popen([self.encoder, str(self.output), str(self.width),
                                             str(self.height), str(self.fps)], stdin=subprocess.PIPE)
            self.started = self.due = now
            self.commit(pixels, screen_width)
        target = int((now - self.started)*self.fps)
        while self.frames <= target:
            self.process.stdin.write(self.latest)
            self.frames += 1
        if self.poster is None and now - self.started > 0.4:
            self.poster = self.latest
        self.changed.add(hashlib.sha256(self.latest).digest())
        if now < self.due or not mouse_ready:
            return None, False
        if self.index == len(self.actions):
            if len(self.changed) < 30:
                raise RuntimeError('Demo did not contain enough changing frames')
            self.process.stdin.close()
            if self.process.wait(timeout=30):
                raise RuntimeError('Native video encoder failed')
            poster = self.output.with_suffix('.poster.ppm')
            poster.write_bytes(f'P6\n{self.width} {self.height}\n255\n'.encode() + self.poster)
            subprocess.run(['sips', '-s', 'format', 'png', str(poster),
                            '--out', str(self.output.with_suffix('.png'))], check=True,
                           stdout=subprocess.DEVNULL)
            poster.unlink()
            print(f'VIDEO PASS {self.frames} frames; {len(self.changed)} distinct framebuffer states; {self.output}')
            self.process = None
            return None, True
        x, y, buttons, delay = self.actions[self.index]
        self.index += 1
        self.due = now + delay
        return (x, y, buttons), False

    def close(self):
        if self.process is not None:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None
