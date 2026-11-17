#!/usr/bin/env python3
"""Compile and exercise CSP on native A2, without drawterm or external services."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    default_toolchain = ROOT / 'build/native-toolchain'
    if not default_toolchain.exists():
        default_toolchain = ROOT / 'build/native-compiler'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain', type=Path, default=default_toolchain)
    parser.add_argument('--repeat', type=int, default=5, help='independent native test runs (default: 5)')
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error('--repeat must be positive')
    toolchain = args.toolchain.resolve()
    loader = toolchain / 'OberonLoader'
    core = toolchain / 'DarwinAosCompilerAa'
    if not loader.is_file() or not core.is_file():
        parser.error(f'native compiler toolchain not found in {toolchain}')
    with tempfile.TemporaryDirectory(prefix='a2-csp-') as directory:
        work = Path(directory).resolve()
        env = dict(os.environ, PWD=str(work), AOSCONFIG='Color 0 StackSize 8192',
                   AOSPATH=f'{work}:{toolchain}:{ROOT / "source"}:{ROOT / "tests"}:{ROOT / "data"}',
                   OBERON_CORE=str(core))

        def run(*arguments):
            result = subprocess.run([str(loader), *arguments], cwd=work, env=env,
                                    capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            if result.returncode or any(marker in output for marker in
                    ('error:', 'Command not successful', 'native signal', 'Trap ')):
                raise RuntimeError(output)
            return output

        run('compile', '-b=AArch64', '--mergeSections', '--metaData=full',
            '--objectFileExtension=.GofAa', '--symbolFileExtension=.SymAa',
            '--define=UNIX,AARCH64,DESKTOP', 'CSP.Mod', 'CSPChannels.Mod', 'CSPDemo.Mod', 'CSPTests.Mod', 'CSPGenericPeer.Mod', 'CSPGenericTests.Mod')
        for name in ('CSP', 'CSPTests', 'CSPDemo', 'CSPGenericTests'):
            if not (work / (name + '.GofAa')).is_file():
                raise RuntimeError(f'{name} did not compile')
        if not (work / 'CSPChannels.SymAa').is_file():
            raise RuntimeError('generic template symbol file was not produced')
        print('PASS: CSP, generic channels, native tests and sieve compiled', flush=True)
        client = work / 'client'
        client.mkdir()
        (client / 'CSPTemplateOnlyProbe.Mod').write_text('''MODULE CSPTemplateOnlyProbe;
IMPORT CSP, Numbers := CSPChannels(SIGNED32), KernelLog;
PROCEDURE Run*;
VAR channel: Numbers.Channel; value: SIGNED32;
BEGIN
    NEW(channel, 1); ASSERT(channel.Send(42, NIL) = CSP.Success);
    ASSERT(channel.Receive(value, NIL) = CSP.Success); ASSERT(value = 42);
    KernelLog.String('TEMPLATE SYMBOLS PASS'); KernelLog.Ln
END Run;
END CSPTemplateOnlyProbe.
''')
        # A new specialization, with no repository source directories on AOSPATH.
        client_env = dict(env, PWD=str(client), AOSPATH=f'{client}:{work}:{toolchain}')
        for arguments in [('compile', '-b=AArch64', '--mergeSections', '--metaData=full',
                '--objectFileExtension=.GofAa', '--symbolFileExtension=.SymAa',
                '--define=UNIX,AARCH64,DESKTOP', 'CSPTemplateOnlyProbe.Mod'),
                ('do', 'CSPTemplateOnlyProbe.Run')]:
            result = subprocess.run([str(loader), *arguments], cwd=client, env=client_env,
                                    capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            if result.returncode or any(marker in output for marker in
                    ('error:', 'Command not successful', 'native signal', 'Trap ')):
                raise RuntimeError(output)
        if 'TEMPLATE SYMBOLS PASS' not in output:
            raise RuntimeError(output)
        print('PASS: new specialization compiled and ran using template symbols only', flush=True)
        negative_cases = {
            'WrongSend': 'result := numbers.Send(request, NIL)',
            'WrongReceive': 'result := requests.Receive(number, NIL)',
            'WrongOfferResult': 'offer := requests.ReceiveOffer(); ok := offer.Get(number)',
            'WrongChannel': 'requests := numbers',
            'WrongObject': 'result := objects.Send(response, NIL)',
        }
        for suffix, statement in negative_cases.items():
            name = 'CSPReject' + suffix
            (work / (name + '.Mod')).write_text(f'''MODULE {name};
IMPORT CSP, Numbers := CSPChannels(SIGNED64), Requests := CSPChannels(Request),
    Objects := CSPChannels(Message);
TYPE Request = RECORD id: SIGNED32 END;
    Message = OBJECT END Message;
    Response = OBJECT END Response;
PROCEDURE Run*;
VAR numbers: Numbers.Channel; requests: Requests.Channel; objects: Objects.Channel;
    request: Request; response: Response; number: SIGNED64; offer: Requests.Offer;
    result: SIGNED32; ok: BOOLEAN;
BEGIN {statement} END Run;
END {name}.
''')
            result = subprocess.run([str(loader), 'compile', '-b=AArch64', '--mergeSections',
                '--metaData=full', '--objectFileExtension=.GofAa', '--symbolFileExtension=.SymAa',
                '--define=UNIX,AARCH64,DESKTOP', name + '.Mod'], cwd=work, env=env,
                capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            if ('error:' not in output or 'incompatible' not in output or
                    any(marker in output for marker in ('native signal', 'Trap ')) or
                    (work / (name + '.GofAa')).exists()):
                raise RuntimeError(f'Expected a type-checking error for {suffix}:\n{output}')
            print(f'PASS: compiler rejected {suffix}', flush=True)
        for iteration in range(args.repeat):
            output = run('do', 'CSPTests.Run ~ CSPGenericTests.Run ~')
            if ('CSP TESTS PASS' not in output or 'GENERIC CSP TESTS PASS' not in output or
                    output.count('CSP PASS ') != 14):
                raise RuntimeError(output)
            print(f'PASS: native CSP suite {iteration + 1}/{args.repeat}', flush=True)
        output = run('do', 'CSPTests.Run ~ CSPGenericTests.Run ~ CSPTests.Run ~ CSPGenericTests.Run ~')
        if output.count('CSP TESTS PASS') != 4:
            raise RuntimeError(output)
        print('PASS: two suites reused one process and coordinator', flush=True)
        output = run('do', 'CSPDemo.Run 50')
        if ('2 3 5 7 11 13 17 19 23 29 31 37 41 43 47' not in output or
                'CSP sieve finished; all filter activities joined' not in output):
            raise RuntimeError(output)
        print('PASS: rendezvous sieve produced 15 primes; all filter activities joined', flush=True)


if __name__ == '__main__':
    main()
