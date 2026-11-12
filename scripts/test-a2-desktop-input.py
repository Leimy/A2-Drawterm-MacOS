#!/usr/bin/env python3
"""Exercise native A2 window events with a small simulated drawterm 9P server.

This verifies the A2 event path; use run-a2-drawterm-probe.py for real drawterm.
"""
import argparse
import hashlib
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import time


def packet(kind, tag, payload=b''):
    return struct.pack('<IBH', 7 + len(payload), kind, tag) + payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--loader', required=True)
    parser.add_argument('--core', required=True)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--open-notepad', action='store_true')
    parser.add_argument('--type-text', default='', help='type into Notepad after opening it')
    parser.add_argument('--paint-stats', action='store_true', help='report framebuffer upload bytes and partial-width rectangles')
    parser.add_argument('--capture', type=Path, help='save the final framebuffer as a PPM')
    parser.add_argument('--resize', action='store_true', help='shrink/grow the screen before exercising widgets')
    parser.add_argument('--resize-menu', nargs='?', const='shrink', choices=['shrink', 'grow'],
                        help='resize, then open a menu app at the new bottom edge')
    parser.add_argument('--shutdown', action='store_true', help='click System > Shutdown and require A2 to exit')
    parser.add_argument('--zoom', action='store_true', help='send Meta+PageUp and require a changed desktop framebuffer')
    parser.add_argument('--zoom-wheel', action='store_true', help='send Meta+wheel and require a changed desktop framebuffer')
    parser.add_argument('--zoom-button', action='store_true', help='click the native desktop Zoom in button')
    parser.add_argument('--tetris', action='store_true', help='click Demos > Tetris and require a painted game window')
    parser.add_argument('--tetris-play', action='store_true', help='start Tetris with Space and require an updated game board')
    parser.add_argument('--tetris-shutdown', action='store_true', help='start Tetris, then shut A2 down from the menu')
    parser.add_argument('--three-d-zoom', action='store_true', help='right-drag in Demos > 3D Explorer and require the scene to change')
    parser.add_argument('--radio-globe-regression', action='store_true', help='check polar rendering, inertia, friction, grab and close')
    parser.add_argument('--radio-globe-interaction', action='store_true', help='drag and wheel Demos > RadioGlobe and require the Earth to change')
    parser.add_argument('--radio-globe-audio', action='store_true', help='click RadioGlobe Play radio and Stop and require streaming playback logs')
    parser.add_argument('--menu-app', choices=['tetris', 'oberon', 'log', 'clock', 'calendar', 'shell', 'files', 'tutorial', 'chinese-tutorial', 'pet', 'search', 'scribble', 'bunny', '3d-explorer', 'turing', 'radio-globe', 'mandelbrot', 'figures', 'text-writer', 'image-grid', 'audio-test', 'audio-mixer', 'hex-editor', 'key-codes', 'color-picker', 'text-styles', 'image-viewer', 'graph-demos', 'drawing-overlay', 'on-screen-message', 'module-state', 'backdrops', 'gfx-spiral', 'slideshow', 'task-scheduler', 'performance', 'ftp-client', 'skin-editor', 'interpreter-shell', 'gui-builder', 'skin-chooser', 'desktop-icon', 'input-methods', 'language', 'window-switcher', 'web-browser'],
                        help='click a native A2 menu application and inspect the resulting window')
    parser.add_argument('--backdrop-select', action='store_true',
                        help='select Mars in the Backdrops picker and require the desktop background to change')
    parser.add_argument('--shell-command', help='type a command into BlueShell and wait for its effect')
    parser.add_argument('--paste-shell-command', action='store_true', help='paste --shell-command through drawterm /dev/snarf')
    parser.add_argument('--pie-shell-command', action='store_true', help='paste --shell-command through BlueShell pie menu')
    parser.add_argument('--expect-file', type=Path, help='require this file after the shell command')
    parser.add_argument('--expect-log', help='require this line in the A2 log after the shell command')
    parser.add_argument('--expect-clipboard', help='require this text in drawterm /dev/snarf after the shell command')
    parser.add_argument('--expect-window', action='store_true', help='require the shell command to paint a new window')
    parser.add_argument('--command-settle', type=float, default=1, help='seconds to wait after sending a shell command')
    parser.add_argument('--pet-compile', action='store_true', help='click PET Compile after opening a source file')
    parser.add_argument('--cwd', type=Path, help='working directory for A2')
    args = parser.parse_args()
    if args.shell_command and args.menu_app not in (None, 'shell'):
        parser.error('--shell-command requires --menu-app shell')
    if (args.expect_file or args.expect_log or args.expect_clipboard or args.expect_window) and not args.shell_command:
        parser.error('shell expectations require --shell-command')
    if args.pet_compile and not args.shell_command:
        parser.error('--pet-compile requires --shell-command')
    if (args.paste_shell_command or args.pie_shell_command) and not args.shell_command:
        parser.error('paste modes require --shell-command')
    if args.paste_shell_command and args.pie_shell_command:
        parser.error('choose one paste mode')
    if args.resize_menu and args.resize:
        parser.error('choose one resize mode')
    if args.backdrop_select and args.menu_app != 'backdrops':
        parser.error('--backdrop-select requires --menu-app backdrops')
    if args.three_d_zoom and args.menu_app != '3d-explorer':
        parser.error('--three-d-zoom requires --menu-app 3d-explorer')
    if args.radio_globe_interaction and args.menu_app != 'radio-globe':
        parser.error('--radio-globe-interaction requires --menu-app radio-globe')
    if args.radio_globe_audio and args.menu_app != 'radio-globe':
        parser.error('--radio-globe-audio requires --menu-app radio-globe')
    radio_checks = None
    if args.radio_globe_regression:
        if args.menu_app != 'radio-globe' or args.radio_globe_interaction:
            parser.error('--radio-globe-regression requires --menu-app radio-globe without --radio-globe-interaction')
        from a2_radio_globe_checks import RadioGlobeChecks
        radio_checks = RadioGlobeChecks(args.capture)
    host, guest = socket.socketpair()
    env = os.environ.copy()
    core_dir = Path(args.core).resolve().parent
    env.update(OBERON_CORE=str(Path(args.core).resolve()), A2_DRAWTERM_FD=str(guest.fileno()),
               AOSPATH=os.pathsep.join([str(core_dir), str((args.cwd or Path.cwd()).resolve()), str(core_dir / 'data')]))
    process = subprocess.Popen([str(Path(args.loader).resolve())], env=env, cwd=args.cwd,
                               pass_fds=(guest.fileno(),),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    guest.close()
    selector = selectors.DefaultSelector()
    selector.register(host, selectors.EVENT_READ, '9p')
    selector.register(process.stdout, selectors.EVENT_READ, 'log')
    incoming = bytearray(); output = ''; ready = False; mouse_tag = None; keyboard_tag = None; next_event = 0; keyboard_sent = False
    cursor_hidden = False
    buttons = [0, 1, 0, 1, 0]; event_index = 0; flushes = 0
    editor_event = 0; editor_ready = None; last_paint = 0
    focus_event = 0; typed = 0; typing_done = None
    screen_width, screen_height = 1024, 768
    origin_x = origin_y = 0
    upload_bytes = upload_count = partial_uploads = full_strip_bytes = 0
    pixels = bytearray(screen_width * screen_height * 3)
    resize_sizes = ([(640, 480), (1280, 900), (800, 600), (1024, 768)] if args.resize else
                    [(640, 480)] if args.resize_menu == 'shrink' else
                    [(1280, 900)] if args.resize_menu == 'grow' else [])
    resize_index = 0; resize_pending = False; stale_screen = False
    resize_log_start = 0; resize_flushes = 0; resize_event_due = None
    stale_errors = 0; editor_resized = False; editor_pixels = None
    shutdown_events = [(75, 718, 0), (75, 718, 1), (75, 718, 0),
                       (90, 756, 0), (90, 756, 1), (90, 756, 0)]
    shutdown_index = 0
    zoom_keys = [b'r' + chr(0xF868).encode() + b'\0',
                 b'r' + chr(0xF00F).encode() + b'\0',
                 b'R' + chr(0xF00F).encode() + b'\0',
                 b'R' + chr(0xF868).encode() + b'\0']
    if args.zoom_wheel: zoom_keys = [zoom_keys[0], zoom_keys[-1]]
    zoom_index = 0; zoom_initial = None; zoom_flushes = 0; zoom_sent_at = None; wheel_index = 0
    zoom_button_index = 0
    menu_app = 'tetris' if args.tetris or args.tetris_play or args.tetris_shutdown else ('shell' if args.shell_command else (args.menu_app or ('clock' if args.resize_menu else None)))
    play_tetris = args.tetris_play or args.tetris_shutdown
    menu_position = {'tetris': (150, 90, 738), 'oberon': (150, 90, 756), 'log': (75, 90, 738),
                     'clock': (75, 270, 738), 'calendar': (75, 270, 756),
                     'shell': (25, 270, 756), 'files': (114, 90, 738),
                     'tutorial': (114, 270, 738), 'chinese-tutorial': (114, 270, 756),
                     'pet': (205, 90, 738), 'search': (270, 90, 738),
                     'scribble': (150, 270, 738), 'bunny': (150, 270, 756),
                     '3d-explorer': (150, 450, 738), 'turing': (150, 450, 756),
                     'radio-globe': (150, 630, 738), 'mandelbrot': (150, 630, 756),
                     'figures': (150, 750, 738), 'text-writer': (150, 750, 756),
                     'image-grid': (150, 900, 738), 'audio-test': (150, 900, 756),
                     'audio-mixer': (270, 810, 756),
                     'hex-editor': (205, 630, 738), 'key-codes': (205, 630, 756),
                     'color-picker': (270, 630, 738), 'text-styles': (270, 630, 756),
                     'image-viewer': (340, 90, 738), 'graph-demos': (340, 90, 756),
                     'drawing-overlay': (340, 270, 738), 'on-screen-message': (340, 270, 756),
                     'module-state': (340, 450, 738), 'backdrops': (340, 450, 756),
                     'gfx-spiral': (340, 630, 738), 'slideshow': (340, 630, 756),
                     'task-scheduler': (75, 450, 738), 'performance': (75, 450, 756),
                     'ftp-client': (270, 810, 738), 'skin-editor': (370, 270, 756),
                     'interpreter-shell': (205, 810, 738),
                     'gui-builder': (370, 90, 738), 'skin-chooser': (370, 90, 756),
                     'desktop-icon': (370, 270, 738),
                     'input-methods': (370, 630, 738), 'language': (370, 630, 756),
                     'window-switcher': (370, 810, 738), 'web-browser': (270, 450, 756)}
    tab_x, button_x, button_y = menu_position.get(menu_app, (150, 90, 738))
    menu_offset_y = resize_sizes[-1][1] - 768 if args.resize_menu else 0
    tetris_events = [(tab_x, 718 + menu_offset_y, 0), (tab_x, 718 + menu_offset_y, 1), (tab_x, 718 + menu_offset_y, 0),
                     (button_x, button_y + menu_offset_y, 0), (button_x, button_y + menu_offset_y, 1), (button_x, button_y + menu_offset_y, 0)]
    if menu_app == 'files':
        tetris_events.extend([(80, 139, 0), (80, 139, 1), (80, 139, 0)])
    tetris_index = 0; tetris_initial = None; tetris_flushes = 0; tetris_sent_at = None
    backdrop_index = 0; backdrop_pixel_before = None; backdrop_sent_at = None
    three_d_drag_index = 0; three_d_drag_before = None; three_d_drag_sent_at = None
    three_d_drag_events = [(350, 300, 0), (350, 300, 4), (350, 450, 4), (350, 450, 0)]
    radio_drag_index = 0; radio_drag_before = None; radio_drag_sent_at = None
    radio_drag_events = [(400, 300, 0), (400, 300, 1), (470, 320, 1), (470, 320, 0)]
    radio_wheel_index = 0; radio_wheel_before = None; radio_wheel_sent_at = None
    radio_audio_events = [(130, 560, 0), (130, 560, 1), (130, 560, 0),
                          (230, 560, 0), (230, 560, 1), (230, 560, 0)]
    radio_audio_index = 0
    tetris_start_sent = False; tetris_game_initial = None; tetris_game_flushes = 0; tetris_game_at = None
    shell_text = ('\n' if args.paste_shell_command or args.pie_shell_command else args.shell_command + '\n') if args.shell_command else ''
    shell_typed = 0; shell_done = None; shell_pasted = False; shell_window_initial = None; pet_click_index = 0
    clipboard_text = args.shell_command.encode() if args.paste_shell_command or args.pie_shell_command else b''
    pie_events = [(300, 200, 0), (300, 200, 4), (360, 200, 4), (360, 200, 0)]
    pie_index = 0
    qid = struct.pack('<BIQ', 0, 0, 1)
    fields = [1, 0, 'a8r8g8b8', 0, 0, 0, 1024, 768, 0, 0, 1024, 768]
    control = ''.join(f'{value:>11} ' for value in fields).encode()
    deadline = time.monotonic() + args.timeout
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(0.05):
                if key.data == 'log':
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        if (args.shutdown or args.tetris_shutdown) and shutdown_index == len(shutdown_events) and 'System event log shut down' in output:
                            print('PASS: System > Shutdown exited the native A2 process')
                            return
                        raise RuntimeError('A2 exited before completing the input test')
                    text = data.decode(errors='replace'); print(text, end='', flush=True); output += text
                    if ('native signal ' in output and 'fault=' in output and output.endswith('\n')) or 'Trap ' in output:
                        raise RuntimeError('A2 trapped')
                    if 'drawterm display failed:' in output and output.endswith('\n'):
                        raise RuntimeError('A2 lost the display connection')
                    ready = 'drawterm desktop initialized' in output
                    if ready and not cursor_hidden:
                        raise RuntimeError('A2 did not hide the overlapping drawterm host cursor')
                    if 'A2 Notepad opened' in output and editor_ready is None:
                        editor_ready = time.monotonic()
                    if 'A2 button clicks: 3' in output and not args.open_notepad and not args.shutdown and not args.zoom and not args.zoom_wheel and not args.zoom_button and menu_app is None:
                        if flushes < 2: raise RuntimeError('window was not repainted')
                        print('PASS: two mouse clicks and one keyboard activation through A2 widgets')
                        return
                else:
                    data = host.recv(65536)
                    if not data:
                        if (args.shutdown or args.tetris_shutdown) and shutdown_index == len(shutdown_events) and 'System event log shut down' in output:
                            process.wait(timeout=2)
                            if process.returncode != 0: raise RuntimeError(f'A2 shutdown returned {process.returncode}')
                            print('PASS: System > Shutdown exited the native A2 process')
                            return
                        raise RuntimeError('A2 closed the device connection')
                    incoming.extend(data)
                    while len(incoming) >= 7:
                        size, kind, tag = struct.unpack_from('<IBH', incoming)
                        if len(incoming) < size: break
                        body = bytes(incoming[7:size]); del incoming[:size]
                        if kind == 100:
                            response = struct.pack('<I', 32768) + struct.pack('<H', 6) + b'9P2000'
                        elif kind == 104: response = qid
                        elif kind == 110:
                            count, = struct.unpack_from('<H', body, 8)
                            response = struct.pack('<H', count) + qid * count
                        elif kind == 112:
                            fid, = struct.unpack_from('<I', body)
                            if fid == 2: stale_screen = False
                            response = qid + struct.pack('<I', 0)
                        elif kind == 116:
                            fid, offset, count = struct.unpack('<IQI', body)
                            if fid == 2:
                                response = struct.pack('<I', len(control)) + control
                            elif fid == 4:
                                mouse_tag = tag; continue
                            elif fid == 5:
                                keyboard_tag = tag; continue
                            elif fid == 7:
                                content = clipboard_text[offset:offset + count]
                                response = struct.pack('<I', len(content)) + content
                            else: raise RuntimeError(f'unexpected read fid {fid}')
                        elif kind == 118:
                            fid, offset, count = struct.unpack_from('<IQI', body)
                            draw = body[16:]
                            if fid == 6:
                                if count != 72 or draw != bytes(72):
                                    raise RuntimeError('invalid drawterm host cursor mask')
                                cursor_hidden = True
                            if fid == 7:
                                clipboard_text = draw
                            if fid == 3 and stale_screen:
                                stale_errors += 1
                                error = b'named image no longer valid'
                                host.sendall(packet(107, tag, struct.pack('<H', len(error)) + error))
                                continue
                            if draw == b'v': flushes += 1; last_paint = time.monotonic()
                            if draw[:1] == b'y':
                                image_id, left, top, right, bottom = struct.unpack_from('<Iiiii', draw, 1)
                                left -= origin_x; right -= origin_x
                                top -= origin_y; bottom -= origin_y
                                if image_id != 0 or not (0 <= left <= right <= screen_width and 0 <= top <= bottom <= screen_height):
                                    raise RuntimeError('invalid framebuffer upload')
                                width = right - left
                                upload_count += 1; upload_bytes += width * (bottom - top) * 4
                                full_strip_bytes += screen_width * (bottom - top) * 4
                                partial_uploads += width < screen_width
                                if len(draw) != 21 + width * (bottom - top) * 4:
                                    raise RuntimeError('invalid framebuffer byte count')
                                for row in range(top, bottom):
                                    source = 21 + (row - top) * width * 4
                                    bgra = draw[source:source + width * 4]
                                    rgb = bytearray(width * 3)
                                    rgb[0::3], rgb[1::3], rgb[2::3] = bgra[2::4], bgra[1::4], bgra[0::4]
                                    start = (row * screen_width + left) * 3
                                    pixels[start:start + width * 3] = rgb
                            response = struct.pack('<I', count)
                        elif kind in (108, 120): response = b''
                        else: raise RuntimeError(f'unexpected 9P request {kind}')
                        host.sendall(packet(kind + 1, tag, response))
            if resize_pending and f'drawterm resized: {screen_width}x{screen_height}' in output[resize_log_start:]:
                if flushes <= resize_flushes: raise RuntimeError('resize did not repaint the screen')
                resize_pending = False; resize_index += 1
                print(f'PASS: resized and repainted {screen_width}x{screen_height}', flush=True)
            if ready and resize_index < len(resize_sizes) and not resize_pending and mouse_tag is not None:
                screen_width, screen_height = resize_sizes[resize_index]
                origin_x, origin_y = (17, 23) if resize_index % 2 == 0 else (0, 0)
                fields = [1, 0, 'a8r8g8b8', 0, origin_x, origin_y, origin_x + screen_width, origin_y + screen_height,
                          origin_x, origin_y, origin_x + screen_width, origin_y + screen_height]
                control = ''.join(f'{value:>11} ' for value in fields).encode()
                pixels = bytearray(screen_width * screen_height * 3)
                stale_screen = True; resize_pending = True; resize_log_start = len(output); resize_flushes = flushes
                # Force a cursor repaint against the invalidated screen before
                # delivering r, reproducing the upload/resize race deterministically.
                resize_event_due = time.monotonic() + 0.3
                event = ('m' + ''.join(f'{n:11d} ' for n in [55 + resize_index, 55 + resize_index, 0, resize_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None
            if resize_event_due is not None and mouse_tag is not None and time.monotonic() >= resize_event_due:
                event = ('r' + ''.join(f'{n:11d} ' for n in [origin_x, origin_y, 0, resize_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; resize_event_due = None
            if (args.shutdown or (args.tetris_shutdown and tetris_game_at is not None and time.monotonic() - tetris_game_at > 2)) and ready and mouse_tag is not None and shutdown_index < len(shutdown_events) and time.monotonic() >= next_event:
                x, y, button = shutdown_events[shutdown_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [x, y, button, shutdown_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; shutdown_index += 1; next_event = time.monotonic() + 0.4
            if menu_app is not None and ready and resize_index == len(resize_sizes) and not resize_pending and mouse_tag is not None and tetris_index < len(tetris_events) and time.monotonic() >= next_event:
                if tetris_initial is None:
                    tetris_initial = hashlib.sha256(pixels).digest(); tetris_flushes = flushes
                x, y, button = tetris_events[tetris_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [x, y, button, tetris_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; tetris_index += 1; next_event = time.monotonic() + 0.4
                if tetris_index == len(tetris_events): tetris_sent_at = time.monotonic()
            if menu_app is not None and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > (12 if menu_app == 'oberon' else 2):
                if menu_app == 'tetris' and 'WMTetris opened' not in output:
                    raise RuntimeError('Demos > Tetris did not invoke WMTetris.Open')
                if menu_app == 'oberon' and 'Oberon started' not in output:
                    raise RuntimeError('Oberon system did not finish starting')
                if 'WMComponents.Call error' in output or 'GofAa not found' in output:
                    raise RuntimeError(f'{menu_app} menu command failed')
                if flushes <= tetris_flushes or hashlib.sha256(pixels).digest() == tetris_initial:
                    raise RuntimeError(f'{menu_app} did not paint a window')
                if menu_app == 'oberon' and pixels[(200 * screen_width + 200) * 3] < 200:
                    raise RuntimeError('Oberon viewer area is still blank')
                if not play_tetris and not args.shell_command and not args.backdrop_select and not args.three_d_zoom and not args.radio_globe_interaction and not args.radio_globe_regression and not args.radio_globe_audio:
                    if menu_app == 'mandelbrot' and 'Mandelbrot render complete' not in output:
                        continue
                    if menu_app == 'audio-test' and 'Native MP3 playback complete' not in output:
                        continue
                    print(f'PASS: {menu_app} menu command painted a window')
                    return
            if args.three_d_zoom and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and three_d_drag_index < len(three_d_drag_events) and mouse_tag is not None and time.monotonic() >= next_event:
                if three_d_drag_before is None:
                    three_d_drag_before = hashlib.sha256(b''.join(pixels[(y * screen_width + 300) * 3:(y * screen_width + 420) * 3] for y in range(250, 440))).digest()
                x, y, button = three_d_drag_events[three_d_drag_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [x, y, button, 8000 + three_d_drag_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; three_d_drag_index += 1; next_event = time.monotonic() + 0.4
                if three_d_drag_index == len(three_d_drag_events): three_d_drag_sent_at = time.monotonic()
            if three_d_drag_sent_at is not None and time.monotonic() - three_d_drag_sent_at > 1:
                three_d_drag_after = hashlib.sha256(b''.join(pixels[(y * screen_width + 300) * 3:(y * screen_width + 420) * 3] for y in range(250, 440))).digest()
                if three_d_drag_after == three_d_drag_before:
                    raise RuntimeError('right-button drag did not zoom the 3D scene')
                print('PASS: right-button drag zoomed the 3D scene')
                return
            if radio_checks is not None and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2:
                mouse, done = radio_checks.step(pixels, screen_width, mouse_tag is not None)
                if done:
                    return
                if mouse is not None:
                    event = ('m' + ''.join(f'{n:11d} ' for n in [*mouse, int(time.monotonic()*1000) % 10000000])).encode()
                    host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                    mouse_tag = None
            if args.radio_globe_audio and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2:
                if radio_audio_index == 3 and ('Radio playing' not in output or 'Radio title:' not in output):
                    continue
                if radio_audio_index < len(radio_audio_events) and mouse_tag is not None and time.monotonic() >= next_event:
                    mouse = radio_audio_events[radio_audio_index]
                    event = ('m' + ''.join(f'{n:11d} ' for n in [*mouse, int(time.monotonic()*1000) % 10000000])).encode()
                    host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                    mouse_tag = None; radio_audio_index += 1; next_event = time.monotonic() + 0.3
                if radio_audio_index == len(radio_audio_events) and 'Radio stopped' in output:
                    if 'DarwinSound error' in output:
                        raise RuntimeError('Native audio failed during RadioGlobe playback')
                    print('PASS: RadioGlobe Play radio and Stop streamed audio with ICY metadata')
                    return
            if args.radio_globe_interaction and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and radio_drag_index < len(radio_drag_events) and mouse_tag is not None and time.monotonic() >= next_event:
                if radio_drag_before is None:
                    radio_drag_before = hashlib.sha256(b''.join(pixels[(y * screen_width + 200) * 3:(y * screen_width + 350) * 3] for y in range(170, 450))).digest()
                x, y, button = radio_drag_events[radio_drag_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [x, y, button, 10000 + radio_drag_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; radio_drag_index += 1; next_event = time.monotonic() + 0.4
                if radio_drag_index == len(radio_drag_events): radio_drag_sent_at = time.monotonic()
            if radio_drag_sent_at is not None and time.monotonic() - radio_drag_sent_at > 1:
                radio_drag_after = hashlib.sha256(b''.join(pixels[(y * screen_width + 200) * 3:(y * screen_width + 350) * 3] for y in range(170, 450))).digest()
                if radio_drag_after == radio_drag_before:
                    raise RuntimeError('left-button drag did not rotate the RadioGlobe')
                radio_wheel_before = radio_drag_after; radio_drag_sent_at = None
            if radio_wheel_before is not None and radio_wheel_index < 2 and mouse_tag is not None and time.monotonic() >= next_event:
                event = ('m' + ''.join(f'{n:11d} ' for n in [470, 320, [16, 0][radio_wheel_index], 12000 + radio_wheel_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; radio_wheel_index += 1; next_event = time.monotonic() + 0.4
                if radio_wheel_index == 2: radio_wheel_sent_at = time.monotonic()
            if radio_wheel_sent_at is not None and time.monotonic() - radio_wheel_sent_at > 1:
                radio_wheel_after = hashlib.sha256(b''.join(pixels[(y * screen_width + 200) * 3:(y * screen_width + 350) * 3] for y in range(170, 450))).digest()
                if radio_wheel_after == radio_wheel_before:
                    raise RuntimeError('wheel did not zoom the RadioGlobe')
                print('PASS: left-button drag rotated and wheel zoomed the RadioGlobe')
                return
            if args.backdrop_select and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and backdrop_index < 3 and mouse_tag is not None and time.monotonic() >= next_event:
                if backdrop_index == 0:
                    sample = (300 * screen_width + 800) * 3
                    backdrop_pixel_before = bytes(pixels[sample:sample + 3])
                button = [0, 1, 0][backdrop_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [350, 410, button, 7000 + backdrop_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; backdrop_index += 1; next_event = time.monotonic() + 0.4
                if backdrop_index == 3: backdrop_sent_at = time.monotonic()
            if backdrop_sent_at is not None and time.monotonic() - backdrop_sent_at > 3:
                sample = (300 * screen_width + 800) * 3
                if bytes(pixels[sample:sample + 3]) == backdrop_pixel_before:
                    raise RuntimeError('Backdrops picker did not change the desktop background')
                if 'No decoder found' in output or 'could not be loaded' in output:
                    raise RuntimeError('Backdrops picker could not load the selected image')
                print('PASS: Backdrops picker changed the desktop background')
                return
            if args.paste_shell_command and not shell_pasted and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and keyboard_tag is not None and time.monotonic() >= next_event:
                meta = chr(0xF868).encode('utf-8')
                event = b'r' + meta + b'\0rv\0Rv\0R' + meta + b'\0'
                host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                keyboard_tag = None; shell_pasted = True; next_event = time.monotonic() + 0.3
            if args.pie_shell_command and not shell_pasted and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and mouse_tag is not None and time.monotonic() >= next_event:
                x, y, button = pie_events[pie_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [x, y, button, 5000 + pie_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; pie_index += 1; next_event = time.monotonic() + 0.4
                if pie_index == len(pie_events): shell_pasted = True
            if args.shell_command and (not args.paste_shell_command and not args.pie_shell_command or shell_pasted) and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 2 and keyboard_tag is not None and shell_typed < len(shell_text) and time.monotonic() >= next_event:
                if shell_typed == len(shell_text) - 1:
                    shell_window_initial = hashlib.sha256(pixels).digest()
                char = shell_text[shell_typed].encode('utf-8')
                event = b'r' + char + b'\0R' + char + b'\0'
                host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                keyboard_tag = None; shell_typed += 1; next_event = time.monotonic() + 0.02
                if shell_typed == len(shell_text): shell_done = time.monotonic()
            if args.pet_compile and pet_click_index < 3 and shell_done is not None and time.monotonic() - shell_done > args.command_settle and mouse_tag is not None and time.monotonic() >= next_event:
                button = [0, 1, 0][pet_click_index]
                event = ('m' + ''.join(f'{n:11d} ' for n in [610, 150, button, 6000 + pet_click_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; pet_click_index += 1; next_event = time.monotonic() + 0.4
            if shell_done is not None and time.monotonic() - shell_done > args.command_settle and (not args.pet_compile or pet_click_index == 3):
                expected = args.expect_file
                if expected is not None and not expected.is_absolute() and args.cwd:
                    expected = args.cwd / expected
                if ((expected is None or expected.is_file()) and
                    (not args.expect_log or args.expect_log in output) and
                    (not args.expect_clipboard or clipboard_text == args.expect_clipboard.encode()) and
                    (not args.expect_window or hashlib.sha256(pixels).digest() != shell_window_initial)):
                    print(f'PASS: BlueShell ran {args.shell_command}')
                    return
            if play_tetris and 'WMTetris opened' in output and not tetris_start_sent and keyboard_tag is not None and tetris_sent_at is not None and time.monotonic() - tetris_sent_at > 1 and time.monotonic() >= next_event:
                tetris_game_initial = hashlib.sha256(pixels).digest(); tetris_game_flushes = flushes
                event = b'r \0R \0'
                host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                keyboard_tag = None; tetris_start_sent = True; tetris_game_at = time.monotonic()
            if play_tetris and tetris_game_at is not None and time.monotonic() - tetris_game_at > 2:
                if flushes <= tetris_game_flushes or hashlib.sha256(pixels).digest() == tetris_game_initial:
                    raise RuntimeError('Space did not start or repaint Tetris')
                if not args.tetris_shutdown:
                    print('PASS: Tetris started with Space and repainted its game board')
                    return
            if (args.zoom or args.zoom_wheel) and ready and keyboard_tag is not None and zoom_index < len(zoom_keys) and time.monotonic() >= next_event and (not args.zoom_wheel or zoom_index == 0 or wheel_index == 2):
                if zoom_initial is None:
                    zoom_initial = hashlib.sha256(pixels).digest(); zoom_flushes = flushes
                event = zoom_keys[zoom_index]
                host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                keyboard_tag = None; zoom_index += 1; next_event = time.monotonic() + 0.3
                if zoom_index == len(zoom_keys): zoom_sent_at = time.monotonic()
            if args.zoom_wheel and zoom_index == 1 and mouse_tag is not None and wheel_index < 2 and time.monotonic() >= next_event:
                event = ('m' + ''.join(f'{n:11d} ' for n in [450, 350, [8, 0][wheel_index], wheel_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; wheel_index += 1; next_event = time.monotonic() + 0.3
            if args.zoom_button and ready and mouse_tag is not None and zoom_button_index < 3 and time.monotonic() >= next_event:
                if zoom_initial is None:
                    zoom_initial = hashlib.sha256(pixels).digest(); zoom_flushes = flushes
                event = ('m' + ''.join(f'{n:11d} ' for n in [280, 270, [0, 1, 0][zoom_button_index], zoom_button_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; zoom_button_index += 1; next_event = time.monotonic() + 0.3
                if zoom_button_index == 3: zoom_sent_at = time.monotonic()
            if (args.zoom or args.zoom_wheel or args.zoom_button) and zoom_sent_at is not None and time.monotonic() - zoom_sent_at > 1.5:
                if flushes <= zoom_flushes or hashlib.sha256(pixels).digest() == zoom_initial:
                    raise RuntimeError('zoom input did not repaint a zoomed desktop')
                if args.zoom_button and 'desktop zoom:' not in output:
                    raise RuntimeError('Zoom in button did not update viewport range')
                print('PASS: zoom input repainted the desktop')
                return
            if not args.shutdown and not args.zoom and not args.zoom_wheel and not args.zoom_button and menu_app is None and ready and resize_index == len(resize_sizes) and mouse_tag is not None and event_index < len(buttons) and time.monotonic() >= next_event:
                event = ('m' + ''.join(f'{n:11d} ' for n in [280, 188, buttons[event_index], event_index * 300])).encode()
                host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                mouse_tag = None; event_index += 1; next_event = time.monotonic() + 0.3
            if 'A2 button clicks: 2' in output and keyboard_tag is not None and not keyboard_sent:
                # drawterm devkbd emits a NUL-terminated r/R record for press/release.
                event = b'r \0R \0'
                host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                keyboard_tag = None; keyboard_sent = True
            if args.open_notepad and 'A2 button clicks: 3' in output:
                if editor_event < 3 and mouse_tag is not None and time.monotonic() >= next_event:
                    event = ('m' + ''.join(f'{n:11d} ' for n in [280, 232, [0, 1, 0][editor_event], 2000 + editor_event * 300])).encode()
                    host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                    mouse_tag = None; editor_event += 1; next_event = time.monotonic() + 0.3
                if args.type_text and editor_ready is not None and time.monotonic() - editor_ready > 0.5:
                    if focus_event < 3 and mouse_tag is not None and time.monotonic() >= next_event:
                        event = ('m' + ''.join(f'{n:11d} ' for n in [120, 160, [0, 1, 0][focus_event], 3000 + focus_event * 300])).encode()
                        host.sendall(packet(117, mouse_tag, struct.pack('<I', len(event)) + event))
                        mouse_tag = None; focus_event += 1; next_event = time.monotonic() + 0.3
                    elif focus_event == 3 and typed < len(args.type_text) and keyboard_tag is not None and time.monotonic() >= next_event:
                        char = args.type_text[typed].encode('utf-8')
                        event = b'r' + char + b'\0R' + char + b'\0'
                        host.sendall(packet(117, keyboard_tag, struct.pack('<I', len(event)) + event))
                        keyboard_tag = None; typed += 1; next_event = time.monotonic() + 0.05
                        if typed == len(args.type_text): typing_done = time.monotonic()
                complete = editor_ready if not args.type_text else typing_done
                if complete is not None and time.monotonic() - complete > 2 and time.monotonic() - last_paint > 0.3:
                    if args.resize:
                        if not editor_resized:
                            # The text area must survive a resize round trip pixel for pixel.
                            editor_pixels = b''.join(pixels[(y * screen_width + 130) * 3:(y * screen_width + 400) * 3] for y in range(150, 180))
                            resize_sizes.extend([(720, 520), (1024, 768)])
                            editor_resized = True
                            continue
                        if resize_pending or resize_index < len(resize_sizes): continue
                        actual = b''.join(pixels[(y * screen_width + 130) * 3:(y * screen_width + 400) * 3] for y in range(150, 180))
                        if actual != editor_pixels: raise RuntimeError('Notepad content changed after resize round trip')
                        if stale_errors == 0: raise RuntimeError('resize/upload race was not exercised')
                        print(f'PASS: preserved Notepad pixels across resize; recovered from {stale_errors} stale-screen errors')
                    print('PASS: mouse and keyboard widgets, followed by opening standard A2 Notepad')
                    return
        raise RuntimeError('timed out waiting for desktop initialization or button callbacks')
    finally:
        if args.paint_stats:
            print(f'Paint stats: {upload_count} uploads, {partial_uploads} partial-width, '
                  f'{upload_bytes} pixel bytes ({full_strip_bytes} with full-width strips)')
        if args.capture:
            args.capture.write_bytes(f'P6\n{screen_width} {screen_height}\n255\n'.encode() + pixels)
        selector.close(); host.close()
        process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == '__main__':
    main()
