#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s DESKTOP_BUILD_DIRECTORY OUTPUT.zip\n' "$0" >&2
    exit 2
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
desktop=$(CDPATH= cd -- "$1" && pwd)
compiler=${A2_RELEASE_COMPILER_DIR:-$repo/build/native-compiler-selfhost2}
compiler=$(CDPATH= cd -- "$compiler" && pwd)
mkdir -p "$(dirname -- "$2")"
archive=$(CDPATH= cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
case "$archive" in *.zip) ;; *) printf 'Output must end in .zip\n' >&2; exit 2;; esac

for file in a2 OberonLoader drawterm DarwinAosDrawtermDesktopAa libA2Audio.dylib; do
    test -s "$desktop/$file"
done
test -d "$desktop/data"
test -s "$desktop/Modules.GofAa"
test -s "$compiler/DarwinAosCompilerAa"
test -s "$repo/license.txt"
test -s "$repo/third_party/drawterm-LICENSE"

stage=$(mktemp -d "${TMPDIR:-/tmp}/a2-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
name=A2-Darwin-arm64-preview
mkdir -p "$stage/$name/toolchain"
cp "$desktop/a2" "$desktop/OberonLoader" "$desktop/drawterm" \
   "$desktop/DarwinAosDrawtermDesktopAa" "$desktop/libA2Audio.dylib" "$stage/$name/"
for file in "$desktop"/*.GofAa "$desktop"/*.SymAa; do
    test -f "$file" || continue
    cp "$file" "$stage/$name/"
done
cp -R "$desktop/data" "$stage/$name/data"
cp "$repo/README-native-desktop.md" "$stage/$name/README.md"
cp "$repo/scripts/verify-a2-release.sh" "$stage/$name/verify.sh"
cp "$repo/RELEASE-DARWIN-AARCH64.md" "$stage/$name/RELEASE-NOTES.md"
cp "$repo/license.txt" "$stage/$name/LICENSE-A2.txt"
cp "$repo/third_party/drawterm-LICENSE" "$stage/$name/LICENSE-drawterm.txt"
revision=$(git -C "$repo" rev-parse HEAD)
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    source_state='uncommitted changes present'
else
    source_state='clean checkout'
fi
printf 'A2 source base commit: %s\nA2 source state: %s\nDrawterm patch base commit: %s\n' \
    "$revision" "$source_state" '76847afb4038906bfa135d8f1d2dd956484ba2f4' \
    > "$stage/$name/BUILD-PROVENANCE.txt"
cp "$compiler/DarwinAosCompilerAa" "$stage/$name/toolchain/"
for file in "$compiler"/*.GofAa "$compiler"/*.SymAa; do
    test -f "$file" || continue
    cp "$file" "$stage/$name/toolchain/"
done

(
    cd "$stage/$name"
    find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do
        shasum -a 256 "$file"
    done > SHA256SUMS
)
temporary="$archive.new.$$.zip"
trap 'rm -rf "$stage"; rm -f "$temporary"' EXIT HUP INT TERM
(cd "$stage" && zip -X -q -r -9 "$temporary" "$name")
unzip -tq "$temporary" >/dev/null
mv -f "$temporary" "$archive"
(cd "$(dirname -- "$archive")" && shasum -a 256 "$(basename -- "$archive")") > "$archive.sha256"
printf 'Release candidate: %s\n' "$archive"
