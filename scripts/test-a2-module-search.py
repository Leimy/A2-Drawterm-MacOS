#!/usr/bin/env python3
"""Exercise the real launcher and native module replacement in an isolated bundle.

A compiler core and a quiet socket peer stand in for the desktop/drawterm so
this tests launcher environment, compilation, caching and reload without a GUI.
"""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--launcher', type=Path, required=True)
parser.add_argument('--compiler', type=Path, required=True)
args = parser.parse_args()
launcher, compiler = args.launcher.resolve(), args.compiler.resolve()


def source(name, marker):
    return f'''MODULE {name};
IMPORT KernelLog;
PROCEDURE Run*;
BEGIN KernelLog.String("{marker}"); KernelLog.Ln END Run;
END {name}.
'''


with tempfile.TemporaryDirectory(prefix='a2-module-search-') as temporary:
    root = Path(temporary).resolve()
    bundle, work, extra, stale = [root / n for n in ('bundle directory', 'work area', 'extra path', 'stale pwd')]
    for directory in (bundle, bundle / 'data', work, extra, stale):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(launcher, bundle / 'a2')
    (bundle / 'DarwinAosDrawtermDesktopAa').symlink_to(compiler / 'DarwinAosCompilerAa')
    wrapper = bundle / 'OberonLoader'
    wrapper.write_text('''#!/bin/sh
printf '%s\\n' "$AOSPATH" > "$A2_TEST_SEARCH_CAPTURE"
printf '%s\\n' "$PWD" > "$A2_TEST_PWD_CAPTURE"
exec ''' + shlex.join([str(compiler / 'OberonLoader'), 'execute', 'Reload.txt']) + '\n')
    wrapper.chmod(0o755)
    peer = bundle / 'drawterm'
    peer.write_text('#!/bin/sh\nexec /bin/cat\n')
    peer.chmod(0o755)

    def compile_module(directory, name, marker):
        (directory / (name + '.Mod')).write_text(source(name, marker))
        env = dict(os.environ, PWD=str(directory), AOSCONFIG='Color 0 StackSize 8192',
                   AOSPATH=f'{directory}:{compiler}', OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
        result = subprocess.run([str(compiler / 'OberonLoader'), 'compile', '-p=DarwinA2', name + '.Mod'],
                                cwd=directory, env=env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and (directory / (name + '.GofAa')).exists(), output
        assert not any(s in output for s in ('error:', 'native signal', 'Trap ', 'Command not successful')), output

    compile_module(bundle, 'NativeModuleOverride', 'OVERRIDE BUNDLED')
    compile_module(work, 'NativeModuleOverride', 'OVERRIDE LOCAL INITIAL')
    compile_module(extra, 'NativeExtraSearch', 'OVERRIDE EXTRA')
    # Recompilation occurs while the initial local version is already loaded.
    (work / 'NativeModuleOverride.Mod').write_text(source('NativeModuleOverride', 'OVERRIDE LOCAL UPDATED'))
    script = work / 'Reload.txt'
    script.write_text('''NativeModuleOverride.Run ~
Compiler.Compile -p=DarwinA2 NativeModuleOverride.Mod ~
NativeModuleOverride.Run ~
System.Free NativeModuleOverride ~
NativeModuleOverride.Run ~
System.Free NativeModuleOverride ~
NativeExtraSearch.Run ~
''')
    env = dict(os.environ, PWD=str(stale), AOSCONFIG='Color 0 StackSize 8192',
               AOSPATH=f'{extra}:{compiler}', A2_TEST_SEARCH_CAPTURE=str(root / 'search.txt'),
               A2_TEST_PWD_CAPTURE=str(root / 'pwd.txt'))

    def launch():
        process = subprocess.Popen([str(bundle / 'a2')], cwd=work, env=env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            # Give the launcher's signal handler time to reap both children.
            process.terminate()
            try:
                output, _ = process.communicate(timeout=6)
            except subprocess.TimeoutExpired:
                process.kill(); output, _ = process.communicate()
            raise AssertionError('Launcher test timed out:\n' + output)
        assert process.returncode == 0, output
        assert not any(s in output for s in ('error:', 'native signal', 'Trap ', 'Command not successful')), output
        return output

    output = launch()
    markers = [line.strip() for line in output.splitlines() if line.startswith('OVERRIDE ')]
    assert markers == ['OVERRIDE LOCAL INITIAL', 'OVERRIDE LOCAL INITIAL',
                       'OVERRIDE LOCAL UPDATED', 'OVERRIDE EXTRA'], output
    assert output.count('Unloading NativeModuleOverride... done.') == 2, output
    paths = (root / 'search.txt').read_text().strip().split(os.pathsep)
    assert paths == [str(work), str(bundle), str(bundle / 'data'), str(extra), str(compiler)], paths
    assert (root / 'pwd.txt').read_text().strip() == str(work)
    print('PASS: local module overrides bundle; loaded code stays cached until unload; reload uses recompiled code')
    print('PASS: actual working directory and inherited search paths survive launch from paths containing spaces')

    for suffix in ('.GofAa', '.SymAa'):
        (work / ('NativeModuleOverride' + suffix)).unlink()
    script.write_text('NativeModuleOverride.Run ~\n')
    output = launch()
    assert output.count('OVERRIDE BUNDLED') == 1 and 'OVERRIDE LOCAL' not in output, output
    print('PASS: removing the local module restores the bundled fallback')
