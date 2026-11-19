## Active Object System (AOS aka A2) git repository (from 9.12.2022)

An experimental native Apple Silicon desktop port is documented in
[RELEASE-DARWIN-AARCH64.md](RELEASE-DARWIN-AARCH64.md). It was developed with
substantial assistance from OpenAI Codex under the direction and testing of an
Active Oberon enthusiast; it is an independent preview, not an ETH release.

[Download the Apple Silicon preview](https://github.com/Leimy/A2-Drawterm-MacOS/releases/tag/preview-2026-11-19),
including drawterm and the native compiler toolchain.

### Lightweight active objects on Apple Silicon

The opt-in lightweight runtime lets many Active Oberon objects share a worker
thread. Each activity keeps its own stack. When it parks in `AWAIT`, timed
sleep, or a supported TCP operation, the worker can run another activity.
CPU-bound loops in an `{ACTIVE}` body can also cooperate when compiled with
`--activityCheckpoints`.

**Try it in Terminal.** From the source checkout on an Apple Silicon Mac with
the Xcode command-line tools, point `A2_COMPILER_LIBRARY` at the extracted
preview's `toolchain` directory. If your checkout already has
`build/native-toolchain`, you can omit the first line.

```sh
export A2_COMPILER_LIBRARY="/path/to/A2-Darwin-arm64-preview/toolchain"
A2_ACTIVITY_WORKERS=1 scripts/test-a2-lightweight-activities.sh --do 'ConcurrentSieve.Run 1000'
```

The script builds a temporary runtime and runs the sieve without opening the
desktop. The sieve creates an ordinary active filter for each prime using
`NEW`. All 168 filters run on one worker and finish before the command returns.
[Sieve source](source/ConcurrentSieve.Mod)

#### ActivityTrees on macOS and Linux (experimental)

Active Oberon already provides active objects: `NEW` starts an object's
`{ACTIVE}` body, `{EXCLUSIVE}` protects shared state, and `AWAIT` lets a body
wait for a condition. **This fork added the `ActivityTrees` library** to run
ordinary active objects on a chosen number of worker threads and join them
as a group. Applications import `ActivityTrees`. macOS on Apple Silicon and Linux on
x86-64 share the tree, scheduler, and fiber-switching logic. The build selects
Darwin's Mach/GCD backend or Linux's glibc/poll backend. Each backend locates
the live stack and registers for garbage collection.

From a native A2 entry point, pass a parameterless procedure or bound method:

```oberon
ok := ActivityTrees.Run(sieve.Run, 4, used)
```

Think of the tree as a family. The root is `sieve.Run`. It creates the filter
for 2, which creates the filter for 3, which creates the filter for 5.
The root can finish feeding numbers while the last filter still has work.
The caller waits for the whole family. This is a **join**. Each body can
finish independently, whereas a barrier would make the participants wait
for each other before continuing. Explicitly detached services have their
own lifetimes.

- **`workers`** requests 1–64 pthreads for this call, in addition to the
  waiting caller. The runtime assigns new bodies round-robin. Each stays on
  its assigned worker, and macOS schedules those threads on CPU cores.
- **`used`** reports how many distinct workers actually ran at least one
  application body, including the root. Even a value of four says nothing
  about whether four cores were busy at the same instant.
- **`ok`** is true on normal completion. If a body traps, the runtime
  initiates cooperative cancellation, unwinds parked siblings, and returns
  false after the workers stop.

Try the same sieve with four workers using the compiler setting above:

```sh
scripts/test-a2-lightweight-activities.sh --do 'DarwinActivityTreeProbe.Run 4 1000'
```

Expect 168 primes and `Sieve workers used: 4`. The filter code is the same
as in the single-worker example.
[Runtime](source/ActivityTrees.Mod) · [Probe](tests/DarwinActivityTreeProbe.Mod)

**Use it in a desktop application.** RadioGlobe declares its watcher as
`StatusWatcher = OBJECT(ServiceActivities.DetachedObject)` and starts it with
`NEW(watcher, orbit)`. Its ordinary `BEGIN {ACTIVE}` body survives the return
from `Open`. The UI calls `watcher.Stop` when the window closes. The build
selects the shared worker on the lightweight desktop or an ordinary active
object on portable A2. To try the watcher, build the `desktop-lightweight`
target and open **Demos → RadioGlobe**. [Watcher source](source/WMRadioGlobe.Mod)
· [Desktop build and launch instructions](README-native-desktop.md#experimental-desktop-with-lightweight-activities)

### Building a standalone terminal application

The same project Makefile selects the host [build rules](build/standalone.mk):

```make
PROGRAM = hello
MODULES = Hello HelloMain

A2_BRANCH ?= $(HOME)/srcs/oberon
include $(A2_BRANCH)/build/standalone.mk
```

List modules in initialization order, with the entry module last. Use
`make run` to build and launch, or `make module` to compile only.
For a program importing `ActivityTrees`, set `A2_PROFILE = activities` before
the include. Set `RUN_ARGS` to pass arguments to the program.
On macOS, the build compiles the embedded-core loader from the same checkout
as the make rules. `A2_TOOLCHAIN` defaults to `$(A2_ROOT)/build/native-toolchain`.
The activities profile embeds its fiber runtime in the executable.

On x86-64 Linux, install make, a C compiler, and glibc development headers
(glibc 2.30 or newer). Unpack the stock A2 Linux64 distribution and set
`A2_TOOLCHAIN` to the directory containing `oberon` and `bin/` (default
`~/Linux64`). The activities profile builds `libA2Activities.so` next to
the ELF executable. Copy both files together when moving the program.

From either host, run the shared acceptance test:

```sh
scripts/test-a2-activity-trees.sh
```

It compares all primes through 1,000 with one and four workers, then checks
that a trapped body unwinds a parked sibling after garbage collection. It also
forces a notification to arrive before its waiter parks and checks the cost
of repeated wakeups. The [monitor wakeup model](tests/model/README.md) explores
interleavings and shows the counterexample when early delivery is disabled. The Linux
backend was exercised under QEMU on Debian 12 x86-64. Other A2 targets still
need a worker and stack-scanning backend to provide this API.

### RadioGlobe on macOS

The native Apple Silicon desktop includes RadioGlobe, based on
[David Leimbach's 9front application](https://github.com/leimy/radioglobe), with
9,297 catalogue stations, globe markers, station search and native audio playback.
Open **Demos → RadioGlobe**; drag to rotate, use the wheel to zoom, and click a
marker to play. **Stations** opens the searchable catalogue. Playback supports
MP3, AAC/AAC+, Opus and native/Ogg FLAC, plus Ogg Vorbis.

[**Watch the RadioGlobe demo**](https://github.com/Leimy/A2-Drawterm-MacOS/releases/download/radioglobe-demo-2026-11-13/radioglobe-demo.mp4)
— 16 seconds, 60 fps capture, silent H.264 MP4, about 4 MB. The clip shows rotation, inertia,
station markers and zoom, recorded from A2's drawterm/9P framebuffer.

**Recording caveat:** This video illustrates the interface, not live performance.
It was recorded through a scripted test harness rather than an ordinary interactive
drawterm session. Its rotation and zoom timing—especially the stepped zoom in
and out—are not representative of using RadioGlobe directly. The 60 fps capture
rate should not be interpreted as an application performance measurement.

[![Watch RadioGlobe rotate and zoom](docs/images/radioglobe-demo.png)](https://github.com/Leimy/A2-Drawterm-MacOS/releases/download/radioglobe-demo-2026-11-13/radioglobe-demo.mp4)

The current source build improves close zoom with **bilinear filtering written
in Active Oberon**, a **4096×2048 Earth texture**, and interpolated angle lookup
tables. The texture wraps across the longitude seam and clamps at the poles.
These captures show the same view and zoom before and after the change:

| Previous nearest-neighbor rendering | Filtered high-resolution rendering |
| --- | --- |
| ![RadioGlobe close zoom before filtering](docs/images/radioglobe-zoom-before.png) | ![RadioGlobe close zoom after filtering](docs/images/radioglobe-zoom-after.png) |

The larger texture uses about 32 MiB decoded. On the development Mac, sampled
full-quality deep-zoom frames in a 600×500 viewport took a median 58.5 ms,
compared with 35 ms before. Rotation retains the faster preview path and restores
full detail when motion stops. Filtering smooths magnification; detail remains
limited by the source image's resolution.

See [native build and desktop instructions](README-native-desktop.md) for building,
launching, controls and verification. The 2026-11-13 readiness preview includes
these changes; older preview downloads may not include them.

### SuperPET on macOS

The current source build includes **SuperPET**, a fork of the Programmer’s Editing
Tool with Acme-style mouse actions and structural editing. Open **Development →
SuperPET**. Right-click a module name to visit its source, or middle-click a command
in scratch text to run it. The **Edit** field applies expressions such as
`x/TODO/c/DONE/` to the current selection. See the [SuperPET guide](README-native-desktop.md#superpet)
for command arguments, examples, and supported editing operations.

In order to run A2 on your Windows- or Linux-based system, clone this repository and unzip the appropriate binary within the repository. Example (Linux, AMD64):
```
git clone https://gitlab.inf.ethz.ch/felixf/oberon.git
cd oberon
unzip Linux64
Linux64/a2.sh
```
Note that in order to keep size of the repository reasonable, we do not commmit binary files directly into the git repository. Instead, we use the large file storage (LFS) support of gitlab in order to keep these files out of local git storage of your computer. 

If you cannot or do not want to install LFS for git, you need to download the corresponding zip file from this gitlab website because then git is downloading only a stub of the files. You can identify this with file sizes: if the zip files in the root directory of this project are a few bytes small, then you do not have lfs installed.

Please inform me, if you need developer-access to the repository, if you observe missing files, or if you, in general, want to help setting this up.

## Active Object System (AOS aka A2) SVN repository (before 9.12.2022)

Unregistered users can download the A2 system from the repository located at https://svn-dept.inf.ethz.ch/svn/lecturers/a2/trunk using svn (read only access as user "infsvn.anonymous" using password "anonymous")

To checkout the trunk, use
<pre>
svn checkout --username infsvn.anonymous --password anonymous https://svn-dept.inf.ethz.ch/svn/lecturers/a2/trunk aos
</pre>

## Build Server

The previously existing build-server is being replaced by the CI/CD pipeline in this gitlab. Currently, the pipeline builds the binaries for each commit in a zip file. The zip-files comprise the most-recent binaries and can be downloaded from the pipeline artifacts. More tests will follow. 
