# Darwin AArch64 A2 preview

This is an experimental native Apple Silicon port of ETH's Active Object System
(A2, formerly Bluebottle) and its Fox compiler. It displays the A2 desktop
through a local 9P connection to a modified drawterm, without X11 or a Linux
VM at runtime. The classic Oberon viewer is included, but its classic compiler
still targets i80386; use the Fox compiler in BlueShell or PET for native AArch64
programs.

The preview executables are built with a macOS 13.0 deployment target. They
have not yet been tested on every macOS release from 13 onward. See the
first-run verifier in the archive's README for a clean-machine check. The
preview is ad-hoc signed by the linker, not Developer ID signed or notarized;
downloaded copies may require a deliberate Gatekeeper approval.

The port was developed with substantial assistance from OpenAI Codex, directed
and tested by an Active Oberon enthusiast interested in making A2 usable on
macOS and alongside 9front tools. It builds on the original work of ETH A2
contributors and the drawterm authors. This is an independent experimental
fork; it is not an ETH or drawterm project release, nor a claim that one person
created A2.

## What is in the source tree

- `source/FoxAArch64InstructionSet.Mod` and `source/FoxAArch64Backend.Mod` add
  the AArch64 Fox backend; `source/A64*.Mod` and the native test scripts exercise it.
- Modified `source/*.Mod` files adapt the runtime, linker, compiler, desktop,
  classic Oberon viewer, input, clipboard, and unload paths to Darwin AArch64.
- `UnixAos/boot/OberonLoader.c` loads the native image under macOS memory rules.
- `build/DarwinAArch64*.txt` are native compiler and desktop recipes.
- `scripts/build-a2-native.sh`, `scripts/build-a2-oberon.sh`,
  `scripts/package-a2-drawterm.sh`, and `scripts/a2-drawterm.c` build and launch
  the system. `data/NativeMenuPage*.XML` defines the native desktop menus.
- `third_party/drawterm-a2.patch` contains the drawterm changes required for its
  direct 9P device mode. It applies to drawterm commit
  `76847afb4038906bfa135d8f1d2dd956484ba2f4` and is distributed with its
  license in `third_party/drawterm-LICENSE`.

To reproduce the modified drawterm from source, check out that drawterm commit,
apply `third_party/drawterm-a2.patch` with `git apply`, and run
`MACOSX_DEPLOYMENT_TARGET=13.0 CONF=osx-cocoa make`. Set `A2_DRAWTERM` to the resulting executable when
packaging A2. The drawterm source is kept as a patch against its own upstream
repository so the changes can be reviewed independently.

## Rebuilding

A clean source checkout cannot bootstrap itself from text alone. Start with a
native Apple Silicon A2 compiler image and its `.GofAa`/`.SymAa` library, a
native `OberonLoader`, and the patched drawterm binary. The preview archive
includes these as a documented binary seed; the seed is not generated from a
clean checkout during this build. Extract the archive, then from the source
repository run:

```sh
bundle=/path/to/A2-Darwin-arm64-preview
A2_LOADER="$bundle/OberonLoader" \
A2_DRAWTERM="$bundle/drawterm" \
A2_COMPILER_CORE="$bundle/toolchain/DarwinAosCompilerAa" \
A2_COMPILER_LIBRARY="$bundle/toolchain" \
  scripts/build-a2-native.sh desktop build/native-desktop

A2_COMPILER_CORE="$bundle/toolchain/DarwinAosCompilerAa" \
A2_COMPILER_LIBRARY="$bundle/toolchain" \
  scripts/build-a2-oberon.sh build/native-desktop
```

The resulting `build/native-desktop/a2` is a self-contained launcher. Keep the
packaged `.GofAa` files beside it: A2 dynamically loads commands from those
files when opening desktop applications. See `README-native-desktop.md` for
use. The compiler seed can also rebuild a native compiler with
`scripts/build-a2-native.sh compiler build/native-compiler`.

## Current limits

This is a preview, not a complete A2 platform release. The desktop, editor,
selected applications, native Fox compilation, local drawterm input, resizing,
clipboard, and shutdown have been exercised on Apple Silicon. The GUI builder
is not included: its generic-module import is currently rejected by the native
compiler. The embedded classic Oberon environment is useful but still has an
i80386 compiler. Broader application coverage and long-running stability need
more testing.

The archive includes `LICENSE-A2.txt` (the original A2 distribution notice),
`LICENSE-drawterm.txt`, and the original `data` license notices. Preserve
these when redistributing it.

To make another archive after a native build, run
`scripts/make-a2-release.sh build/native-desktop OUTPUT.zip`. It uses
`build/native-compiler-selfhost2` as the compiler seed by default; set
`A2_RELEASE_COMPILER_DIR` to the extracted archive's `toolchain` directory
when that local build directory is unavailable. The archive includes a file
hash manifest and records whether its source tree had uncommitted changes.
