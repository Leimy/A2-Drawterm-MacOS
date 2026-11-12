#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s DESKTOP_BUILD_DIRECTORY\n' "$0" >&2
    exit 2
fi
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$(CDPATH= cd -- "$1" && pwd)
drawterm=${A2_DRAWTERM:-$repo/../drawterm/drawterm}
minimum_macos=${A2_MACOS_MIN_VERSION:-13.0}
test -s "$output/DarwinAosDrawtermDesktopAa"
test -x "$drawterm"

loader_tmp="$output/.OberonLoader.new.$$"
drawterm_tmp="$output/.drawterm.new.$$"
launcher_tmp="$output/.a2.new.$$"
audio_tmp="$output/.libA2Audio.new.$$"
radio_tmp="$output/.libA2Radio.new.$$"
trap 'rm -f "$loader_tmp" "$drawterm_tmp" "$launcher_tmp" "$audio_tmp" "$radio_tmp"' EXIT HUP INT TERM
clang -arch arm64 -mmacosx-version-min="$minimum_macos" -std=gnu11 -O2 -Wall -Wextra \
    "$repo/UnixAos/boot/OberonLoader.c" -o "$loader_tmp"
cp "$drawterm" "$drawterm_tmp"
clang -arch arm64 -mmacosx-version-min="$minimum_macos" -dynamiclib -O2 -Wall -Wextra \
    "$repo/UnixAos/boot/DarwinAudio.c" -framework AudioToolbox -o "$audio_tmp"
mv -f "$audio_tmp" "$output/libA2Audio.dylib"
clang -arch arm64 -mmacosx-version-min="$minimum_macos" -dynamiclib -O2 -Wall -Wextra \
    "$repo/UnixAos/boot/DarwinRadio.c" "$repo/UnixAos/boot/DarwinCodecs.c" -lcurl -framework AudioToolbox -o "$radio_tmp"
mv -f "$radio_tmp" "$output/libA2Radio.dylib"
mv -f "$loader_tmp" "$output/OberonLoader"
mv -f "$drawterm_tmp" "$output/drawterm"
mkdir -p "$output/data"
cp -R "$repo/data/." "$output/data/"
# Device statistics are unavailable in the hosted Unix runtime; the messages
# plugin also requires WMMessages.Statistics, which this image does not enable.
sed -e 's/name="WMPerfMonPluginMessages" value="TRUE"/name="WMPerfMonPluginMessages" value="FALSE"/' \
    -e 's/name="WMPerfMonPluginDisks" value="TRUE"/name="WMPerfMonPluginDisks" value="FALSE"/' \
    -e 's/name="WMPerfMonPluginUsb" value="TRUE"/name="WMPerfMonPluginUsb" value="FALSE"/' \
    "$output/data/Configuration.XML" > "$output/data/Configuration.XML.native"
mv -f "$output/data/Configuration.XML.native" "$output/data/Configuration.XML"
cp "$repo/README-native-desktop.md" "$output/README.md"
cp "$repo/third_party/stb-vorbis-LICENSE" "$output/LICENSE-stb-vorbis.txt"
cp "$repo/scripts/pet-assist.sh" "$output/pet-assist.sh"
clang -arch arm64 -mmacosx-version-min="$minimum_macos" -std=gnu11 -O2 -Wall -Wextra \
    "$repo/scripts/a2-drawterm.c" -o "$launcher_tmp"
mv -f "$launcher_tmp" "$output/a2"
printf 'Run the desktop: %s/a2\n' "$output"
