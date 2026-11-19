#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || { [ "$1" != compiler ] && [ "$1" != desktop ] && [ "$1" != desktop-lightweight ]; }; then
    printf 'Usage: %s compiler|desktop|desktop-lightweight OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
fi
target=$1
mkdir -p "$2"
output=$(CDPATH= cd -- "$2" && pwd)
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
seed=$repo/build/native-compiler
if [ "$target" = desktop-lightweight ]; then seed=$repo/build/native-toolchain; fi
loader=${A2_LOADER:-$seed/OberonLoader}
compiler=${A2_COMPILER_CORE:-$seed/DarwinAosCompilerAa}
library=${A2_COMPILER_LIBRARY:-$seed}
loader=$(CDPATH= cd -- "$(dirname -- "$loader")" && pwd)/$(basename -- "$loader")
compiler=$(CDPATH= cd -- "$(dirname -- "$compiler")" && pwd)/$(basename -- "$compiler")
library=$(CDPATH= cd -- "$library" && pwd)

if [ "$target" != compiler ]; then
    recipe=$repo/build/DarwinAArch64DrawtermDesktop.txt
    image=DarwinAosDrawtermDesktopAa
else
    recipe=$repo/build/DarwinAArch64Compiler.txt
    image=DarwinAosCompilerAa
fi
test -x "$loader"
test -s "$compiler"
if [ "$target" = desktop-lightweight ]; then
    # The low-level Unix module is built before KernelLog is available.
    sed -e '1d' \
        -e '2s/Compiler.Compile /Compiler.Compile --traceModule=Trace /' \
        -e 's/--define=UNIX,AARCH64,DESKTOP /--define=UNIX,AARCH64,DESKTOP,LIGHTWEIGHT /g' \
        -e '2s/ ServiceActivities.Mod / DarwinActivities.Mod Darwin.ActivityTrees.Mod DarwinServices.Mod DarwinCommandWorkers.Mod Darwin.ServiceActivities.Mod /' \
        -e '3s/ ServiceActivities / DarwinActivities ActivityTrees DarwinServices DarwinCommandWorkers ServiceActivities /' \
        "$recipe" > "$output/NativeBuild.txt"
    cc -arch arm64 -mmacosx-version-min="${A2_MACOS_MIN_VERSION:-13.0}" -O2 -dynamiclib -Wno-deprecated-declarations \
        "$repo/UnixAos/boot/DarwinActivities.c" -o "$output/libA2Activities.dylib"
else
    sed '1d' "$recipe" > "$output/NativeBuild.txt"
fi
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
if [ "$target" != compiler ]; then
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
