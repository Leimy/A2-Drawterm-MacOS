# Native A2 desktop development on Apple Silicon

The drawterm desktop includes the Fox AArch64 compiler. BlueShell runs A2
commands; the classic Oberon window is a separate environment and its classic
compiler still targets i80386.

The [2026-11-13 readiness preview](https://github.com/Leimy/A2-Drawterm-MacOS/releases/tag/preview-2026-11-13-readiness)
includes the desktop, modified drawterm and native compiler toolchain.
For a first run on another Apple Silicon Mac, copy the ZIP and its adjacent
`.zip.sha256` file to that Mac. In Terminal, verify and extract them:

```sh
archive=A2-Darwin-arm64-preview-2026-11-13-readiness.zip
shasum -a 256 -c "$archive.sha256"
unzip "$archive"
cd A2-Darwin-arm64-preview
sh ./verify.sh --check
sh ./verify.sh --launch
```

The verifier checks every bundled file, compiles and runs an Active Oberon
example using the bundled toolchain, and confirms the launcher starts.
With `--launch`, it opens A2 with `~/A2-work` as its writable directory. Running the bundle needs
neither Python nor Xcode command-line tools. The binaries target macOS 13.0 or
later on Apple Silicon. Release-readiness checks on two Apple Silicon Macs
used macOS 27.2.1; earlier macOS versions still need testing.
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

Newer source builds search the working directory first, then the bundle,
the bundle's `data` directory, and any inherited `AOSPATH` entries. Thus a
module compiled in `~/A2-work` overrides the bundled copy. This search-order
change is newer than the readiness preview archive.

Compiling does not replace an already loaded module. Close its application
windows and stop its activities, then use `System.Free MyModule` in BlueShell
before running `MyModule.Run` again. Unload dependent modules first if A2
reports that the module is still imported. Remove or rename the local `.GofAa`
and `.SymAa` pair to use the bundled version again after unloading or restarting.
Modules linked into the core image still require rebuilding that image; local
object-file precedence applies to dynamically loaded modules.

### Keeping the checkout tidy

Keep source, assets, build recipes and tests in Git. Keep personal programs
and settings in a working directory such as `~/A2-work`. Preserve PET backups
as user data, including backups created alongside repository source files.
Generated objects, captures and logs belong under `build/` or a temporary test
directory, rather than the repository root. Child processes must use a matching
working directory and `PWD` so A2 scratch files are created there too.

Retain one current desktop, one known-good fallback, the compiler seed needed
to rebuild, and published release archives/checksums with useful validation
evidence. Keep additional outputs only while a script or running process uses
them. Use `build/native-current`, `build/native-previous` and
`build/native-toolchain` as stable local aliases instead of accumulating a
permanent directory for every experiment. Validate a new build before updating
the aliases, and keep the old running build until it exits.
These aliases are local symlinks, not committed build products. If they are not
configured on your machine, use the actual build directory in the examples below.

Move superseded snapshots to Trash first. Remove closed orphan `.tmp.*` and
old `AOS.*.Log` files after checking that no A2 process uses them; retain useful
failure diagnostics. Age alone is not a reason to delete source or `.Bak`
files. Avoid blanket `git clean -fdx`: ignored directories include bootstrap
seeds, and untracked files can contain personal work. Cleanup manifests are
kept under `build/native-diagnostics/` for recovery.

### Larger PET text (newer source builds)

PET on AArch64 starts with **20-pixel editor text**, independently of desktop
zoom. Its **Text - / Text +** bar, or **Ctrl+- / Ctrl++** (Ctrl+= also works),
selects 12, 14, 16, 20 or 24 pixels. Source, split view and scratch text use the
selected base size; new compiler-log output uses it too. Syntax highlighting is
retained. Existing explicit formatting in rich text can override the base font.

The choice is saved in `PET.FontSize` in A2's working directory and read on the
next launch. Use the same working directory to keep your preference. Font changes
affect the view, without formatting or rewriting the source file. The rest of
the desktop keeps its existing control sizes.

This change is newer than the `preview-2026-11-13-readiness` archive. Rebuild
from current source to get it; that existing download is unchanged.

### PET compiler options

For native desktop modules, PET's compiler-options field should include
`-p=DarwinA2 --warnings`. Newer source builds retain this setting when loading a
`.Mod` file and make the compiler's implicit Darwin target deterministic.

In older builds, the file-specific configuration can replace that option with
`-w`, causing the compiler to select simple metadata and report **maximal
extension level exceeded** for a valid inherited GUI class. Replace `-w` in
the options field with `-p=DarwinA2 -w` and compile again. This does not require
editing or reloading the source buffer.

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

Desktop controls in the current source build:

- **System → Reset desktop zoom**, or **Ctrl+Shift+0**, restores the original
  desktop origin and 1:1 scale. `WindowManager.ResetZoom` does the same from BlueShell.
- Hold the **right mouse button on the desktop background**, drag toward a
  sector, then release: **Reset zoom**, **Fit all**, **Maximize/Restore**, or
  **Cancel**. Maximize/Restore acts on the application focused before opening
  the pie. It fills the drawterm viewport; macOS fullscreen remains drawterm's own control.
- Window title bars expose the existing minimize and maximize/restore buttons
  beside Close. Maximize preserves the previous position and size for Restore.
- In a text area, the right-button pie remains **Open / Copy / Paste / Start**.
  Hold right, move toward the action, then release. A plain right-click no longer
  changes window dimensions, including when drawterm uses Command to emulate it.

The old Meta+right-click window-size reset has been removed because it conflicts
with drawterm's mouse emulation. Meta+End still returns to 1:1 around the current
view center; Ctrl+Shift+0 also resets the origin.

Run `scripts/test-a2-window-controls.sh build/native-current` from the checkout
to exercise the actual input dispatch, title-bar buttons, desktop pie, and zoom
reset in an isolated desktop session.


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
From a source checkout, `scripts/test-a2-browser.sh build/native-current`
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
**Demos > Mandelbrot** opens the concurrent fractal viewer, **Figures** opens
the editable shape example, **Text writer** opens linked editors, and **Image
grid** opens the colored image-grid example. These modules and their supporting
window components are built for AArch64.
**Demos > RadioGlobe** shows a textured Earth based on David
Leimbach's [9front radioglobe](https://github.com/leimy/radioglobe). Drag the
globe with the left mouse button to rotate; use the wheel to zoom. This first
preview keeps the globe circular when its window is resized. Wheel zoom can
enlarge it beyond the window edges; rendering clips to the visible area.
The application lives in `source/WMRadioGlobe.Mod`, with a separate Earth texture
and shared A2 graphics and math modules. It loads **9,297 stations from the
9front RadioGlobe catalogue**, with markers projected onto the visible hemisphere.
Hover to see a name; click a marker or middle-click it to play. Dragging continues
to rotate the globe. **Stations** opens a searchable list so colocated stations
are all accessible. Type a name and press Enter, then select a row and click
**Play**; when a search has one match, Enter again plays it. Selecting from the
list centers the globe on that station. **Prev/Next** step through the catalogue
and switch playback when a stream is active. **Stop** ends playback. Station
switches and network cancellation run outside the UI sequencer; the latest
selection wins. Connection, codec, playback and song-title updates appear in
the globe's status area.

`RadioGlobeStations.txt` is the larger original `stations2` snapshot;
`RadioGlobeStationsTop.txt` preserves the smaller 899-entry `stations` snapshot.
Run `WMRadioGlobe.Open RadioGlobeStationsTop.txt` to use the smaller one, or pass
your own catalogue filename. The format is `latitude longitude "name" URL`.
Placing `RadioGlobeStations.txt` in your launch directory overrides the bundled
list. Close and reopen the globe to reload it. Format labels in the station
window are hints from the names and URLs, not a codec verification. These are
catalogue snapshots: some stations may have moved, gone offline, or use an
unsupported format; failures are reported in the globe rather than freezing it.

Before selecting a marker, **Play radio** uses `RadioGlobeStation.txt`, whose
default is [SomaFM Groove Salad](https://somafm.com/groovesalad/directstreamlinks.html).
Closing a globe window that started playback also requests a stop. Its bundled 4096x2048 Earth
texture is downsampled from radioglobe's `earth.mask`; no Python is needed at
runtime. The texture has four times the angular resolution of the original preview
(16 times as many texels, about 32 MiB decoded). Active Oberon samples it with
fixed-point bilinear interpolation, wraps longitude across the seam and clamps
latitude at the poles. Interpolated angle tables avoid visible coordinate steps;
near-pole latitude uses the exact math routine. Magnification eventually reveals
the source image's finite resolution, but no longer exposes hard texel blocks.
The committed PNG is sufficient to build; `scripts/import-radioglobe-earth.py`
optionally regenerates it from the original EARTHTEX BGR source using macOS sips.
Drag and release to spin the globe; friction gradually stops it, and
pressing the left button grabs and stops it immediately. The motion follows
[libview's orbit controller](https://github.com/Leimy/libview/blob/master/orbit.c),
with decay based on elapsed time. The globe renders a quicker preview during
motion and restores full detail when it stops. During desktop magnification,
moving frames use nearest-neighbor scaling; smooth scaling returns at rest.
For a visual comparison, see the [README screenshots](README.md#radioglobe-on-macos).
On the development Mac, sampled full-quality deep-zoom frames in a 600x500
viewport had median CPU render times of 58.5 ms with filtering and the larger
texture, versus 35 ms previously. These measurements exclude drawterm display
latency. The quicker motion preview remains enabled; rendering cost depends on
viewport size, zoom and hardware.
The drawterm driver uploads only the changed rectangle, including its horizontal
bounds. `NativeScaleBenchmark.Mod` measures the CPU scaling cost separately from
globe rendering and drawterm transport; `--paint-stats` on
`scripts/test-a2-desktop-input.py` reports upload volume.

A [16-second RadioGlobe video demo](https://github.com/Leimy/A2-Drawterm-MacOS/releases/tag/radioglobe-demo-2026-11-13)
shows rotation, inertia, station markers and zoom. The silent MP4 records actual
committed framebuffer updates from A2's drawterm/9P interface at 800x600 and
60 fps on an independent capture thread, using finely stepped scripted pointer
input. Capture and encoding run on separate threads with a bounded queue to
reduce recording overhead. Frames repeat naturally when the application is
still; no motion interpolation is added. It does not capture other Mac windows.

**Recording caveat:** This video illustrates the interface, not live performance.
It was recorded through a scripted test harness rather than an ordinary interactive
drawterm session. Its rotation and zoom timing—especially the stepped zoom in
and out—are not representative of using RadioGlobe directly. The 60 fps capture
rate should not be interpreted as an application performance measurement.

To record another clip from a source build on macOS:

```sh
sh scripts/record-a2-radioglobe.sh build/native-current /tmp/my-radioglobe-demo.mp4
```

The development recording tool writes a `.timing.json` sidecar with capture and
source-frame timestamps, pointer events and encoder queue statistics. Its 9P
input loop avoids repeated full-screen hashing during a recording. These changes reduce the
original recorder's overhead, but the recording still does not reproduce the
timing or responsiveness of an ordinary interactive session.

The recording tool uses the existing Python input driver and a Swift
helper compiled with the Xcode command-line tools. macOS AVFoundation encodes
H.264; no ffmpeg installation is needed. It writes the MP4 and a matching PNG
poster, refuses to overwrite an existing video, and opens a separate A2 process
with a temporary working directory. The A2 runtime needs neither recording tool.

For native audio playback in BlueShell or the terminal Oberon shell, run
`RadioGlobeAudio.PlayMP3 RadioGlobeTest.mp3`. The `DarwinSound` driver implements
A2's `SoundDevices` interface using macOS AudioQueue. It supports mono/stereo,
8/16-bit PCM and sample rates from 8 to 192 kHz. macOS mixes concurrent playback
channels. Each channel has its own volume (256 = unity); the A2 output mixer
adds volume and mute without changing the Mac's system volume. Each channel has bounded native
buffers; AudioQueue callbacks remain in C, and reusable A2 buffers are returned
after copying. Playback uses neither drawterm audio nor an external player.
The command waits until the local file finishes playing. The native library `libA2Audio.dylib`
must sit beside the `OberonLoader` executable, including for terminal-only use.
`python3 scripts/test-a2-native-audio.py BUILD_DIRECTORY` plays the test clip
twice and checks unloading and reinstalling the driver. It needs audio-device access.
The probe also checks concurrent channels, volume/mute, buffer backpressure,
resume, stop, and closing. Existing `SoundDevices` clients can select this driver
after running `DarwinSound.Install`.
The desktop offers **Demos > Audio test** and **Tools > Audio mixer**.

For direct Icecast/Shoutcast-style MP3 streams, use these commands in BlueShell
or a persistent terminal Oberon shell:

```text
RadioGlobeAudio.PlayURL https://ice5.somafm.com/groovesalad-128-mp3
RadioGlobeAudio.Stop
```

`PlayURL` runs in the background and replaces the current station automatically.
HTTP/HTTPS transport uses macOS's system libcurl in `libA2Radio.dylib`, beside
`OberonLoader`. It validates TLS certificates, follows at most five redirects,
handles HTTP chunking and legacy `ICY 200 OK`, and buffers at most 64 KiB with
a 16 KiB startup target. Active Oberon removes ICY metadata from the audio and
prints `StreamTitle` updates in the launch terminal. Radio playback decodes
MP3, AAC/AAC+, native/Ogg FLAC and Ogg Opus with macOS AudioToolbox; Ogg Vorbis uses the
bundled MIT-licensed `stb_vorbis` decoder and system PCM conversion. Vorbis
logical-stream changes are handled so changing tracks can supply new headers
and codebooks. Output is converted to stereo 44.1 kHz PCM for the native sound
driver. The original Active Oberon MP3 decoder remains available for local
MP3 playback and `DecodeMP3`. Stop cancels network reads and playback; connection failures
and end-of-stream release both resources. Streams are not automatically reconnected.
Live MP3/AAC connections may begin partway through a frame; the decoder searches
for two consistent adjacent frame headers before handing audio to the system parser.
Ogg Opus/FLAC have bounded page/packet assembly, page CRC and sequence validation,
EOS trimming and chained-stream handling. Opus applies pre-skip and output gain. Cached Icecast
headers followed by the current live page sequence are accepted. Opus mapping
family zero (mono/stereo) is supported; multichannel mapping is not implemented.
Native FLAC uses bounded frame assembly with CRC8/CRC16 validation, and uses
STREAMINFO for exact finite-file duration. FLAC frames are passed directly to
AudioConverter, bypassing the system incremental FLAC file parser. Opus/FLAC require the system AudioToolbox decoder;
there are no extra installed libraries or helper processes.
Use a direct MP3, ADTS AAC/AAC+, native/Ogg FLAC, Ogg Opus or Ogg Vorbis mount URL.
HLS and playlist-file resolution are not implemented. The catalogue retains those entries
so its original data is preserved; the decoder reports unsupported streams.
`python3 scripts/test-a2-radio.py BUILD_DIRECTORY` checks local plain/ICY/chunked
streams, metadata boundaries, redirects, format/HTTP errors and cancellation.
Add `--playback --stations` to exercise local playback, map selection, station
switching, rapid requests, browser search and module cleanup. This requires
audio-codec/device access and does not contact a public station.
`python3 scripts/test-a2-codecs.py BUILD_DIRECTORY` verifies pitch, amplitude and
duration for generated MP3, AAC, AAC+, FLAC, Opus and Vorbis fixtures, including
chained Vorbis/Opus/FLAC tracks, live Opus sequence offsets and MP3 frame synchronization. `python3 scripts/test-a2-stations.py BUILD_DIRECTORY` checks the
catalogue snapshots, parsing, marker projection and picking. Pure globe geometry
tests use an empty catalogue fixture to measure the texture independently of markers.
`python3 scripts/test-a2-globe-texture.py BUILD_DIRECTORY` checks bilinear color
mixing, seam wrapping, pole clamping, subtexel continuity and angle accuracy.
Add `--radio-globe-quality --menu-app radio-globe` to the desktop input harness
for deterministic deep-zoom projection checks against an independent floating-point
bilinear reference; `--radio-globe-regression` covers poles, seams, inertia and resize.

The offline RadioGlobe codec command is also available in BlueShell:
`RadioGlobeAudio.DecodeMP3 input.mp3 output.wav`. It uses A2's MP3 decoder and
writes stereo 16-bit PCM WAV for a local MPEG-1 Layer III file. From the Mac
terminal, `afplay output.wav` plays the result. Conversion currently stops at
ten minutes. It also accepts a URL for finite stream regression tests.
`python3 scripts/test-a2-mp3.py BUILD_DIRECTORY`
checks generated MP3 silence through the decoder and validates the WAV output.
No personal MP3 is needed: the bundle includes `RadioGlobeTest.mp3`, an original
two-second test clip. Run `RadioGlobeAudio.DecodeMP3 RadioGlobeTest.mp3 RadioGlobeTest.wav`
in BlueShell, then `afplay RadioGlobeTest.wav` from the Mac terminal in your
launch directory. The codec regression also checks the clip's 440 Hz and 660 Hz tones.
The input-method selector offers Arabic, Armenian, Hebrew, Pinyin, Russian,
Ukrainian, and Unicode entry; the language switcher and window switcher are
also available from this page.
The native bundle includes BMP and JPEG image codecs for these tools and
existing applications such as Tetris. Skin and icon changes made in a running
session are not automatically persisted.

The Apple Silicon build also includes A2's Unix socket-backed IP, TCP, UDP,
and DNS modules. From a source checkout, run
`scripts/test-a2-network.sh build/native-current` to check byte order,
`localhost` lookup, local TCP/UDP traffic, and a TCP exchange with macOS
`nc` without contacting an external server. These modules are
available for native A2 programs; network applications still need their own
runtime checks before being added to the menu.

The bundle also includes A2's cryptography modules and test commands. For
example, `CryptoTools.Hash CryptoSHA256 filename` prints a file's SHA-256 hash
in BlueShell. From a source checkout, run
`scripts/test-a2-crypto.sh build/native-current` to check SHA-256, SHA-3,
MD5, and an AES-128 known-answer vector in the native runtime.

To edit and compile the example in PET, copy it into your launch
directory, run `PET.Open NativeDesktopHello.Mod` in BlueShell, then click
**Compile**. PET's Fox compiler uses the DarwinA2 AArch64 target here.

For a first PET assistant experiment, select source text in PET and run
`PETAssistant.Prepare` in BlueShell. That writes `PETAssistant.Selection.txt`
in the launch directory. From the Mac terminal in that directory, run
`/path/to/a2-bundle/pet-assist.sh "What could be improved here?"`.
The script finds the Codex executable on `PATH` or inside ChatGPT.app, uses it
in read-only mode, and saves its answer as
`PETAssistant.Response.txt`. Open it in BlueShell with
`PET.Open PETAssistant.Response.txt`. The assistant does not change, compile,
or load the selected module.

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

### SuperPET

Choose **Development → SuperPET** or enter `SuperPET.Open filename.Mod` in BlueShell.
In the source, split view, or scratch pane, right-click a module identifier such as
`CSPDemo` to open its source in a tab. Right-clicking another identifier selects
its next occurrence, wrapping at the end. SuperPET uses PET's Compile button,
diagnostics, and text size controls. **Development → PET editor** opens classic PET.

To launch a compiled module with arguments, type `CSPDemo.Run 100 ~` in scratch
and middle-click **CSPDemo.Run**. SuperPET supplies the command's arguments and
shows output written to `context.out` in the page log. Middle-clicking an exported
command such as `Run*` in the Program Structure tree launches it with empty
arguments and sends its default output to the kernel log.

**Structural Edit.** Select text in the source or split view, enter a command in
the field beside **Text +**, and press Return or click **Edit**. A comma addresses
the whole buffer. A dot (or no address) uses the selection, or the caret if the
selection is empty. Output and errors appear in the page log. Store saves the source.

| Command | Effect |
| --- | --- |
| `,x/TODO/p` | Print every match for TODO in the file. |
| `x/beta/c/DELTA/` | Replace each beta in the selection with DELTA. |
| `,x/.*\n/g/TODO/x/[ \t]+$/d` | Trim trailing spaces and tabs from newline-terminated lines containing TODO. |

This single-buffer subset supports nested **x** (each match), **g** (if a match
exists), and **v** (if no match exists). Finish with **p** (print), **d** (delete),
**c/text/** (change), **i/text/** (insert before), or **a/text/** (append after).
Patterns use Darwin's extended regular expressions. Use `\n` for newline,
`\t` for tab, and `\/` for a slash. Changes use PET's ordinary undo history,
so undoing a batch can take multiple presses.

### CSP communication for active objects

The current source build includes `source/CSP.Mod`, a shared coordinator using
ordinary Active Oberon `EXCLUSIVE` regions and `AWAIT`. The typed interface is
`source/CSPChannels.Mod`, using Fox's existing parameterized modules:

```oberon
IMPORT CSP,
    Numbers := CSPChannels(SIGNED64),
    Requests := CSPChannels(Request);
```

Each instance supplies `Channel` and `Offer` types: `Numbers.Channel.Send`
accepts an integer, while `Requests.Channel.Send` accepts a `Request`. Receive
variables and offer results are checked against the same type. Records, fixed
arrays, and object references are supported. Records and arrays are copied when
a send or send offer is created; embedded object references remain shared.
All instances use the same CSP coordinator, so choices can span payload types.
The coordinator moves opaque `CSP.Packet` references. Only the generic channel
packs and unpacks a value of its payload type. Migrate earlier integer and
object channels to `CSPChannels(SIGNED64)` and `CSPChannels(YourObjectType)`
respectively, and recompile their clients.

`NEW(channel, 0)` creates an unbuffered rendezvous: a successful send waits for
an actual receiver. A positive capacity creates a bounded FIFO; a successful
buffered send means the value was accepted into the buffer. Neither operation
waits for the receiver to finish processing the value. Use a reply channel if
completion needs acknowledgement.

From BlueShell, run the concurrent sieve:

```text
CSPDemo.Run 50
```

It prints the primes through 50 in the invoking shell (BlueShell or Terminal),
propagates channel closure down the pipeline,
and joins every filter activity before returning. Its source is
`source/CSPDemo.Mod`; it now imports `Numbers := CSPChannels(SIGNED64)`.
The coordinator, generic template, and demo are compiled by both the desktop
recipe and the native compiler extras recipe. Fox includes the specialization's
code in the importing module's object file; there is no standalone template
object file to load.

To update an existing session that loaded an earlier CSP build, run
these commands separately in BlueShell (adjust the checkout path if needed):

```text
System.Free CSPDemo
System.Free CSP
Compiler.Compile -p=DarwinA2 /Users/dave/srcs/oberon/source/CSP.Mod /Users/dave/srcs/oberon/source/CSPChannels.Mod /Users/dave/srcs/oberon/source/CSPDemo.Mod
CSPDemo.Run 50
```

This writes compiled modules to the working directory. Keep the template's
`CSPChannels.SymAa` with the bundle so other payload types can be compiled.
As with other A2 modules, updates require unloading importing modules before
their dependencies.

The same demo runs without graphics. From the checkout:

```sh
repo=$(pwd)
bundle="$repo/build/native-current"
toolchain="$repo/build/native-toolchain"
mkdir -p ~/A2-cli-work
cd ~/A2-cli-work
export OBERON_CORE="$toolchain/DarwinAosCompilerAa"
export AOSPATH="$PWD:$bundle:$toolchain:$repo/data"
export AOSCONFIG='Color 0 StackSize 8192'
"$bundle/OberonLoader" do 'CSPDemo.Run 50'
```

Channel operations return `CSP.Success`, `Closed`, `Cancelled`, or `WouldBlock`
(the last for nonblocking calls). A failed receive preserves its output variable.
Pass `NIL` for no cancellation, or `NEW(cancel)` to create a one-shot
`CSP.Cancellation`. Calling `cancel.Cancel` wakes affected communications; it
neither terminates active objects nor undoes a communication already committed.
`channel.Close()` returns true only on the first close. Pending sends fail;
receives drain accepted buffered values before returning `Closed`.

For atomic external choice, construct fresh offers from the channels and call
`CSP.Select`, or `CSP.TrySelect` for a default/nonblocking alternative. For example,
this helper can be called from an active object supplied with two integer channels:

```oberon
IMPORT CSP, Numbers := CSPChannels(SIGNED64);

PROCEDURE ReceiveEither(a, b: Numbers.Channel; cancel: CSP.Cancellation;
    VAR source: SIZE; VAR value: SIGNED64): SIGNED32;
VAR left, right: Numbers.Offer; offers: ARRAY 2 OF CSP.Offer; result: SIGNED32;
BEGIN
    left := a.ReceiveOffer(); right := b.ReceiveOffer();
    offers[0] := left; offers[1] := right;
    result := CSP.Select(offers, cancel, source);
    IF result = CSP.Success THEN
        IF source = 0 THEN ASSERT(left.Get(value)) ELSE ASSERT(right.Get(value)) END
    END;
    RETURN result
END ReceiveEither;
```

Send and receive offers from different generic instances
may be mixed in the same `ARRAY OF CSP.Offer`. Typed offers are normalized before
entering the coordinator; their typed `Get` methods preserve the result type.
Exactly one branch commits; losing branches are withdrawn atomically. Two
branches of the same choice cannot rendezvous with each other. On `Success`
or `Closed`, the returned index identifies the branch; on `Cancelled`,
`WouldBlock` or `Invalid`, it is -1. An empty array, `NIL` entry, repeated offer
object, or previously used offer is `Invalid`. Every accepted choice consumes
all its offers, including after cancellation or `WouldBlock`; create new offers
for the next choice. `Get` succeeds only on the selected successful receive.
In a receive loop, remove a drained channel after its branch returns `Closed`.
It stays ready while closed. Exit the loop when the last input closes.

The first implementation uses one passive coordinator monitor and rotates the
starting branch of successive multi-branch choices. This avoids fixed branch
priority, but is not a guarantee of scheduler fairness or libthread's randomized
`alt` policy. There are no callbacks under the monitor, polling loops, per-channel
active objects, built-in deadlines, or new ownership rules. The implementation
prioritizes auditable communication semantics over maximum throughput. The
generic facade allocates one GC-traced payload box for each send or send offer.
It uses ordinary typed assignment rather than raw memory copying; applications
need no `ANY` payloads, casts, or handwritten channel wrappers.

Run the native concurrency tests from the checkout:

```sh
python3 scripts/test-a2-csp.py --repeat 20
```

They compile into a temporary directory and exercise rendezvous, FIFO/backpressure,
24-way receive, heterogeneous and bilateral choices across generic instances, cancellation,
close/drain, typed record/array copying, GC, invalid offers, and contention with
eight producers and three consumers. Five negative compilation cases check
that incorrect payloads, result variables and channel types are rejected. Each
suite transfers 2,400 values and checks for loss/duplication; every native process
has a timeout so a blocked protocol fails the test run.

The native bridge also has a fragmented-input sanitizer probe (from the repo root):

```sh
clang -arch arm64 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  tests/NativeRadioCodecProbe.c UnixAos/boot/DarwinCodecs.c \
  -framework AudioToolbox -o /tmp/a2-codec-boundaries
/tmp/a2-codec-boundaries data
```

It checks 1-, 7-, 137- and 4096-byte input fragments for every bundled codec fixture.

An optional FAAD2 evaluation probe is available for David Leimbach's
[9front aacdec](https://github.com/leimy/aacdec) source tree. AAC playback in
A2 currently uses AudioToolbox; this probe does not change the playback backend
or add FAAD2 to the release bundle. It builds a separately obtained local
checkout in a temporary directory and checks AAC-LC, HE-AAC and mono fixtures:

```sh
python3 scripts/test-a2-faad.py /path/to/aacdec
python3 scripts/test-a2-faad.py /path/to/aacdec --sanitize
```

Evaluated revision: `c50992e2d5e02e69b4065e23fa7a074756516a76`.
The decoder source carries GPL notices. No decoder sources or binaries are
vendored by this probe. Runtime integration still needs bounded ADTS input,
per-stream decoder state, PCM format-change handling and mixer integration;
release packaging also needs to account for the decoder's license notices.

## Experimental desktop with lightweight activities

From the source checkout on Apple Silicon, build the experimental image with
the native compiler in `build/native-toolchain`. Use a separate writable
directory so previously compiled modules cannot shadow this image's modules.

```sh
cd ~/srcs/oberon
scripts/build-a2-native.sh desktop-lightweight build/native-lightweight-desktop
mkdir -p ~/A2-work-lightweight
cd ~/A2-work-lightweight
~/srcs/oberon/build/native-lightweight-desktop/a2
```

The system event log starts a lightweight dispatcher at desktop startup. A
native producer can enqueue an event, and the dispatcher wakes on its service
worker to deliver it to the registered sinks. System → Shutdown stops the
queue and joins the dispatcher. Other desktop active objects continue to use
their existing execution paths.

To write a service for either build, import `ServiceActivities`, keep a
`ServiceActivities.Service` handle and call `ServiceActivities.Start(obj.Run)`
with a parameterless method. When shutting down, wake the method through its
own stop protocol and call `handle.Join()`. It returns TRUE when the method
returns normally. The portable recipe compiles `ServiceActivities.Mod`, whose
worker uses an ordinary `{ACTIVE}` body. The lightweight desktop recipe
substitutes `Darwin.ServiceActivities.Mod`, which declares the same module
name and schedules the body on the shared worker. Both compile the same
`Events.Mod`. No platform detection is needed in a service module.

For an independently lived active object, extend
`ServiceActivities.DetachedObject` and use its ordinary constructor and
`BEGIN {ACTIVE}` body. RadioGlobe's status watcher is an example. In the
experimental desktop its body runs on the service worker and its normal
`{EXCLUSIVE}` methods are callable from the UI. The creator can return
immediately. The owner signals termination and waits where its own lifetime
requires it (RadioGlobe waits at module cleanup). On the portable backend
the base is empty and A2 starts the active body as usual. Explicit priority
or process flags retain the native execution path.

On a lightweight activity, `Objects.Sleep(ms)` parks until a monotonic deadline.
Other runnable activities can use that pthread in the meantime. A zero delay
yields one turn. A caller holding a native A2 monitor uses pthread sleep so a
sibling cannot deadlock the worker by trying to acquire that monitor.

To repeat the service lifecycle and timer regressions, run
`scripts/test-a2-lightweight-activities.sh` from the checkout. To exercise
desktop startup, Tetris, and the Shutdown menu with a simulated drawterm
connection, run the following from the checkout:

```sh
python3 scripts/test-a2-desktop-input.py --cwd "$(mktemp -d)" \
    --loader build/native-lightweight-desktop/OberonLoader \
    --core build/native-lightweight-desktop/DarwinAosDrawtermDesktopAa --tetris-shutdown
```
