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

for module in Network IP Sockets TCP UDP DNS; do
    test -s "$bundle/$module.GofAa"
done
test -x "$loader"
test -s "$compiler"

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/a2-network.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT HUP INT TERM
printf '%s\n' \
    'Compiler.Compile -b=AArch64 --mergeSections --metaData=full --objectFileExtension=.GofAa --symbolFileExtension=.SymAa --define=UNIX,AARCH64,DESKTOP DarwinNetworkProbe.Mod ~' \
    > "$probe_dir/NetworkProbe.txt"

(
    cd "$probe_dir"
    export AOSCONFIG='Color 0 StackSize 8192'
    export AOSPATH="$probe_dir:$bundle:$library:$repo/tests:$repo/source:$repo/data"
    export OBERON_CORE="$compiler"
    "$loader" execute NetworkProbe.txt
    "$loader" do 'DarwinNetworkProbe.Run'
) > "$probe_dir/result.log" 2>&1

cat "$probe_dir/result.log"
for check in 'endian' 'localhost DNS' 'TCP loopback' 'UDP loopback'; do
    if ! grep -Fq "NETWORK PASS $check" "$probe_dir/result.log"; then
        printf 'Network probe failed: %s\n' "$check" >&2
        exit 1
    fi
done
if grep -Eq 'NETWORK FAIL|native signal|Trap [0-9]+' "$probe_dir/result.log"; then
    printf 'Network probe reported a native failure\n' >&2
    exit 1
fi
