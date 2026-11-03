#!/usr/bin/env python3
"""Run the native Active Oberon sieve demo and stop after its result."""

import argparse
import os
from pathlib import Path
import selectors
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    demo = Path(__file__).resolve().parents[1] / "build/native-sieve"
    parser.add_argument(
        "--loader",
        default=os.environ.get("A2_LOADER", str(demo / "OberonLoader")),
    )
    parser.add_argument(
        "--core",
        default=os.environ.get("A2_SIEVE_CORE", str(demo / "DarwinAosSieveDemoAa")),
    )
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    environment = os.environ.copy()
    environment["OBERON_CORE"] = args.core
    process = subprocess.Popen(
        [args.loader], env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.timeout
    saw_result = False
    try:
        while time.monotonic() < deadline:
            events = selector.select(deadline - time.monotonic())
            if not events:
                break
            line = process.stdout.readline()
            if not line:
                break
            text = line.decode(errors="replace")
            print(text, end="")
            if text.startswith("2 3 5 7 11 13 17 19 23 29 31 37 41 43 47"):
                saw_result = True
                break
    finally:
        if process.poll() is None:
            # A2 installs handlers for ordinary termination signals and is
            # intentionally a persistent system, so the one-shot wrapper kills it.
            process.kill()
        process.wait(timeout=2)
    if not saw_result:
        raise SystemExit("native sieve did not produce its expected result")


if __name__ == "__main__":
    main()
