#!/usr/bin/env python3
"""Run the existing Fox compilation and execution suites on native AArch64.

The suite driver itself is an Oberon module. It keeps compiled helper modules
between cases, matching the original FoxTest runner's semantics.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'scripts' / 'run-a2-native.py'
SUMMARY = re.compile(r'A64 Fox suite: (\d+)/(\d+) passed, (\d+) failed')
SKIPPED = re.compile(r'(\d+) non-AArch64 cases skipped')
REPLACED = re.compile(r'(\d+) legacy NIL cases replaced')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=['compilation', 'execution', 'both'], default='both')
    parser.add_argument('--core', type=Path)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--timeout', type=float, default=300)
    parser.add_argument('--report', type=Path, help='write JSON summary and suite output')
    args = parser.parse_args()
    launcher = [sys.executable, str(RUNNER)]
    if args.core:
        launcher.extend(['--core', str(args.core.resolve())])
    if args.library:
        launcher.extend(['--library', str(args.library.resolve())])

    selected = ['compilation', 'execution'] if args.suite == 'both' else [args.suite]
    suites = [(suite, f'Oberon.{suite.capitalize()}.Test',
               'compile' if suite == 'compilation' else 'execute') for suite in selected]
    suites += [(f'{suite}/aarch64', f'Oberon.AArch64.{suite.capitalize()}.Test',
                'compile' if suite == 'compilation' else 'execute') for suite in selected]
    results = []
    started = time.monotonic()
    for suite, file_name, mode in suites:
        with tempfile.TemporaryDirectory(prefix=f'a64-fox-{suite.replace("/", "-")}-') as directory:
            work = Path(directory)
            build = subprocess.run([*launcher, 'compile', 'A64FoxSuite.Mod'], cwd=work,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, timeout=args.timeout)
            if build.returncode != 0 or not (work / 'A64FoxSuite.GofAa').is_file():
                print(build.stdout, end='', flush=True)
                raise RuntimeError('could not compile A64FoxSuite.Mod')
            command = f'A64FoxSuite.Run {file_name} {mode} ~'
            try:
                run = subprocess.run([*launcher, 'do', command], cwd=work,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, timeout=args.timeout)
                output = run.stdout
                status = run.returncode
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b''
                if isinstance(output, bytes):
                    output = output.decode(errors='replace')
                output += '\nTIMEOUT'
                status = None
            for line in output.splitlines():
                clean = line.lstrip('\x01\x02\r')
                if ('FAIL #' in clean or clean.startswith('A64 Fox suite:') or
                    re.match(r'^\d+ cases:', clean)):
                    print(clean, flush=True)
            match = SUMMARY.search(output)
            skipped = SKIPPED.search(output)
            replaced = REPLACED.search(output)
            result = {'suite': suite, 'status': status, 'output': output,
                      'passed': int(match[1]) if match else None,
                      'total': int(match[2]) if match else None,
                      'failed': int(match[3]) if match else None,
                      'skipped': int(skipped[1]) if skipped else 0,
                      'replaced': int(replaced[1]) if replaced else 0}
            results.append(result)
            if match is None:
                print(f'{suite}: no complete suite summary (exit {status})', flush=True)
    if args.report:
        args.report.write_text(json.dumps({'results': results}, indent=2) + '\n')
    passed = sum(item['passed'] or 0 for item in results)
    total = sum(item['total'] or 0 for item in results)
    print(f'{passed}/{total} passed in {time.monotonic() - started:.1f}s', flush=True)
    return 0 if all(item['failed'] == 0 and item['status'] == 0 for item in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
