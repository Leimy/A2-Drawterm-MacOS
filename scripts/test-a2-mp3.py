#!/usr/bin/env python3
"""Check the native MP3 decode path with generated MPEG-1 Layer III silence."""
import os
import math
import array
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = repo / 'build/native-compiler'
with tempfile.TemporaryDirectory(prefix='a2-mp3-') as temporary:
    directory = Path(temporary)
    source = directory / 'silence.mp3'
    target = directory / 'silence.wav'
    # 128 kbit/s, 44.1 kHz stereo, no CRC or padding. Zero side information
    # declares no spectral coefficients; the expected decoded PCM is silence.
    source.write_bytes((bytes.fromhex('fffb9000') + bytes(413)) * 12)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{bundle}:{compiler}:{bundle / "data"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    result = subprocess.run([str(compiler / 'OberonLoader'), 'do',
                             f'RadioGlobeAudio.DecodeMP3 {source} {target}'],
                            env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'MP3 decoded bytes=' in result.stdout, result.stdout + result.stderr
    with wave.open(str(target)) as audio:
        assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (2, 44100, 2)
        assert 13824 <= audio.getnframes() <= 18000
        samples = audio.readframes(audio.getnframes())
        assert samples and not any(samples), 'Silence decoded to nonzero PCM'
    fixture = bundle / 'data/RadioGlobeTest.mp3'
    target = directory / 'tones.wav'
    result = subprocess.run([str(compiler / 'OberonLoader'), 'do',
                             f'RadioGlobeAudio.DecodeMP3 {fixture} {target}'],
                            env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0 and 'MP3 decoded bytes=' in result.stdout, result.stdout + result.stderr
    with wave.open(str(target)) as audio:
        assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (2, 44100, 2)
        pcm = array.array('h', audio.readframes(audio.getnframes()))
        if sys.byteorder != 'little':
            pcm.byteswap()
        left = pcm[::2]
        assert 88200 <= len(left) <= 96000
        assert max(abs(x) for x in left) < 7000, 'Unexpected clipping or noise'
        for time, frequency, other in ((0.3, 440, 660), (1.3, 660, 440)):
            segment = left[int(time * 44100):int(time * 44100) + 4410]
            def amplitude(hz):
                return abs(sum(x * complex(math.cos(2 * math.pi * hz * i / 44100),
                                           math.sin(2 * math.pi * hz * i / 44100))
                               for i, x in enumerate(segment))) / len(segment)
            assert amplitude(frequency) > 2000 and amplitude(other) < 100, 'Decoded tone is incorrect'
print('PASS: native MP3 silence decoded to stereo 44.1 kHz PCM WAV')
print('PASS: native MP3 test clip preserves the 440 Hz and 660 Hz tones')
