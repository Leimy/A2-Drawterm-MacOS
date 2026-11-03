# Native A2 desktop development on Apple Silicon

The drawterm desktop includes the Fox AArch64 compiler. BlueShell runs A2
commands; the classic Oberon window is a separate environment and its classic
compiler still targets i80386.

For a first run on another Apple Silicon Mac, copy the ZIP and its adjacent
`.zip.sha256` file to that Mac. In Terminal, verify and extract them:

```sh
shasum -a 256 -c A2-Darwin-arm64-preview-2026-11-03.zip.sha256
unzip A2-Darwin-arm64-preview-2026-11-03.zip
cd A2-Darwin-arm64-preview
sh ./verify.sh --check
sh ./verify.sh --launch
```

The verifier checks every bundled file, confirms the launcher starts, and
opens A2 with `~/A2-work` as its writable directory. Running the bundle needs
neither Python nor Xcode command-line tools. The binaries target macOS 13.0 or
later on Apple Silicon; the clean-Mac test should confirm actual compatibility.
This preview has no Developer ID signature or notarization. If macOS blocks a
downloaded executable after its checksums pass, review the warning in
[System Settings > Privacy & Security](https://support.apple.com/en-lamr/102445)
and use **Open Anyway** only if you trust this build. The verifier does not
change Gatekeeper settings or remove quarantine metadata.

Launch the desktop from the directory where you want compiled modules written:

```sh
mkdir -p ~/A2-work
cd ~/A2-work
/path/to/A2-Darwin-arm64-preview/a2
```

Open **Desktop > BlueShell**, then compile and run the bundled example. Enter
each line separately:

```text
Compiler.Compile -p=DarwinA2 NativeDesktopHello.Mod
NativeDesktopHello.Run
```

You can paste commands from the macOS clipboard into BlueShell with **Command-V**.
**Control-W** and the text view's right-button pie-menu **Paste** are alternatives.
Selecting and copying text
in A2 updates the macOS clipboard through drawterm's `/dev/snarf`.
`NativeDesktopHello.Copy` is a small command that puts `copied from native A2`
on the macOS clipboard for a round-trip check.

The compiler writes `NativeDesktopHello.GofAa` and
`NativeDesktopHello.SymAa` to the launch directory. The second command loads
the object into A2 and runs its exported procedure. Its message appears in the
terminal that launched `a2`. To edit the example, copy `data/NativeDesktopHello.Mod`
into the launch directory; that directory takes priority over bundled data.
After recompiling a loaded module, run `System.Free NativeDesktopHello` before
running its new version.

The native menu also includes **Development > PET editor**, **Hex editor**,
and **Key codes**, plus **Tools > Color picker** and **Text styles**. Search,
archives, diff, event logs, inspection, repositories, character input, and
scribbling are available as well. To edit and compile the example in PET, copy it into your launch
directory, run `PET.Open NativeDesktopHello.Mod` in BlueShell, then click
**Compile**. PET's Fox compiler uses the DarwinA2 AArch64 target here.

For your own module, use the same compiler options with its `.Mod` filename.
Exported command procedures can be invoked as `Module.Procedure` in BlueShell.
The launcher includes its own directory, the launch directory, and `data` in
`AOSPATH`; it also preserves any `AOSPATH` you set before launching.

For a headless compiler check, run these commands from the extracted bundle
directory. They use the bundled native compiler and write output to
`~/A2-cli-work`:

```sh
bundle=$(pwd)
mkdir -p ~/A2-cli-work
cd ~/A2-cli-work
export OBERON_CORE="$bundle/toolchain/DarwinAosCompilerAa"
export AOSPATH="$PWD:$bundle:$bundle/toolchain:$bundle/data"
export AOSCONFIG='Color 0 StackSize 8192'
"$bundle/OberonLoader" compile -b=AArch64 \
  --objectFileExtension=.GofAa --symbolFileExtension=.SymAa \
  --metaData=full --define=UNIX,AARCH64,DESKTOP NativeDesktopHello.Mod
test -s NativeDesktopHello.GofAa
"$bundle/OberonLoader" do 'NativeDesktopHello.Run'
```

The last command should print `native A2 desktop compiler demo ran`.
