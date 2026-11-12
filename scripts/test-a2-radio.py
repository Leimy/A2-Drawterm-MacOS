#!/usr/bin/env python3
"""Local Icecast/Shoutcast transport, metadata and cancellation regression."""
import array
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import wave

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = repo / 'build/native-compiler'
fixture = (bundle / 'data/RadioGlobeTest.mp3').read_bytes()
codec_fixtures = {'/aac': (bundle / 'data/RadioGlobeTest.aac').read_bytes(),
                  '/aac-he': (bundle / 'data/RadioGlobeTest-HE.aac').read_bytes(),
                  '/vorbis': (bundle / 'data/RadioGlobeTest.ogg').read_bytes()}
codec_fixtures['/vorbis-chain'] = codec_fixtures['/vorbis'] * 2
interval = 997
metadata = b"StreamTitle='A2 radio regression';"
metadata += bytes((-len(metadata)) % 16)
icy = bytearray()
for number, offset in enumerate(range(0, len(fixture), interval)):
    block = fixture[offset:offset + interval]
    icy.extend(block)
    if len(block) == interval:
        icy.extend(bytes([len(metadata) // 16]) + metadata if number % 2 == 0 else b'\0')

def add_metadata(audio):
    data = bytearray()
    for offset in range(0, len(audio), interval):
        block = audio[offset:offset + interval]
        data.extend(block)
        if len(block) == interval:
            data.extend(bytes([len(metadata) // 16]) + metadata)
    return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        assert self.headers.get('Icy-MetaData') == '1'
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/chunked')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/missing':
            self.send_error(404)
            return
        self.send_response(200)
        if self.path == '/legacy':
            self._headers_buffer[0] = b'ICY 200 OK\r\n'
        content_type = 'audio/mpeg'
        if self.path == '/html': content_type = 'text/html'
        elif self.path.startswith('/aac'): content_type = 'audio/aacp'
        elif self.path.startswith('/vorbis'): content_type = 'audio/ogg'
        self.send_header('Content-Type', content_type)
        self.send_header('Connection', 'close')
        body = fixture if self.path in ('/plain', '/stall') else icy
        if self.path in codec_fixtures:
            body = add_metadata(codec_fixtures[self.path])
        if self.path not in ('/plain', '/stall'):
            self.send_header('icy-metaint', '-1' if self.path == '/badmeta' else str(interval))
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        elif self.path != '/stall' and not self.path.startswith('/continuous'):
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            if self.path == '/stall':
                self.wfile.write(fixture[:100])
                self.wfile.flush()
                self.connection.settimeout(6)
                # Cancellation should close the connection before this timeout.
                with contextlib.suppress(OSError):
                    self.connection.recv(1)
                return
            if self.path.startswith('/continuous'):
                position = 0
                while True:
                    audio = fixture[position:position + interval]
                    if len(audio) < interval:
                        audio += fixture[:interval - len(audio)]
                    position = (position + interval) % len(fixture)
                    self.wfile.write(audio + bytes([len(metadata) // 16]) + metadata)
                    self.wfile.flush()
            for offset in range(0, len(body), 137):
                block = body[offset:offset + 137]
                if self.path == '/chunked':
                    self.wfile.write(f'{len(block):x}\r\n'.encode() + block + b'\r\n')
                else:
                    self.wfile.write(block)
            if self.path == '/chunked':
                self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


def check_wav(path, repeats=1):
    with wave.open(str(path)) as f:
        assert (f.getnchannels(), f.getframerate(), f.getsampwidth()) == (2, 44100, 2)
        pcm = array.array('h', f.readframes(f.getnframes()))
        if sys.byteorder != 'little':
            pcm.byteswap()
        samples = pcm[::2]
        assert 88200 * repeats <= len(samples) <= 96000 * repeats, len(samples)
        assert max(abs(x) for x in samples) < 7000
        for start, hz, reject in [(i * 2 + t, hz, other) for i in range(repeats)
                                  for t, hz, other in ((0.3, 440, 660), (1.3, 660, 440))]:
            segment = samples[int(start * 44100):int(start * 44100) + 4410]
            def amplitude(frequency):
                return abs(sum(x * complex(math.cos(2 * math.pi * frequency * i / 44100),
                                           math.sin(2 * math.pi * frequency * i / 44100))
                               for i, x in enumerate(segment))) / len(segment)
            assert amplitude(hz) > 2000 and amplitude(reject) < 100


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.requests = []
server.daemon_threads = True
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='a2-radio-') as temporary:
        env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
                   AOSPATH=f'{temporary}:{bundle}:{compiler}:{bundle / "data"}:{repo / "tests"}',
                   OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
        def run(*arguments):
            result = subprocess.run([str(bundle / 'OberonLoader'), *arguments], cwd=temporary,
                                    env=env, capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert not any(s in output for s in ('Trap ', 'native signal', 'Command not successful')), output
            return output
        base = f'http://127.0.0.1:{server.server_port}'
        for endpoint in ('plain', 'icy', 'legacy', 'chunked', 'redirect'):
            path = Path(temporary) / f'{endpoint}.wav'
            output = run('do', f'RadioGlobeAudio.DecodeMP3 {base}/{endpoint} {path}')
            assert 'MP3 decoded bytes=' in output, output
            if endpoint != 'plain':
                assert 'Radio title: A2 radio regression' in output, output
            check_wav(path)
            print(f'RADIO PASS {endpoint}')
        for endpoint in ('aac', 'aac-he', 'vorbis', 'vorbis-chain'):
            path = Path(temporary) / f'{endpoint}.wav'
            output = run('do', f'RadioGlobeAudio.DecodeNative {base}/{endpoint} {path}')
            assert 'Audio decoded bytes=' in output and 'Radio title: A2 radio regression' in output, output
            check_wav(path, 2 if endpoint == 'vorbis-chain' else 1)
            print(f'RADIO PASS {endpoint} with ICY metadata')
        for endpoint in ('missing', 'html', 'badmeta'):
            path = Path(temporary) / f'{endpoint}.wav'
            output = run('do', f'RadioGlobeAudio.DecodeMP3 {base}/{endpoint} {path}')
            assert 'Radio connection failed' in output and not path.exists(), output
            print(f'RADIO PASS reject {endpoint}')
        commands = Path(temporary) / 'Stop.txt'
        commands.write_text(f'RadioGlobeAudio.PlayURL {base}/stall ~\n'
                            'System.Wait 500 ~\nRadioGlobeAudio.Stop ~\n')
        start = time.monotonic()
        output = run('execute', str(commands))
        assert 'Radio stopped' in output and time.monotonic() - start < 5, output
        print('RADIO PASS cancellation during stalled input')
        if '--playback' in sys.argv:
            commands.write_text(f'RadioGlobeAudio.PlayURL {base}/continuous ~\n'
                                'System.Wait 3000 ~\nRadioGlobeAudio.Stop ~\n')
            output = run('execute', str(commands))
            assert 'Radio playing' in output and 'Radio stopped' in output, output
            assert 'DarwinSound error' not in output, output
            print('RADIO PASS streaming through native AudioQueue')
            (Path(temporary) / 'RadioGlobeStation.txt').write_text(f'{base}/continuous\n')
            ui = subprocess.run([sys.executable, str(repo / 'scripts/test-a2-desktop-input.py'),
                                 '--loader', str(bundle / 'OberonLoader'),
                                 '--core', str(bundle / 'DarwinAosDrawtermDesktopAa'),
                                 '--cwd', temporary, '--menu-app', 'radio-globe',
                                 '--radio-globe-audio', '--timeout', '35'],
                                capture_output=True, text=True, timeout=40)
            assert ui.returncode == 0, ui.stdout + ui.stderr
            print('RADIO PASS globe Play/Stop buttons')
        if '--stations' in sys.argv:
            capture = []
            if '--capture' in sys.argv:
                capture = ['--capture', str(Path(sys.argv[sys.argv.index('--capture') + 1]).resolve())]
            output = run('compile', '-b=AArch64', '--mergeSections', '--metaData=full',
                         '--objectFileExtension=.GofAa', '--symbolFileExtension=.SymAa',
                         '--define=UNIX,AARCH64,DESKTOP', 'RadioPlaybackProbe.Mod')
            assert (Path(temporary) / 'RadioPlaybackProbe.GofAa').exists(), output
            commands.write_text(f'RadioPlaybackProbe.Run {base} ~\n'
                                'System.Free RadioPlaybackProbe RadioGlobeAudio ~\n')
            output = run('execute', str(commands))
            assert 'RADIO PASS rapid selection keeps latest station and stops' in output, output
            assert 'Unloading RadioGlobeAudio... done.' in output, output
            print('RADIO PASS rapid requests and module unload')
            (Path(temporary) / 'RadioGlobeStations.txt').write_text(
                f'20 0 "Test One" {base}/continuous-one\n'
                f'20 0 "Test Two" {base}/continuous-two\n'
                f'20 180 "Back station" {base}/continuous-back\n' +
                (bundle / 'data/RadioGlobeStations.txt').read_text())
            ui = subprocess.run([sys.executable, str(repo / 'scripts/test-a2-desktop-input.py'),
                                 '--loader', str(bundle / 'OberonLoader'),
                                 '--core', str(bundle / 'DarwinAosDrawtermDesktopAa'),
                                 '--cwd', temporary, '--menu-app', 'radio-globe',
                                 '--radio-globe-stations', '--timeout', '45', *capture],
                                capture_output=True, text=True, timeout=50)
            assert ui.returncode == 0, ui.stdout + ui.stderr
            assert '/continuous-one' in server.requests and server.requests.count('/continuous-two') >= 2, server.requests
            print('RADIO PASS station picking, switching, browser search and play')
finally:
    server.shutdown()
    server.server_close()
