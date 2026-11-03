#!/usr/bin/env python3
"""Rebuild the A2 compiler or drawterm desktop entirely on macOS ARM64."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['compiler', 'desktop'])
    parser.add_argument('--output', required=True, type=Path, help='directory for generated objects and image')
    parser.add_argument('--core', type=Path, help='override the native compiler image')
    parser.add_argument('--library', type=Path, help='matching compiler library directory')
    args = parser.parse_args()
    output = args.output.resolve()
    environment = os.environ.copy()
    if args.core: environment['A2_COMPILER_CORE'] = str(args.core.resolve())
    if args.library: environment['A2_COMPILER_LIBRARY'] = str(args.library.resolve())
    subprocess.run([str(ROOT / 'scripts' / 'build-a2-native.sh'), args.target, str(output)],
                   env=environment, check=True)
    image = output / ('DarwinAosCompilerAa' if args.target == 'compiler' else 'DarwinAosDrawtermDesktopAa')
    if not image.is_file(): raise RuntimeError(f'build did not produce {image}')
    print(f'Native build complete: {image}')

if __name__ == '__main__':
    main()
