# Native A2 desktop development on Apple Silicon

The drawterm desktop includes the Fox AArch64 compiler. BlueShell runs A2
commands; the classic Oberon window is a separate environment and its classic
compiler still targets i80386.

For a first run on another Apple Silicon Mac, copy the ZIP and its adjacent
`.zip.sha256` file to that Mac. In Terminal, verify and extract them:

```sh
archive=A2-Darwin-arm64-preview-2026-11-03-apps.zip
shasum -a 256 -c "$archive.sha256"
unzip "$archive"
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
**Key codes**, and **Interpreter shell**, plus **Tools > Color picker** and
**Text styles**. **Graphics** offers an image viewer, graph demos, a Gfx
spiral, a slideshow, a backdrop chooser, drawing overlay, on-screen message,
and module state viewer. **System > Task scheduler** opens the scheduler UI.
Search, archives, diff, event logs, inspection, repositories, character input,
and scribbling are available as well. The slideshow uses the bundled
`RetoWMSlideshow.XML`; the image viewer opens the bundled `mars.png`.
**Graphics > Backdrops** opens a picker; click an image name to apply it to the
desktop. PNG, JPEG, and JP2 choices are bundled, as is `Wallpapers.txt` for the
backdrop's Next action.

**Tools > Web browser** opens A2's BimBrowser on a bundled welcome page. Its
original HTML renderer can open local `file://` documents and plain `http://`
pages. It does not support HTTPS or modern browser features. To open a URL from
BlueShell, run `WebBrowser.OpenURL http://127.0.0.1:8080/`, substituting your
HTTP address and port. The native build includes its HTML, CSS, SVG, and HTTP
dependencies.
From a source checkout, `scripts/test-a2-browser.sh build/native-browser-2026`
checks a local HTTP exchange through the browser and its drawterm desktop.

**Customize** includes the GUI builder, skin chooser, and a command to add a
configurable desktop icon. **Save screenshot** writes `A2Shot.bmp` in the
directory from which you launched `a2`; **View screenshot** opens that file.
It also includes the Skin Editor. **System > Performance** opens the performance
monitor with the Unix CPU, memory, network, event, and self-monitoring plugins.
Device statistics plugins are disabled in this hosted build. **Tools > FTP
client** opens A2's FTP interface; connecting to an external FTP server has
not yet been verified. **Demos > Bunny** displays the bundled animated GIF.
**Demos > 3D Explorer** opens the native software-rendered 3D viewer; drag
with the left mouse button to rotate and drag with the right button to zoom.
**Demos > Turing patterns** animates the reaction-diffusion simulation.
**Demos > RadioGlobe (preview)** shows a textured Earth based on David
Leimbach's [9front radioglobe](https://github.com/leimy/radioglobe). Drag the
globe with the left mouse button to rotate; use the wheel to zoom. This first
preview has no station markers or audio playback. Its bundled 1024x512 Earth
texture is downsampled from radioglobe's `earth.mask`; no Python is needed at
runtime. The globe renders a quicker preview while dragging and restores full
detail when the button is released.
The input-method selector offers Arabic, Armenian, Hebrew, Pinyin, Russian,
Ukrainian, and Unicode entry; the language switcher and window switcher are
also available from this page.
The native bundle includes BMP and JPEG image codecs for these tools and
existing applications such as Tetris. Skin and icon changes made in a running
session are not automatically persisted.

The Apple Silicon build also includes A2's Unix socket-backed IP, TCP, UDP,
and DNS modules. From a source checkout, run
`scripts/test-a2-network.sh build/native-customize-2026` to check byte order,
`localhost` lookup, local TCP/UDP traffic, and a TCP exchange with macOS
`nc` without contacting an external server. These modules are
available for native A2 programs; network applications still need their own
runtime checks before being added to the menu.

To edit and compile the example in PET, copy it into your launch
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
