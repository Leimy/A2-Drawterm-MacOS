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
for module in CryptoTools CryptoSHA256 CryptoSHA3 CryptoAES CryptoTestCiphers; do
    test -s "$bundle/$module.GofAa"
done
test -x "$loader"
test -s "$compiler"

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/a2-crypto.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT HUP INT TERM
printf abc > "$probe_dir/abc"

export AOSCONFIG='Color 0 StackSize 8192'
export AOSPATH="$bundle:$library:$bundle/data"
export OBERON_CORE="$compiler"

for vector in \
    'CryptoSHA256 BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD' \
    'CryptoSHA3 3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532' \
    'CryptoMD5 900150983CD24FB0D6963F7D28E17F72'; do
    set -- $vector
    output=$("$loader" do "CryptoTools.Hash $1 $probe_dir/abc" 2>&1)
    if ! printf '%s\n' "$output" | grep -Fq "$probe_dir/abc: $2"; then
        printf 'Hash vector failed for %s:\n%s\n' "$1" "$output" >&2
        exit 1
    fi
    printf 'CRYPTO PASS %s abc\n' "$1"
done

output=$("$loader" do 'CryptoTestCiphers.Ecb1 CryptoAES 128' 2>&1)
if ! printf '%s\n' "$output" | grep -Fq 'A1EE5608   B33AF054   70858608   D1DE080F' ||
   ! printf '%s\n' "$output" | tr -d '\r' | grep -xq 'OK'; then
    printf 'AES-128 ECB vector failed:\n%s\n' "$output" >&2
    exit 1
fi
printf 'CRYPTO PASS AES-128 ECB\n'
