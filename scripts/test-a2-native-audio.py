#!/usr/bin/env python3
"""Audible integration check: play, unload the driver, reload, and play again."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1]).resolve()
compiler = Path(os.environ.get('A2_COMPILER_LIBRARY', repo / 'build/native-compiler')).resolve()
with tempfile.TemporaryDirectory(prefix='a2-audio-') as directory:
    commands = Path(directory) / 'Audio.txt'
    commands.write_text('RadioGlobeAudio.PlayMP3 RadioGlobeTest.mp3 ~\n'
                        'System.Free RadioGlobeAudio DarwinSound ~\n'
                        'RadioGlobeAudio.PlayMP3 RadioGlobeTest.mp3 ~\n')
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{directory}:{bundle}:{compiler}:{bundle / "data"}:{repo / "tests"}',
               OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    compile_result = subprocess.run([str(compiler / 'OberonLoader'), 'compile', '-b=AArch64',
                                    '--mergeSections', '--metaData=full', '--objectFileExtension=.GofAa',
                                    '--symbolFileExtension=.SymAa', '--define=UNIX,AARCH64,DESKTOP',
                                    'DarwinSoundProbe.Mod'], cwd=directory, env=env,
                                   capture_output=True, text=True, timeout=30)
    assert (Path(directory) / 'DarwinSoundProbe.GofAa').exists(), compile_result.stdout + compile_result.stderr
    probe = subprocess.run([str(bundle / 'OberonLoader'), 'do', 'DarwinSoundProbe.Run'],
                           cwd=directory, env=env, capture_output=True, text=True, timeout=30)
    print(probe.stdout + probe.stderr)
    assert probe.returncode == 0 and 'AUDIO PASS channels, mixer, backpressure, resume, stop, close' in probe.stdout
    assert not any(s in probe.stdout + probe.stderr for s in ('DarwinSound error', 'Trap ', 'native signal', 'Command not successful'))
    result = subprocess.run([str(bundle / 'OberonLoader'), 'execute', str(commands)],
                            cwd=directory, env=env, capture_output=True, text=True, timeout=40)
    output = result.stdout + result.stderr
    print(output)
    assert result.returncode == 0, result.returncode
    assert output.count('Native MP3 playback complete') == 2, output
    assert output.count('DarwinSound installed') == 2, output
    assert not any(s in output for s in ('DarwinSound error', 'Trap ', 'native signal', 'Command not successful')), output
print('PASS: native AudioQueue playback, driver unload, and replay')
