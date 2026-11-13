#!/usr/bin/env python3
"""Audit a native bundle and run release smoke checks with an explicit compiler.

python3 scripts/check-a2-release.py BUNDLE --compiler COMPILER_DIR --report-dir OUTPUT --all-menus
The menu checks establish open-and-paint coverage, not complete application correctness.
Network checks use local servers; audio checks play the original bundled test tones.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def menu_choices():
    tree = ast.parse((ROOT / 'scripts/test-a2-desktop-input.py').read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'add_argument' and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == '--menu-app':
            return ast.literal_eval(next(k.value for k in node.keywords if k.arg == 'choices'))
    raise RuntimeError('Menu test choices not found')


def inventory(bundle):
    selected = {}
    for recipe in ('DarwinAArch64Compiler.txt', 'DarwinAArch64CompilerExtras.txt', 'DarwinAArch64DrawtermDesktop.txt'):
        for name in re.findall(r'([\w.-]+\.Mod)\b', (ROOT / 'build' / recipe).read_text()):
            selected.setdefault(name, []).append(recipe)
    objects = {p.stem for p in bundle.glob('*.GofAa')}
    commands = []
    for page in sorted((bundle / 'data').glob('NativeMenuPage*.XML')):
        for value in re.findall(r'<CommandString>(.*?)</CommandString>', page.read_text(), re.S):
            command = html.unescape(value.strip())
            first = re.match(r'([\w-]+)\.', command)
            module = first[1] if first else None
            commands.append({'page': page.name, 'command': command, 'module': module,
                             'object_present': module in objects if module else None})
    # Includes portable modules, architecture variants and hardware drivers:
    # absence from these recipes does not by itself mean a port is required.
    sources = [{'source': p.name, 'selected_by': selected.get(p.name, [])}
               for p in sorted((ROOT / 'source').glob('*.Mod'))]
    return {'object_modules': sorted(objects), 'object_count': len(objects),
            'source_files': sources, 'menu_commands': commands,
            'missing_menu_objects': [c for c in commands if c['object_present'] is False]}


def audit_binaries(bundle):
    details = []
    for name in ('a2', 'OberonLoader', 'drawterm', 'libA2Audio.dylib', 'libA2Radio.dylib'):
        path = bundle / name
        arch = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
        assert arch == 'arm64', (name, arch)
        loads = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
        dependencies = [line.strip().split(' (')[0] for line in loads]
        if name.endswith('.dylib'):
            assert dependencies.pop(0) == '@rpath/' + name, (name, dependencies)
        assert all(p.startswith(('/usr/lib/', '/System/Library/')) for p in dependencies), (name, dependencies)
        load_commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
        minimum = re.search(r'\bminos ([\d.]+)', load_commands)
        if minimum:
            assert tuple(map(int, minimum[1].split('.'))) <= (13, 0), (name, minimum[1])
        details.append({'file': name, 'architecture': arch, 'minimum_macos': minimum[1] if minimum else None,
                        'dependencies': dependencies})
    return details


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('bundle', type=Path)
    p.add_argument('--compiler', type=Path, required=True)
    p.add_argument('--report-dir', type=Path, required=True)
    p.add_argument('--all-menus', action='store_true')
    p.add_argument('--only', help='comma-separated check IDs; inventory/binary audit always runs')
    p.add_argument('--resume', action='store_true', help='reuse passed checks for identical binaries, test inputs and commands')
    args = p.parse_args()
    bundle, compiler, report_dir = args.bundle.resolve(), args.compiler.resolve(), args.report_dir.resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, A2_COMPILER_LIBRARY=str(compiler),
               A2_COMPILER_CORE=str(compiler / 'DarwinAosCompilerAa'), A2_LOADER=str(compiler / 'OberonLoader'),
               PYTHONPYCACHEPREFIX=str(report_dir / 'pycache'))
    fingerprint = hashlib.sha256()
    for directory in (bundle, compiler):
        for path in sorted(directory.glob('*')):
            if path.is_file() and (path.suffix in ('.GofAa', '.SymAa', '.dylib') or path.name in
                                  ('a2', 'OberonLoader', 'drawterm', 'DarwinAosCompilerAa', 'DarwinAosDrawtermDesktopAa')):
                fingerprint.update(path.name.encode()); fingerprint.update(path.read_bytes())
    for label, directory in (('data', bundle / 'data'), ('scripts', ROOT / 'scripts'), ('tests', ROOT / 'tests')):
        for path in sorted(directory.rglob('*')):
            if path.is_file() and (label == 'data' or path.suffix in ('.py', '.sh', '.Mod')):
                fingerprint.update(f'{label}/{path.relative_to(directory)}'.encode())
                fingerprint.update(path.read_bytes())
    identity = fingerprint.hexdigest()
    result_file = report_dir / 'checks.json'
    old = json.loads(result_file.read_text()) if args.resume and result_file.exists() else {}
    previous = {r['id']: r for r in old.get('checks', [])} if old.get('binary_fingerprint') == identity else {}
    report = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'tracked_source_dirty': subprocess.run(['git', 'diff', '--quiet', 'HEAD'], cwd=ROOT).returncode != 0,
              'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'started_utc': datetime.now(timezone.utc).isoformat(), 'binary_fingerprint': identity,
              'macos': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
              'architecture': os.uname().machine, 'checks': []}
    data = inventory(bundle)
    (report_dir / 'inventory.json').write_text(json.dumps(data, indent=2)+'\n')
    assert not data['missing_menu_objects'], data['missing_menu_objects']
    report['checks'] = list(previous.values())
    report['binaries'] = audit_binaries(bundle)
    base = [sys.executable, str(ROOT / 'scripts/test-a2-desktop-input.py'),
            '--loader', str(bundle / 'OberonLoader'), '--core', str(bundle / 'DarwinAosDrawtermDesktopAa')]
    checks = [(name, [sys.executable, str(ROOT / 'scripts' / f'test-a2-{name}.py'), str(bundle)], 90)
              for name in ('mp3', 'codecs', 'stations', 'globe-texture', 'native-audio')]
    checks += [(name, ['sh', str(ROOT / 'scripts' / f'test-a2-{name}.sh'), str(bundle)], 90)
               for name in ('network', 'crypto', 'browser')]
    checks += [('radio', [sys.executable, str(ROOT / 'scripts/test-a2-radio.py'), str(bundle), '--playback', '--stations'], 150),
               ('desktop-resize', [*base, '--resize', '--open-notepad', '--type-text', 'release resize test', '--timeout', '45'], 55),
               ('desktop-zoom', [*base, '--zoom', '--timeout', '35'], 45),
               ('desktop-clipboard', [*base, '--shell-command', 'NativeDesktopHello.Copy', '--expect-clipboard', 'copied from native A2', '--timeout', '40'], 50),
               ('desktop-compile', [*base, '--shell-command', 'Compiler.Compile -p=DarwinA2 NativeDesktopHello.Mod', '--expect-file', 'NativeDesktopHello.GofAa', '--timeout', '40'], 50),
               ('desktop-shutdown', [*base, '--tetris-shutdown', '--timeout', '45'], 55),
               ('globe-geometry', [*base, '--menu-app', 'radio-globe', '--radio-globe-regression', '--timeout', '120'], 135)]
    menus = menu_choices() if args.all_menus else ['pet', 'gui-builder', 'oberon', 'files', 'performance', 'image-viewer']
    checks += [('menu-' + menu, [*base, '--menu-app', menu, '--timeout', '40'], 50) for menu in menus]
    selected = set(args.only.split(',')) if args.only else None
    if selected:
        unknown = selected - {name for name, _, _ in checks}
        assert not unknown, f'Unknown check IDs: {sorted(unknown)}'
    for name, command, timeout in checks:
        if selected and name not in selected:
            continue
        if command[:len(base)] == base:
            work = report_dir / 'work' / name
            work.mkdir(parents=True, exist_ok=True)
            command = [*command, '--cwd', str(work)]
            if '--expect-file' in command:
                pos = command.index('--expect-file') + 1
                command[pos] = str(work / command[pos])
        if name in previous and previous[name]['status'] == 'passed' and previous[name]['command'] == command:
            print(f'REUSED PASS {name}', flush=True)
        else:
            print(f'CHECK {name}', flush=True)
            started = time.monotonic()
            log = report_dir / (name + '.log')
            with log.open('w') as out:
                try:
                    prepared = True
                    if name == 'desktop-clipboard':
                        prepare_env = dict(env, AOSCONFIG='Color 0 StackSize 8192',
                            OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'),
                            AOSPATH=f'{work}:{bundle}:{compiler}:{bundle / "data"}')
                        prepare = subprocess.run([str(compiler / 'OberonLoader'), 'compile', '-p=DarwinA2',
                            'NativeDesktopHello.Mod'], cwd=work, env=prepare_env, stdout=out,
                            stderr=subprocess.STDOUT, timeout=30)
                        prepared = prepare.returncode == 0 and (work / 'NativeDesktopHello.GofAa').exists()
                    if prepared:
                        run = subprocess.run(command, cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=timeout)
                        code = run.returncode
                    else:
                        out.write('Clipboard fixture did not compile\n'); code = 1
                except subprocess.TimeoutExpired:
                    out.write('\nRELEASE CHECK TIMEOUT\n'); code = None
            # The runtime sometimes reports traps without a nonzero process status.
            output = log.read_text(errors='replace')
            passed = code == 0 and not any(word in output for word in ('native signal ', 'Trap ', 'Traceback (most recent call last)'))
            item = {'id': name, 'status': 'passed' if passed else 'failed', 'exit_code': code,
                    'seconds': round(time.monotonic()-started, 2), 'command': command, 'log': log.name}
            report['checks'] = [r for r in report['checks'] if r['id'] != name] + [item]
            print(f'{item["status"].upper()} {name} ({item["seconds"]}s)', flush=True)
        result_file.write_text(json.dumps(report, indent=2)+'\n')
    count = sum(r['status'] == 'passed' for r in report['checks'])
    print(f'{count}/{len(report["checks"])} bundle checks passed; {data["object_count"]} object modules; report: {result_file}', flush=True)
    return 0 if count == len(report['checks']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
