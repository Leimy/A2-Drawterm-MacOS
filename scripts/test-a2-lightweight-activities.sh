#!/bin/sh
# Builds a separate compiler core with experimental stack scanning. The
# existing native toolchain supplies the unchanged bootstrap modules.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
seed=${A2_COMPILER_LIBRARY:-$repo/build/native-toolchain}
seed=$(CDPATH= cd -- "$seed" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/a2-activities.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$seed/OberonLoader" "$work/"
cc -arch arm64 -O2 -dynamiclib -Wall -Wextra -Werror -Wno-deprecated-declarations \
    "$repo/UnixAos/boot/DarwinActivities.c" -o "$work/libA2Activities.dylib"
cd "$work"
export AOSCONFIG='Color 0 StackSize 8192'
export AOSPATH="$work:$seed:$repo/source:$repo/tests:$repo/data"
export OBERON_CORE="$seed/DarwinAosCompilerAa"
# Recompile Objects and its importers against the experiment's Process type.
sed '1d;s/AMD64.Builtins.Mod .* Unix.Objects.Mod/Unix.Objects.Mod/;s/--define=UNIX,AARCH64,DESKTOP /--define=UNIX,AARCH64,DESKTOP,LIGHTWEIGHT /' \
    "$repo/build/DarwinAArch64Compiler.txt" > core.txt

run() {
    if ! perl -e 'alarm 90; exec @ARGV or die $!' ./OberonLoader "$@" > run.log 2>&1 ||
       grep -Eq 'error:|native signal|Command not successful|Trap [0-9]+' run.log; then
        cat run.log >&2
        exit 1
    fi
}
run execute core.txt
grep -q 'Link successful' run.log
run compile -p=DarwinA2 DarwinActivities.Mod DarwinActivitiesProbe.Mod
test -s DarwinActivitiesProbe.GofAa
export OBERON_CORE="$work/DarwinAosCompilerAa"
run do 'DarwinActivitiesProbe.Run 100000'
grep -F 'PASS two ACTIVE bodies, contended EXCLUSIVE and 1000 AWAIT exchanges on one pthread' run.log
grep 'PASS single worker, parked GC and exact sieve through 100000: 9592 activities' run.log
