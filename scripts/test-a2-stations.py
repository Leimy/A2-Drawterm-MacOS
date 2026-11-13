#!/usr/bin/env python3
"""Verify original catalogues and native station projection/picking."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = Path(os.environ.get('A2_COMPILER_LIBRARY', repo / 'build/native-compiler')).resolve()
with tempfile.TemporaryDirectory(prefix='a2-stations-') as temporary:
    directory = Path(temporary)
    fixture = directory / 'stations'
    fixture.write_text('# fixture\n20 0 "Test One" http://example.invalid/a;data\n'
                       '20 0 "Test Two" https://example.invalid/two\n'
                       '20 180 "Back" http://example.invalid/back\n'
                       '91 0 "Invalid latitude" http://example.invalid/x\n'
                       'nan 0 "Invalid number" http://example.invalid/x\n'
                       '0 0 "Invalid scheme" file:///nonexistent\n')
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{directory}:{bundle}:{compiler}:{bundle / "data"}:{repo / "tests"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    result = subprocess.run([str(compiler / 'OberonLoader'), 'compile', '-b=AArch64',
                             '--mergeSections', '--metaData=full', '--objectFileExtension=.GofAa',
                             '--symbolFileExtension=.SymAa', '--define=UNIX,AARCH64,DESKTOP',
                             'RadioStationsProbe.Mod'], cwd=directory, env=env,
                            capture_output=True, text=True, timeout=30)
    assert (directory / 'RadioStationsProbe.GofAa').exists(), result.stdout + result.stderr
    for command, expected in ((f'RadioStationsProbe.Run {fixture}', 'STATIONS PASS parsing'),
                              ('RadioStationsProbe.Data', 'STATIONS PASS original')):
        result = subprocess.run([str(bundle / 'OberonLoader'), 'do', command], cwd=directory,
                                env=env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        print(output)
        assert result.returncode == 0 and expected in output, output
        assert not any(s in output for s in ('Trap ', 'native signal', 'Command not successful')), output
