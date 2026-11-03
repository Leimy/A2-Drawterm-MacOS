#!/usr/bin/env python3
"""Compile, link, dynamically load and execute Oberon using only native macOS tools."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--library', type=Path)
    args = parser.parse_args()
    command = [sys.executable, str(ROOT / 'scripts' / 'run-a2-native.py')]
    if args.core: command += ['--core', str(args.core.resolve())]
    if args.library: command += ['--library', str(args.library.resolve())]
    with tempfile.TemporaryDirectory(prefix='native-a2-test-') as directory:
        work = Path(directory)
        def run(*arguments):
            try:
                result = subprocess.run([*command, *arguments], cwd=work, check=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            except subprocess.CalledProcessError as error:
                print(error.stdout, end='', flush=True)
                raise
            print(result.stdout, end='', flush=True)
            return result.stdout
        run('compile', 'NativeBuildHello.Mod', 'NativeClockGCRegression.Mod', 'ConcurrentSieve.Mod', 'A64NilTypeTest.Mod',
            'A64SignedConversionTest.Mod', 'A64BitcastTest.Mod', 'A64CallingConventionTest.Mod',
            'A64AddressLoweringTest.Mod', 'A64CompositeReturnTest.Mod', 'A64InlineCodeTest.Mod',
            'A64InlineEmpty.Mod', 'A64InlineConstant.Mod', 'A64InlineConstantUse.Mod',
            'FoxAArch64InstructionSetTest.Mod', 'A64ComplexRegression.Mod')
        for module in ['NativeBuildHello', 'NativeClockGCRegression', 'ConcurrentSieve', 'A64NilTypeTest',
                       'A64SignedConversionTest', 'A64BitcastTest', 'A64CallingConventionTest',
                       'A64AddressLoweringTest', 'A64CompositeReturnTest', 'A64InlineCodeTest',
                       'A64InlineEmpty', 'A64InlineConstant', 'A64InlineConstantUse',
                       'FoxAArch64InstructionSetTest', 'A64ComplexRegression']:
            assert (work / (module + '.GofAa')).is_file(), f'{module} was not compiled locally'
        output = run('do', 'NativeBuildHello.Run ~ NativeClockGCRegression.Run ~ A64NilTypeTest.Run ~ A64SignedConversionTest.Run ~ '
                     'A64BitcastTest.Run ~ A64CallingConventionTest.Run ~ A64CompositeReturnTest.Run ~ '
                     'A64InlineCodeTest.Run ~ A64InlineEmpty.Run ~ A64InlineConstantUse.Run ~ '
                     'FoxAArch64InstructionSetTest.Run ~ A64ComplexRegression.Run ~ '
                     'ConcurrentSieve.Run 50 ~ System.Wait 1000 ~')
        assert 'Native Mac build: answer = 42' in output
        assert 'Native clock/GC: 256 reads, 16 collections OK' in output
        assert 'NIL type test passed' in output
        assert 'negated NIL type test passed' in output
        assert 'base type test passed' in output
        assert 'child type test passed' in output
        assert 'NIL object type tests passed' in output
        assert 'signed float conversion tests passed' in output
        assert 'SYSTEM.VAL bitcast tests passed' in output
        assert 'AArch64 calling convention tests passed' in output
        assert 'portable composite returns passed' in output
        assert 'AArch64 inline code passed' in output
        assert 'empty AArch64 inline passed' in output
        assert 'exported AArch64 inline constant passed' in output
        assert 'AArch64 instruction encoding tests passed' in output
        assert 'AArch64 complex operators passed' in output
        assert '2 3 5 7 11 13 17 19 23 29 31 37 41 43 47' in output
        # A bare platform keeps per-procedure sections for the C ABI fixture;
        # the normal A2 platform merges sections and supplies GC metadata.
        (work / 'Regression.txt').write_text(
            'Compiler.AddPlatform RawTest "-b=AArch64 --objectFileExtension=.GofAa --symbolFileExtension=.SymAa" ~\n'
            'Compiler.Compile -p=RawTest A64CallRegression.Mod ~\n'
            'Linker.Link --extension=.GofAa --fileName=A64CallRegression.bin --linkRoot=A64CallRegression A64CallRegression\n')
        run('execute', 'Regression.txt')
        subprocess.run([sys.executable, str(ROOT / 'scripts' / 'test-a64-call-regression.py'),
                        str(work / 'A64CallRegression.bin')], check=True, timeout=60)
    print('PASS: native compiler, linker, dynamic loading, clock/GC, complex operators, active objects, NIL type tests, '
          'signed conversion, SYSTEM.VAL bitcasts, calling conventions, composite returns, inline code, literal addresses, '
          'instruction encodings, and nine code-generation regressions')

if __name__ == '__main__':
    main()
