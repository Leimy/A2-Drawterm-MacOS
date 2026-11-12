#!/usr/bin/env python3
"""Check MP3, AAC, AAC+ and Vorbis decoding, including Vorbis track changes."""
import array
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = repo / 'build/native-compiler'
with tempfile.TemporaryDirectory(prefix='a2-codecs-') as temporary:
    directory = Path(temporary)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{bundle}:{compiler}:{bundle / "data"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    vorbis = (bundle / 'data/RadioGlobeTest.ogg').read_bytes()
    chained = directory / 'chained.ogg'
    chained.write_bytes(vorbis + vorbis)
    cases = [(str(bundle / 'data' / f'RadioGlobeTest{suffix}'), suffix, 1)
             for suffix in ('.mp3', '.aac', '-HE.aac', '-Mono.aac', '.ogg')]
    cases.append((str(chained), 'chained Vorbis', 2))
    for source, label, repeats in cases:
        target = directory / 'decoded.wav'
        result = subprocess.run([str(bundle / 'OberonLoader'), 'do',
                                 f'RadioGlobeAudio.DecodeNative {source} {target}'],
                                cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and 'Audio decoded bytes=' in output, output
        assert not any(s in output for s in ('Trap ', 'native signal', 'codec error')), output
        with wave.open(str(target)) as f:
            assert (f.getnchannels(), f.getframerate(), f.getsampwidth()) == (2, 44100, 2)
            pcm = array.array('h', f.readframes(f.getnframes()))
            if sys.byteorder != 'little': pcm.byteswap()
            if label == '-Mono.aac':
                assert pcm[::2] == pcm[1::2], 'Mono channel mapping differs between output channels'
            samples = pcm[::2]
            assert 88200 * repeats <= len(samples) <= 96000 * repeats, (label, len(samples))
            assert max(map(abs, samples)) < 7000, label
            for repeat in range(repeats):
                for start, hz, reject in ((0.3, 440, 660), (1.3, 660, 440)):
                    offset = int((repeat * 2 + start) * 44100)
                    segment = samples[offset:offset + 4410]
                    def amplitude(frequency):
                        return abs(sum(x * complex(math.cos(2 * math.pi * frequency * i / 44100),
                                                   math.sin(2 * math.pi * frequency * i / 44100))
                                       for i, x in enumerate(segment))) / len(segment)
                    assert amplitude(hz) > 2000 and amplitude(reject) < 100, label
        print(f'CODEC PASS {label}: duration, amplitude and pitch')
