#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || { [ "$1" != compiler ] && [ "$1" != desktop ]; }; then
    printf 'Usage: %s compiler|desktop OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
fi
target=$1
mkdir -p "$2"
output=$(CDPATH= cd -- "$2" && pwd)
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
loader=${A2_LOADER:-$repo/build/native-compiler/OberonLoader}
compiler=${A2_COMPILER_CORE:-$repo/build/native-compiler/DarwinAosCompilerAa}
library=${A2_COMPILER_LIBRARY:-$repo/build/native-compiler}
loader=$(CDPATH= cd -- "$(dirname -- "$loader")" && pwd)/$(basename -- "$loader")
compiler=$(CDPATH= cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")
library=$(CDPATH= cd -- "$library" && pwd)

if [ "$target" = desktop ]; then
    recipe=$repo/build/DarwinAArch64DrawtermDesktop.txt
    image=DarwinAosDrawtermDesktopAa
else
    recipe=$repo/build/DarwinAArch64Compiler.txt
    image=DarwinAosCompilerAa
fi
test -x "$loader"
test -s "$compiler"
sed '1d' "$recipe" > "$output/NativeBuild.txt"
build_log="$output/NativeBuild.log"
(
    cd "$output"
    AOSCONFIG=${AOSCONFIG:-'Color 0 StackSize 8192'}
    AOSPATH="$output:$library:$repo/source:$repo/data${AOSPATH:+:$AOSPATH}"
    OBERON_CORE=$compiler
    export AOSCONFIG AOSPATH OBERON_CORE
    "$loader" execute NativeBuild.txt
) > "$build_log" 2>&1
cat "$build_log"
if grep -Eq 'error:|Command not successful|native signal|Trap [0-9]+' "$build_log" || ! grep -q 'Link successful' "$build_log"; then
    printf 'Native build failed; see %s\n' "$build_log" >&2
    exit 1
fi
test -s "$output/$image"
if [ "$target" = desktop ]; then
    "$repo/scripts/package-a2-drawterm.sh" "$output"
else
    cp "$repo/build/DarwinAArch64CompilerExtras.txt" "$output/NativeExtras.txt"
    (
        cd "$output"
        AOSCONFIG=${AOSCONFIG:-'Color 0 StackSize 8192'}
        AOSPATH="$output:$repo/source:$repo/data${AOSPATH:+:$AOSPATH}"
        OBERON_CORE="$output/$image"
        export AOSCONFIG AOSPATH OBERON_CORE
        "$loader" execute NativeExtras.txt
    )
    if [ "$loader" != "$output/OberonLoader" ]; then
        cp "$loader" "$output/OberonLoader"
    fi
fi
printf 'Native build complete: %s/%s\n' "$output" "$image"
