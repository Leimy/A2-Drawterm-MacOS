#!/usr/bin/env python3
"""Bounded concurrent allocation/GC soak and repeated dynamic load/unload check."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--compiler', type=Path, required=True)
p.add_argument('--seconds', type=int, default=60)
p.add_argument('--cycles', type=int, default=200)
a = p.parse_args()
compiler = a.compiler.resolve()
assert 1 <= a.seconds <= 3600 and 1 <= a.cycles <= 10000
with tempfile.TemporaryDirectory(prefix='a2-release-soak-') as temporary:
    work = Path(temporary)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{work}:{compiler}:{repo / "tests"}', OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    def run(*args, timeout=30):
        p = subprocess.run([str(compiler / 'OberonLoader'), *args], cwd=work, env=env,
                           capture_output=True, text=True, timeout=timeout)
        output = p.stdout + p.stderr
        assert p.returncode == 0 and not any(x in output for x in ('Trap ', 'native signal ', 'Command not successful')), output
        return output
    output = run('compile', '-p=DarwinA2', 'NativeReleaseSoak.Mod', 'NativeReleaseUnload.Mod')
    assert (work / 'NativeReleaseSoak.GofAa').exists() and (work / 'NativeReleaseUnload.GofAa').exists(), output
    output = run('do', f'NativeReleaseSoak.Run {a.seconds}', timeout=a.seconds + 45)
    print(output, flush=True)
    assert 'SOAK PASS concurrent allocation and GC:' in output, output
    commands = work / 'Unload.txt'
    commands.write_text('NativeReleaseUnload.Run ~\nSystem.Free NativeReleaseUnload ~\n' * a.cycles)
    output = run('execute', str(commands), timeout=max(60, a.cycles // 2))
    assert output.count('Unloading NativeReleaseUnload... done.') == a.cycles, output
    print(f'SOAK PASS {a.cycles} dynamic module load/unload cycles', flush=True)
