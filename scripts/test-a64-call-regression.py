#!/usr/bin/env python3
"""Run the linked A64CallRegression fixture on macOS arm64.

Compile build/DarwinAArch64CallRegression.txt with the Fox host compiler first.
The raw linker log supplies entry offsets. Literal relocation detection is
specific to this self-contained fixture and the AArch64 backend's EmitAddress;
it is not a general object-file loader.
"""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
args = parser.parse_args()
data = args.binary.read_bytes()
log = args.binary.with_suffix('.log').read_text()
relocations = []
for offset in range(0, len(data) - 15, 4):
    instruction, branch = struct.unpack_from('<II', data, offset)
    if instruction & 0xffffffe0 == 0x58000040 and branch == 0x14000003:
        address, = struct.unpack_from('<Q', data, offset + 8)
        if address >= len(data):
            raise ValueError('fixture has an external absolute reference')
        relocations.append(hex(offset + 8))
with tempfile.TemporaryDirectory(prefix='a64-call-test-') as directory:
    executable = Path(directory) / 'probe'
    subprocess.run(['clang', '-O0', '-o', str(executable),
                    str(Path(__file__).with_name('a64-offset-probe.c'))], check=True)
    for name, expected in [('Scalars', 54321), ('Record', 4321), ('Nested', 13086), ('Narrow', 0), ('SignedShift', -5), ('MixedRecords', 0), ('MixedConstructed', 0), ('ValueArray', 187), ('Rotations', 0)]:
        match = re.search(r'([0-9A-Fa-f]+)H: code A64CallRegression\.' + name + r'\b', log)
        if not match:
            raise ValueError(f'missing entry {name}')
        print(f'{name}: expected {expected}', flush=True)
        subprocess.run([str(executable), str(args.binary.resolve()),
                        '0x' + match[1], str(expected), *relocations], check=True)
