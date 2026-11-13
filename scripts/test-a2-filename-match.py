#!/usr/bin/env python3
"""Check the actual UnixFiles matcher against wildcard cases on a 128 KiB worker stack."""
import argparse
import fnmatch
import itertools
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', type=Path, required=True)
args = parser.parse_args()
compiler = args.compiler.resolve()
repo = Path(__file__).resolve().parents[1]
# Exercise the private production procedure without adding an exported test API.
source = (repo / 'source/Unix.UnixFiles.Mod').read_text()
match = re.search(r'\tPROCEDURE Match\(.*?\tEND Match;', source, re.S).group()
names = [''.join(p) for n in range(4) for p in itertools.product('ab', repeat=n)]
patterns = [''.join(p) for n in range(4) for p in itertools.product('ab*', repeat=n)]
cases = [(n, p) for n in names for p in patterns]
randomizer = random.Random(112026)
cases += [(''.join(randomizer.choices('abc', k=randomizer.randrange(30))),
           ''.join(randomizer.choices('abc*', k=randomizer.randrange(30)))) for _ in range(300)]
cases += [('a' * 255, p) for p in ('*', '*b', 'a*', '**a***', '*a*a*a*b', 'a' * 255)]
checks = '\n'.join(f'Check("{n}", "{p}", {str(fnmatch.fnmatchcase(n, p)).upper()});' for n, p in cases)
module = '''MODULE NativeFilenameMatch;
IMPORT KernelLog;
''' + match + '''
PROCEDURE Check(CONST name, pattern: ARRAY OF CHAR; expected: BOOLEAN);
BEGIN ASSERT(Match(name, pattern, 0, 0) = expected) END Check;
TYPE Group = OBJECT
VAR done: BOOLEAN;
PROCEDURE Done;
BEGIN {EXCLUSIVE} done := TRUE END Done;
PROCEDURE Wait;
BEGIN {EXCLUSIVE} AWAIT(done) END Wait;
END Group;
Worker = OBJECT
VAR group: Group;
PROCEDURE &Init(owner: Group);
BEGIN group := owner END Init;
BEGIN {ACTIVE}
''' + checks + '''
group.Done
END Worker;
PROCEDURE Run*;
VAR worker: Worker; group: Group;
BEGIN
  NEW(group); NEW(worker, group); group.Wait;
  KernelLog.String("FILENAME MATCH PASS"); KernelLog.Ln
END Run;
END NativeFilenameMatch.
'''
with tempfile.TemporaryDirectory(prefix='a2-match-') as temporary:
    work = Path(temporary)
    (work / 'NativeFilenameMatch.Mod').write_text(module)
    env = dict(os.environ, AOSCONFIG='Color 0 StackSize 128',
               AOSPATH=f'{work}:{compiler}', OBERON_CORE=str(compiler / 'DarwinAosCompilerAa'))
    for command in (['compile', '-p=DarwinA2', 'NativeFilenameMatch.Mod'], ['do', 'NativeFilenameMatch.Run']):
        result = subprocess.run([str(compiler / 'OberonLoader'), *command], cwd=work,
                                env=env, capture_output=True, text=True, timeout=45)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and not any(s in output for s in ('Trap ', 'native signal ', 'error:', 'Command not successful')), output
    assert 'FILENAME MATCH PASS' in output, output
print(f'PASS: {len(cases)} wildcard cases, including 255-character names, on a 128 KiB active-object stack')
