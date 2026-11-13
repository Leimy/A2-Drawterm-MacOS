"""Record timestamped committed A2 frames without blocking its 9P/input loop."""
import hashlib
import json
from pathlib import Path
import queue
import struct
import subprocess
import threading
import time


class RadioGlobeVideo:
    width, height, fps = 800, 600, 60  # Capture cadence; timestamps are preserved by the encoder.
    crop_x, crop_y = 16, 32

    def __init__(self, output, encoder):
        self.output, self.encoder = Path(output).resolve(), encoder
        if self.output.exists():
            raise ValueError(f'Video already exists: {self.output}')
        self.actions = [(380, 318, 0, 1.2)]
        def drag(start, finish):
            self.actions.extend([(start, 320, 0, 0.2), (start, 320, 1, 0.08)])
            for i in range(1, 97):
                self.actions.append((round(start + (finish-start)*i/96), 320, 1, 1/120))
            self.actions.extend([(finish, 320, 0, 1.6), (finish, 320, 1, 0.5), (finish, 320, 0, 0.2)])
        drag(480, 300)
        drag(330, 410)
        for button in (16, 8):
            for _ in range(12):
                self.actions.extend([(380, 318, button, 0.10), (380, 318, 0, 0.10)])
            self.actions.append((380, 318, 0, 1.5))
        self.index = 0
        self.due = self.started = None
        self.latest = self.poster = None
        self.process = self.worker = self.sampler = None
        self.stop_sampling = threading.Event()
        self.source_timestamps = []
        self.sampling_late = 0
        self.pending = queue.Queue(maxsize=32)  # Bounded ~46 MiB, never waits in the 9P loop.
        self.error = None
        self.records, self.events = [], []
        self.last_timestamp = -1
        self.max_queue = 0

    def _write_frames(self):
        try:
            while True:
                item = self.pending.get()
                if item is None:
                    break
                timestamp, frame = item
                self.process.stdin.write(struct.pack('<Q', timestamp))
                self.process.stdin.write(frame)
                self.records.append((timestamp, hashlib.sha256(frame).hexdigest()))
            self.process.stdin.close()
        except Exception as error:
            self.error = error

    def _enqueue(self, frame, now):
        timestamp = max(self.last_timestamp+1, int((now-self.started)*1_000_000))
        try:
            self.pending.put_nowait((timestamp, frame))
        except queue.Full:
            raise RuntimeError('Video encoder fell behind; refusing a recording with dropped frames')
        self.last_timestamp = timestamp
        self.max_queue = max(self.max_queue, self.pending.qsize())

    def _sample_frames(self):
        number = 0
        try:
            while not self.stop_sampling.is_set():
                due = self.started + number/self.fps
                if self.stop_sampling.wait(max(0, due-time.monotonic())):
                    break
                now = time.monotonic()
                if now-due > 0.05:
                    self.sampling_late += 1
                # Immutable framebuffer snapshots can be read without blocking
                # the protocol thread. Encoding has its own bounded queue.
                self._enqueue(self.latest, due)
                number += 1
        except Exception as error:
            self.error = error

    def commit(self, pixels, screen_width):
        if self.started is None:
            return
        now = time.monotonic()
        self.latest = b''.join(pixels[((self.crop_y+y)*screen_width+self.crop_x)*3:
                                     ((self.crop_y+y)*screen_width+self.crop_x+self.width)*3]
                               for y in range(self.height))
        self.source_timestamps.append((now-self.started)*1000)
        if self.poster is None and now-self.started > 0.4:
            self.poster = self.latest

    def step(self, pixels, screen_width, mouse_ready):
        now = time.monotonic()
        if self.error is not None:
            raise RuntimeError(f'Video encoder pipe failed: {self.error}')
        if self.started is None:
            self.output.parent.mkdir(parents=True, exist_ok=True)
            self.process = subprocess.Popen([self.encoder, str(self.output), str(self.width),
                                             str(self.height), str(self.fps), '--timestamps'],
                                            stdin=subprocess.PIPE)
            self.started = self.due = now
            self.worker = threading.Thread(target=self._write_frames, daemon=True)
            self.worker.start()
            self.commit(pixels, screen_width)
            self.sampler = threading.Thread(target=self._sample_frames, daemon=True)
            self.sampler.start()
        if now < self.due or not mouse_ready:
            return None, False
        if self.index == len(self.actions):
            self.stop_sampling.set()
            self.sampler.join(timeout=2)
            if self.sampler.is_alive():
                raise RuntimeError('Frame sampler did not stop')
            self._enqueue(self.latest, now)  # Preserve the final still's duration.
            self.pending.put(None, timeout=5)
            self.worker.join(timeout=30)
            if self.worker.is_alive() or self.error is not None:
                raise RuntimeError(f'Video writer did not finish: {self.error}')
            if self.process.wait(timeout=30):
                raise RuntimeError('Native video encoder failed')
            if len(set(digest for _, digest in self.records)) < 30:
                raise RuntimeError('Demo did not contain enough changing frames')
            poster = self.output.with_suffix('.poster.ppm')
            poster.write_bytes(f'P6\n{self.width} {self.height}\n255\n'.encode() + (self.poster or self.latest))
            subprocess.run(['sips', '-s', 'format', 'png', str(poster),
                            '--out', str(self.output.with_suffix('.png'))], check=True,
                           stdout=subprocess.DEVNULL)
            poster.unlink()
            timestamps = [t/1000 for t, _ in self.records]
            timing = {'duration_seconds': now-self.started, 'frames': len(self.records),
                      'max_encoder_queue': self.max_queue, 'dropped_frames': 0,
                      'capture_fps': self.fps, 'late_samples_over_50ms': self.sampling_late,
                      'source_frame_timestamps_ms': self.source_timestamps,
                      'frame_timestamps_ms': timestamps, 'pointer_events': self.events}
            self.output.with_suffix('.timing.json').write_text(json.dumps(timing, indent=2)+'\n')
            print(f'VIDEO PASS {len(self.records)} frames at {self.fps} fps, zero encoder drops; max queue={self.max_queue}, late={self.sampling_late}; {self.output}')
            self.process = None
            return None, True
        x, y, buttons, delay = self.actions[self.index]
        self.events.append({'time_ms': (now-self.started)*1000, 'buttons': buttons, 'x': x, 'y': y})
        self.index += 1
        self.due = max(self.due, now-0.02) + delay
        return (x, y, buttons), False

    def close(self):
        self.stop_sampling.set()
        if self.sampler is not None:
            self.sampler.join(timeout=2)
        if self.process is not None:
            # Termination also unblocks a worker waiting on a stalled encoder pipe.
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            try:
                self.pending.put_nowait(None)
            except queue.Full:
                pass
            if self.worker is not None:
                self.worker.join(timeout=2)
            self.process = None
