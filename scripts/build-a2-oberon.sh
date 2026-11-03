#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s DESKTOP_BUILD_DIRECTORY\n' "$0" >&2
    exit 2
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$(CDPATH= cd -- "$1" && pwd)
compiler=${A2_COMPILER_CORE:-$repo/build/native-compiler/DarwinAosCompilerAa}
library=${A2_COMPILER_LIBRARY:-$repo/build/native-compiler}
loader=${A2_LOADER:-$output/OberonLoader}
test -s "$output/DarwinAosDrawtermDesktopAa"
test -s "$compiler"
test -x "$loader"

export AOSCONFIG=${AOSCONFIG:-'Color 0 StackSize 8192'}
export AOSPATH="$output:$library:$repo/source:$repo/data${AOSPATH:+:$AOSPATH}"
export OBERON_CORE=$compiler

# Separate compiler invocations avoid a native compiler trap when OberonDisplay
# follows the namespace modules in the same command.
for module in \
    Oberon.Kernel Oberon.Modules Oberon.Files Oberon.Objects \
    Oberon.Display Oberon.Input Oberon.Types Oberon.FileDir \
    OberonDisplay Oberon.Viewers OpenTypeInt OpenTypeScan OpenType \
    OberonFonts Oberon.Fonts Oberon Oberon.Texts Fido \
    Oberon.Oberon Oberon.MenuViewers Oberon.TextFrames Oberon.System \
    Oberon.In Oberon.Out Oberon.Dates Oberon.Strings \
    AArch64.Oberon.Bitmaps Oberon.Pictures Unix.Oberon.Printer Oberon.Edit \
    Oberon.Colors Oberon.Display3 Oberon.Effects Oberon.Printer3 \
    Oberon.Attributes Oberon.Links Oberon.Gadgets Oberon.BasicGadgets \
    Oberon.TextFields Oberon.ListRiders Oberon.ListModels Oberon.ListDags \
    Oberon.ListGadgets Oberon.Lists Oberon.Panels Oberon.TextGadgets0 \
    Oberon.TextGadgets Oberon.BasicFigures Oberon.Scrollbars \
    Oberon.Directories Oberon.Documents Oberon.Views Oberon.Desktops \
    Oberon.NamePlates Oberon.TextDocs Oberon.OPM Oberon.OPS Oberon.TextPopups \
    Oberon.EditKeys
do
    printf 'Compiler.Compile -b=AArch64 --mergeSections --metaData=full --objectFileExtension=.GofAa --symbolFileExtension=.SymAa --define=UNIX,AARCH64,DESKTOP %s.Mod ~\n' "$module" > "$output/OberonBuild.txt"
    (cd "$output" && "$loader" execute OberonBuild.txt) > "$output/OberonBuild.log" 2>&1
    cat "$output/OberonBuild.log"
    if grep -Eq 'error:|Command not successful|native signal|Trap [0-9]+' "$output/OberonBuild.log" ||
       ! grep -Eq 'compiling .* done\.' "$output/OberonBuild.log"; then
        printf 'Embedded Oberon compile failed: %s\n' "$module" >&2
        exit 1
    fi
done

sed -n '3p' "$repo/build/DarwinAArch64DrawtermDesktop.txt" | sed 's/ ~$//' > "$output/OberonBuild.txt"
printf ' Oberon-Kernel Oberon-Modules Oberon-Files Oberon-Objects Oberon-Display Oberon-Input Oberon-Types Oberon-FileDir OberonDisplay Oberon-Viewers OpenTypeInt OpenTypeScan OpenType OberonFonts Oberon-Fonts Oberon Oberon-Texts Fido Oberon-Oberon Oberon-MenuViewers Oberon-TextFrames Oberon-System Oberon-In Oberon-Out Oberon-Dates Oberon-Strings Oberon-Bitmaps Oberon-Pictures Oberon-Printer Oberon-Edit Oberon-Colors Oberon-Display3 Oberon-Effects Oberon-Printer3 Oberon-Attributes Oberon-Links Oberon-Gadgets Oberon-BasicGadgets Oberon-TextFields Oberon-ListRiders Oberon-ListModels Oberon-ListDags Oberon-ListGadgets Oberon-Lists Oberon-Panels Oberon-TextGadgets0 Oberon-TextGadgets Oberon-BasicFigures Oberon-Scrollbars Oberon-Directories Oberon-Documents Oberon-Views Oberon-Desktops Oberon-NamePlates Oberon-TextDocs Oberon-OPM Oberon-OPS Oberon-TextPopups Oberon-EditKeys ~\n' >> "$output/OberonBuild.txt"
(cd "$output" && "$loader" execute OberonBuild.txt) > "$output/OberonBuild.log" 2>&1
cat "$output/OberonBuild.log"
if grep -Eq 'error:|Command not successful|native signal|Trap [0-9]+' "$output/OberonBuild.log" ||
   ! grep -q 'Link successful' "$output/OberonBuild.log"; then
    printf 'Embedded Oberon link failed\n' >&2
    exit 1
fi
"$repo/scripts/package-a2-drawterm.sh" "$output"
cp "$repo/scripts/NativeOberonMenuPage30.XML" "$output/data/NativeMenuPage30.XML"
printf 'Embedded Oberon preview ready: %s/a2\n' "$output"
