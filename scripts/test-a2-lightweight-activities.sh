#!/bin/sh
# Builds a separate compiler core with experimental stack scanning. The
# existing native toolchain supplies the unchanged bootstrap modules.
set -eu
limit=${1:-10000}
case "$limit" in
    10000|100000) ;;
    *) echo "Usage: $0 [10000|100000]" >&2; exit 2 ;;
esac
run_timeout=90
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
    if ! perl -e 'alarm shift; exec @ARGV or die $!' "$run_timeout" ./OberonLoader "$@" > run.log 2>&1 ||
       grep -Eq 'error:|native signal|Command not successful|Trap [0-9]+' run.log; then
        cat run.log >&2
        exit 1
    fi
}
run execute core.txt
grep -q 'Link successful' run.log
run compile -p=DarwinA2 CSP.Mod CSPChannels.Mod CSPDemo.Mod ConcurrentSieve.Mod DarwinActivities.Mod DarwinActivitiesProbe.Mod
test -s DarwinActivitiesProbe.GofAa
export OBERON_CORE="$work/DarwinAosCompilerAa"
run do 'DarwinActivitiesProbe.Run 100000'
grep -F 'PASS two ACTIVE bodies, contended EXCLUSIVE and 1000 AWAIT exchanges on one pthread' run.log
grep 'PASS single worker, parked GC and exact sieve through 100000: 9592 activities' run.log

# Independently check the entire printed prime sequence and the number of
# ordinary NEW bodies that ran to completion through this scheduler.
check_tree() {
    run do "DarwinActivitiesProbe.$1 $2"
    awk -v limit="$2" '
        BEGIN {
            for (n = 2; n <= limit; n++) if (!composite[n]) {
                primes[++count] = n
                for (i = n+n; i <= limit; i += n) composite[i] = 1
            }
        }
        { sub(/\r$/, "") }
        /^2( |$)/ {
            if (NF != count) exit 1
            for (i = 1; i <= NF; i++) if ($i != primes[i]) exit 1
            exact++
        }
        /^Joined lightweight filter bodies: / { if ($NF == count) joined++ }
        END { if (exact != 1 || joined != 1) exit 1 }
    ' run.log
    if [ "$1" = Mailboxes ]; then grep "^Active-object sieve through " run.log; fi
    echo "PASS $1 through $2, every prime and filter join verified"
}
if [ "$limit" = 100000 ]; then run_timeout=600; fi
check_tree Mailboxes "$limit"
run_timeout=90
check_tree Channels 1000
