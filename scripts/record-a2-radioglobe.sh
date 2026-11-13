#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    printf 'Usage: sh %s DESKTOP_BUILD_DIRECTORY OUTPUT.mp4\n' "$0" >&2
    exit 2
fi
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=$(CDPATH= cd -- "$1" && pwd)
output=$2
case "$output" in *.mp4) ;; *) printf 'Output must end in .mp4\n' >&2; exit 2;; esac
if [ -e "$output" ]; then printf 'Output already exists: %s\n' "$output" >&2; exit 1; fi
work=$(mktemp -d "${TMPDIR:-/tmp}/a2-video.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -O -module-cache-path "$work/modules" "$repo/scripts/encode-a2-video.swift" -o "$work/encode-video"
python3 "$repo/scripts/test-a2-desktop-input.py" --loader "$bundle/OberonLoader" \
    --core "$bundle/DarwinAosDrawtermDesktopAa" --cwd "$work" --menu-app radio-globe \
    --radio-globe-video "$output" --video-encoder "$work/encode-video" --timeout 65
