#!/usr/bin/env python3
"""Check implicit Darwin metadata defaults, explicit overrides and GUI inheritance.

The fixture's GUI constructor/type tests run in check-a2-release.py's booted
desktop check, alongside this compiler-only check.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', type=Path, required=True)
parser.add_argument('--bundle', type=Path, required=True)
args = parser.parse_args()
compiler, bundle = args.compiler.resolve(), args.bundle.resolve()
repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='a2-native-platform-') as temporary:
    root = Path(temporary)
    cases = [('implicit', ['-w'], True),
             ('darwin', ['-p=DarwinA2', '-w'], True),
             ('unix-full', ['-p=UnixAArch64', '--metaData=full'], True),
             ('explicit-simple', ['--metaData=simple'], False)]
    for name, options, expected in cases:
        work = root / name
        work.mkdir()
        env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
                   OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'),
                   AOSPATH=f'{work}:{bundle}:{compiler}:{repo / "tests"}')
        result = subprocess.run([str(compiler / 'OberonLoader'), 'compile', *options,
                                 'NativeGUIInheritance.Mod'], cwd=work, env=env,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert not any(s in output for s in ('native signal', 'Trap ')), output
        if expected:
            assert result.returncode == 0 and (work / 'NativeGUIInheritance.GofAa').exists(), output
            assert not any(s in output for s in ('error:', 'Command not successful')), output
            print(f'PASS: {name} compiles an inherited GUI class')
        else:
            assert 'maximal extension level exceeded' in output, output
            assert not (work / 'NativeGUIInheritance.GofAa').exists(), output
            print('PASS: explicit simple metadata remains an intentional override')
