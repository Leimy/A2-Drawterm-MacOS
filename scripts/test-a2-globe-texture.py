#!/usr/bin/env python3
"""Verify native bilinear filtering and interpolated spherical coordinates."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = repo / 'build/native-compiler'
with tempfile.TemporaryDirectory(prefix='a2-globe-texture-') as temporary:
    directory = Path(temporary)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{directory}:{bundle}:{compiler}:{bundle / "data"}:{repo / "tests"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    result = subprocess.run([str(compiler / 'OberonLoader'), 'compile', '-b=AArch64',
                             '--mergeSections', '--metaData=full', '--objectFileExtension=.GofAa',
                             '--symbolFileExtension=.SymAa', '--define=UNIX,AARCH64,DESKTOP',
                             'RadioGlobeTextureProbe.Mod'], cwd=directory, env=env,
                            capture_output=True, text=True, timeout=30)
    assert (directory / 'RadioGlobeTextureProbe.GofAa').exists(), result.stdout + result.stderr
    for command, expected in (('RadioGlobeTextureProbe.Run', 'TEXTURE PASS interpolated angles'),):
        result = subprocess.run([str(bundle / 'OberonLoader'), 'do', command], cwd=directory,
                                env=env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        print(output)
        assert result.returncode == 0 and expected in output, output
        assert not any(s in output for s in ('Trap ', 'native signal', 'Command not successful')), output
