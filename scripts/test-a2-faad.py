#!/usr/bin/env python3
"""Evaluate a local leimy/aacdec checkout without bundling or installing FAAD2.
Usage: python3 scripts/test-a2-faad.py AACDEC_CHECKOUT [--sanitize]
"""
import array
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
checkout = Path(sys.argv[1]).resolve()
source = checkout / 'libfaad'
sanitize = '--sanitize' in sys.argv[2:]
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
print(f'FAAD evaluation: {revision}', flush=True)
units = re.findall(r'^\s*([a-z0-9_]+)\.\$O', (source / 'mkfile').read_text(), re.M)
assert units and len(units) == len(set(units))
with tempfile.TemporaryDirectory(prefix='a2-faad-evaluation-') as temporary:
    output = Path(temporary)
    flags = ['-std=gnu99', '-O1' if sanitize else '-O2', '-g', '-fPIC',
             '-I' + str(source), '-DSTDC_HEADERS=1', '-DHAVE_STDINT_H=1',
             '-DHAVE_STRING_H=1', '-DHAVE_STRCHR=1', '-DHAVE_MEMCPY=1',
             '-DHAVE_STDLIB_H=1', '-DNDEBUG', '-DPACKAGE_VERSION="2.11.1"']
    if sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    objects = []
    for name in units:
        target = output / (name + '.o')
        subprocess.run(['clang', *flags, '-c', str(source / (name + '.c')),
                        '-o', str(target)], check=True)
        objects.append(str(target))
    executable = output / 'probe'
    subprocess.run(['clang', *flags, str(repo / 'tests/FAADDecoderProbe.c'),
                    *objects, '-o', str(executable)], check=True)
    env = dict(os.environ)
    if sanitize:
        env['UBSAN_OPTIONS'] = 'halt_on_error=1'
        env['ASAN_OPTIONS'] = 'detect_leaks=0'  # LeakSanitizer is unavailable on macOS.
    for suffix, rate in (('.aac', 44100), ('-HE.aac', 44100), ('-Mono.aac', 48000)):
        target = output / 'decoded.pcm'
        result = subprocess.run([str(executable), str(repo / 'data' / ('RadioGlobeTest' + suffix)),
                                 str(target)], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert f'rate={rate} channels=2' in result.stdout, result.stdout
        pcm = array.array('h', target.read_bytes())
        if sys.byteorder != 'little':
            pcm.byteswap()
        samples = pcm[::2]
        assert 2 <= len(samples) / rate < 2.2, len(samples)
        assert max(map(abs, samples)) < 7000
        for start, hz, reject in ((0.3, 440, 660), (1.3, 660, 440)):
            segment = samples[int(start * rate):int((start + 0.1) * rate)]
            def amplitude(frequency):
                return abs(sum(x * complex(math.cos(2 * math.pi * frequency * i / rate),
                                           math.sin(2 * math.pi * frequency * i / rate))
                               for i, x in enumerate(segment))) / len(segment)
            assert amplitude(hz) > 2000 and amplitude(reject) < 100
        print(f'FAAD PASS {suffix}: {result.stdout.strip()}, pitch and amplitude', flush=True)
