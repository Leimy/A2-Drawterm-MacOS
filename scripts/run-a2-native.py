#!/usr/bin/env python3
"""Run the native macOS ARM64 A2 command-line compiler image (no VM).

Examples:
  run-a2-native.py compile Example.Mod
  run-a2-native.py link --fileName=Example.bin --linkRoot=Example.Answer Example
  run-a2-native.py do 'Example.Run'

Output files are written in the current directory. The image and its matching
symbol/object files are produced initially by build/DarwinAArch64Compiler.txt.
"""
import argparse
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE_COMPILER = ROOT / 'build' / 'native-compiler'
DEFAULT_LIBRARY = Path(os.environ.get('A2_COMPILER_LIBRARY', NATIVE_COMPILER))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--loader', type=Path)
    parser.add_argument('--core', type=Path, default=Path(os.environ.get('A2_COMPILER_CORE', DEFAULT_LIBRARY / 'DarwinAosCompilerAa')))
    parser.add_argument('--library', type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.loader is None:
        candidates = [Path(os.environ['A2_LOADER'])] if os.environ.get('A2_LOADER') else [
            args.library / 'OberonLoader', args.library.parent / 'OberonLoader',
            ROOT / 'build' / 'native-desktop-compiler' / 'OberonLoader',
        ]
        args.loader = next((candidate for candidate in candidates if candidate.is_file()), candidates[0])
    if not args.loader.is_file() or not args.core.is_file():
        parser.error('native loader/compiler image missing; pass --loader and --core or set A2_LOADER and A2_COMPILER_CORE')
    command = args.command
    if command and command[0] == 'compile':
        command = [command[0], '-b=AArch64', '--objectFileExtension=.GofAa',
                   '--symbolFileExtension=.SymAa', '--metaData=full',
                   '--define=UNIX,AARCH64', *command[1:]]
    elif command and command[0] == 'link':
        command = [command[0], '--extension=.GofAa', *command[1:]]
    env = os.environ.copy()
    # Fox's recursive semantic checker needs more than the runtime's 128 KiB default.
    env.setdefault('AOSCONFIG', 'Color 0 StackSize 8192')
    env['PWD'] = str(Path.cwd())
    env['OBERON_CORE'] = str(args.core.resolve())
    env['AOSPATH'] = os.pathsep.join([str(Path.cwd()), str(args.library.resolve()), str(ROOT / 'source'),
                                    str(ROOT / 'data'), env.get('AOSPATH', '')]).rstrip(os.pathsep)
    os.execve(str(args.loader.resolve()), [str(args.loader.resolve()), *command], env)

if __name__ == '__main__':
    main()
