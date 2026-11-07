#!/usr/bin/env python3
"""Exercise Cocoa mouse delivery before /dev/draw initializes the screen.

Requires a built, patched Cocoa drawterm checkout. Builds a temporary client;
never modifies that checkout or its production binary.
"""
import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkout', type=Path)
args = parser.parse_args()
root = args.checkout.resolve()
source = (root / 'gui-cocoa/screen.m').read_text()
anchor = '\tLOG(@"launch mainproc");'
assert source.count(anchor) == 1, 'Cocoa startup hook changed'
injection = '''
    if(gscreen != nil) _exit(2);
    NSEvent *early = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
        location:NSMakePoint(20,20) modifierFlags:0 timestamp:0
        windowNumber:[_window windowNumber] context:nil
        eventNumber:0 clickCount:0 pressure:0];
    [myview mouseMoved:early];
    [myview mouseDown:early];
    [myview mouseUp:early];
    NSLog(@"PASS: mouse events before screen initialization");
    _exit(0);
'''
with tempfile.TemporaryDirectory(prefix='drawterm-startup-') as tmp:
    tmp = Path(tmp)
    src, obj, binary = tmp/'screen.m', tmp/'screen.o', tmp/'drawterm'
    src.write_text(source.replace(anchor, injection + anchor))
    subprocess.run(['clang', '-c', '-O2', '-fobjc-arc', '-D_THREAD_SAFE', '-DPTHREAD',
                    '-I.', '-Iinclude', '-Ikern', str(src), '-o', str(obj)], cwd=root, check=True)
    dry = subprocess.check_output(['make', '-n', 'CONF=osx-cocoa', '-W',
                                   'gui-cocoa/libgui.a', 'drawterm'], cwd=root, text=True)
    link = next(shlex.split(line) for line in dry.splitlines() if ' -o drawterm ' in line)
    link[link.index('-o') + 1] = str(binary)
    link = [arg for arg in link if arg != 'gui-cocoa/libgui.a']
    link.insert(1, str(obj))
    subprocess.run(link, cwd=root, check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run([str(binary), '-D'], capture_output=True, text=True, timeout=20)
    print(result.stderr, end='')
    assert result.returncode == 0 and 'PASS:' in result.stderr, result.returncode
