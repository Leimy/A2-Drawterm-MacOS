#!/usr/bin/env python3
"""Run native A2 and drawterm -D over a private socketpair."""

import argparse
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import time


def stop(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def main():
    parser = argparse.ArgumentParser()
    bundle = Path(__file__).resolve().parents[1] / "build/native-desktop"
    parser.add_argument("--drawterm", default=os.environ.get("A2_DRAWTERM", str(bundle / "drawterm")))
    parser.add_argument(
        "--loader",
        default=os.environ.get("A2_LOADER", str(bundle / "OberonLoader")),
    )
    parser.add_argument(
        "--core",
        default=os.environ.get("A2_DESKTOP_CORE", str(bundle / "DarwinAosDrawtermDesktopAa")),
    )
    parser.add_argument("--data-dir", default=str(Path(__file__).resolve().parents[1] / "data"))
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--hold", type=float, default=2.0)
    args = parser.parse_args()

    a2_socket, drawterm_socket = socket.socketpair()
    drawterm = subprocess.Popen(
        [args.drawterm, "-D"], stdin=drawterm_socket, stdout=drawterm_socket,
        stderr=subprocess.PIPE, close_fds=True,
    )
    drawterm_socket.close()

    environment = os.environ.copy()
    environment["OBERON_CORE"] = args.core
    environment["AOSPATH"] = os.pathsep.join(filter(None, [args.data_dir, environment.get("AOSPATH", "")]))
    environment["A2_DRAWTERM_FD"] = str(a2_socket.fileno())
    a2 = subprocess.Popen(
        [args.loader], env=environment, pass_fds=(a2_socket.fileno(),),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0,
    )
    a2_socket.close()
    os.set_blocking(a2.stdout.fileno(), False)

    selector = selectors.DefaultSelector()
    selector.register(a2.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.timeout
    success = False
    fault = False
    output_tail = ""
    frame_ready = False
    desktop_ready = False
    try:
        while time.monotonic() < deadline:
            events = selector.select(deadline - time.monotonic())
            if not events:
                break
            data = os.read(a2.stdout.fileno(), 65536)
            if not data:
                break
            text = data.decode(errors="replace")
            print(text, end="", flush=True)
            combined = output_tail + text
            output_tail = combined[-4096:]
            if "Trap " in combined or "[Recursive Trap]" in combined or "drawterm display failed" in combined or ("native signal " in combined and "fault=" in combined and combined.endswith("\n")):
                fault = True
                break
            frame_ready |= "drawterm full frame acknowledged" in combined
            desktop_ready |= "drawterm desktop initialized" in combined
            if ("drawterm visible input monitor ready" in output_tail
                    or (frame_ready and desktop_ready)):
                success = True
                break
            if "drawterm display failed" in output_tail:
                break
        if success and not fault:
            hold_deadline = time.monotonic() + args.hold
            unexpected_exit = False
            while time.monotonic() < hold_deadline:
                events = selector.select(min(0.25, hold_deadline - time.monotonic()))
                if events:
                    data = os.read(a2.stdout.fileno(), 65536)
                    if not data:
                        unexpected_exit = a2.poll() is not None
                        break
                    text = data.decode(errors="replace")
                    print(text, end="", flush=True)
                    combined = output_tail + text
                    output_tail = combined[-4096:]
                    if "Trap " in combined or "[Recursive Trap]" in combined or "drawterm display failed" in combined or ("native signal " in combined and "fault=" in combined and combined.endswith("\n")):
                        fault = True
                        break
    finally:
        stop(a2)
        stop(drawterm)
        remaining_data = a2.stdout.read()
        remaining = remaining_data.decode(errors="replace") if remaining_data else ""
        if remaining:
            print(remaining, end="")
        error = drawterm.stderr.read().decode(errors="replace")
        if error:
            print(error, end="", file=sys.stderr)
    if not success or fault:
        raise SystemExit(
            "native A2 did not complete a stable drawterm 9P probe "
            f"(a2={a2.returncode}, drawterm={drawterm.returncode})"
        )
    if unexpected_exit:
        raise SystemExit(f"native A2 exited during the hold interval ({a2.returncode})")


if __name__ == "__main__":
    main()
