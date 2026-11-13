#!/bin/sh
set -eu

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --check ] && [ "$1" != --launch ]; }; then
    printf 'Usage: sh %s [--check|--launch]\n' "$0" >&2
    exit 2
fi

bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf 'This preview requires an Apple Silicon Mac running macOS.\n' >&2
    exit 1
fi
for file in a2 OberonLoader drawterm; do
    test -x "$bundle/$file" || { printf 'Missing executable: %s\n' "$file" >&2; exit 1; }
done
for file in DarwinAosDrawtermDesktopAa libA2Audio.dylib libA2Radio.dylib Modules.GofAa WMColorPicker.GofAa data/NativeMenuPage00.XML toolchain/DarwinAosCompilerAa data/NativeDesktopHello.Mod SHA256SUMS; do
    test -s "$bundle/$file" || { printf 'Missing bundle file: %s\n' "$file" >&2; exit 1; }
done

printf 'Checking bundle integrity...\n'
(cd "$bundle" && shasum -a 256 -c SHA256SUMS > /dev/null)
if ! "$bundle/a2" --help > /dev/null 2>&1; then
    printf 'The launcher could not start. Check the macOS version and any Gatekeeper message.\n' >&2
    exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/a2-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf 'Checking bundled native compiler and module loading...\n'
(
    cd "$work"
    export AOSCONFIG='Color 0 StackSize 8192'
    export AOSPATH="$work:$bundle/toolchain:$bundle:$bundle/data"
    export OBERON_CORE="$bundle/toolchain/DarwinAosCompilerAa"
    "$bundle/OberonLoader" compile -p=DarwinA2 NativeDesktopHello.Mod > compile.log 2>&1
    if [ ! -s NativeDesktopHello.GofAa ] || grep -Eq 'native signal|Trap |error:|Command not successful' compile.log; then
        cat compile.log >&2
        exit 1
    fi
    "$bundle/OberonLoader" do NativeDesktopHello.Run > run.log 2>&1
    if ! grep -Fq 'native A2 desktop compiler demo ran' run.log || grep -Eq 'native signal|Trap |Command not successful' run.log; then
        cat run.log >&2
        exit 1
    fi
)
rm -rf "$work"
trap - EXIT HUP INT TERM
printf 'A2 bundle verified on macOS %s (%s).\n' "$(sw_vers -productVersion)" "$(uname -m)"

if [ "${1:---check}" = --launch ]; then
    work="$HOME/A2-work"
    mkdir -p "$work"
    printf 'Starting A2; compiled modules will be written in %s\n' "$work"
    printf 'Try Tools > Color picker and Demos > Oberon, then System > Shutdown.\n'
    cd "$work"
    exec "$bundle/a2"
fi
