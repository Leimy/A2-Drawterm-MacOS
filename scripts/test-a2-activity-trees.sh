#!/bin/sh
# Exercise the same public API, probe and build rules on each supported host.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/a2-tree-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$repo/source/ConcurrentSieve.Mod" "$repo/tests/DarwinActivityTreeProbe.Mod" "$repo/tests/ActivityTreeMain.Mod" .
cat >Makefile <<'MAKE'
PROGRAM = tree-test
MODULES = ConcurrentSieve DarwinActivityTreeProbe ActivityTreeMain
A2_PROFILE = activities
include $(A2_BRANCH)/build/standalone.mk
MAKE
make A2_BRANCH="$repo"
for n in 1 4; do
    ./tree-test sieve "$n" 1000 > "log.$n" 2>&1 || { cat "log.$n"; exit 1; }
    grep -F "Sieve workers used: $n" "log.$n" || { cat "log.$n"; exit 1; }
    grep -F '1000: 168 primes' "log.$n"
    grep '^2 3 5 ' "log.$n" > "primes.$n"
done
cmp primes.1 primes.4
./tree-test cancel > cancel.log 2>&1
grep -F 'PASS cross-worker cancellation' cancel.log
