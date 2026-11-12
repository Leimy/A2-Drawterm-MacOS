#!/usr/bin/env python3
"""Check the native MP3 decode path with generated MPEG-1 Layer III silence."""
import os
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
print('PASS: native MP3 silence decoded to stereo 44.1 kHz PCM WAV')
