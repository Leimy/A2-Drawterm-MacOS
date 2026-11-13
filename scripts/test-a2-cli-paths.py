#!/usr/bin/env python3
"""Compile and run through a physically relocated loader whose path contains spaces."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', type=Path, required=True)
args = parser.parse_args()
compiler = args.compiler.resolve()
repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='a2 cli path ') as temporary:
    work = Path(temporary)
    loader = work / 'OberonLoader'
    shutil.copy2(compiler / 'OberonLoader', loader)
    env = dict(os.environ, OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'),
               AOSPATH=f'{work}:{compiler}:{repo / "source"}')
    for command in (['compile', '-p=DarwinA2', 'NativeBuildHello.Mod'], ['do', 'NativeBuildHello.Run']):
        result = subprocess.run([str(loader), *command], cwd=work, env=env,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and not any(s in output for s in
            ('Trap ', 'native signal ', 'error:', 'Command not successful', 'Expected ModuleName')), output
        if command[0] == 'compile':
            assert (work / 'NativeBuildHello.GofAa').is_file(), output
        else:
            assert 'Native Mac build: answer = 42' in output, output
print('PASS: native compile and command execution from a loader path containing spaces')
