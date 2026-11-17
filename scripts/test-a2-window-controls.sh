#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s DESKTOP_BUILD_DIRECTORY\n' "$0" >&2
    exit 2
fi
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=$(CDPATH= cd -- "$1" && pwd)
loader=${A2_LOADER:-$repo/build/native-compiler/OberonLoader}
compiler=${A2_COMPILER_CORE:-$repo/build/native-compiler/DarwinAosCompilerAa}
library=${A2_COMPILER_LIBRARY:-$repo/build/native-compiler}
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/a2-window-controls.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT HUP INT TERM
cp "$repo/tests/NativeWindowControls.Mod" "$probe_dir/"
(
    cd "$probe_dir"
    export AOSCONFIG='Color 0 StackSize 8192'
    export AOSPATH="$probe_dir:$bundle:$library:$repo/data"
    export OBERON_CORE="$compiler"
    "$loader" compile -b=AArch64 --mergeSections --metaData=full \
        --objectFileExtension=.GofAa --symbolFileExtension=.SymAa \
        --define=UNIX,AARCH64,DESKTOP NativeWindowControls.Mod > compile.log 2>&1
    cat compile.log
    test -s NativeWindowControls.GofAa
    if grep -Eq 'error:|Command not successful|native signal|Trap [0-9]+' compile.log; then exit 1; fi
)
python3 "$repo/scripts/test-a2-desktop-input.py" \
    --loader "$bundle/OberonLoader" --core "$bundle/DarwinAosDrawtermDesktopAa" \
    --cwd "$probe_dir" --shell-command NativeWindowControls.Run \
    --expect-log 'WINDOW CONTROLS PASS' --timeout 45
