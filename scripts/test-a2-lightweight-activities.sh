#!/bin/sh
# Builds a separate compiler core with experimental stack scanning. The
# existing native toolchain supplies the unchanged bootstrap modules.
set -eu
case "${1:-10000}" in
    10000|100000) limit=${1:-10000}; command_mode=false ;;
    --do) [ "$#" -eq 2 ] || { echo 'Expected one quoted A2 command' >&2; exit 2; }; command_mode=true ;;
    *) echo "Usage: $0 [10000|100000|--do 'Module.Command args']" >&2; exit 2 ;;
esac
run_timeout=90
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
seed=${A2_COMPILER_LIBRARY:-$repo/build/native-toolchain}
seed=$(CDPATH= cd -- "$seed" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/a2-activities.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$seed/OberonLoader" "$work/"
cc -arch arm64 -O2 -dynamiclib -Wall -Wextra -Werror -Wno-deprecated-declarations \
    "$repo/UnixAos/boot/DarwinActivities.c" -o "$work/libA2Activities.dylib"
cd "$work"
export AOSCONFIG='Color 0 StackSize 8192'
export AOSPATH="$work:$seed:$repo/source:$repo/tests:$repo/data"
export OBERON_CORE="$seed/DarwinAosCompilerAa"
# Recompile Objects and its importers against the experiment's Process type.
sed '1d;s/AMD64.Builtins.Mod .* Unix.Objects.Mod/Unix.Objects.Mod/;s/--define=UNIX,AARCH64,DESKTOP /--define=UNIX,AARCH64,DESKTOP,LIGHTWEIGHT /' \
    "$repo/build/DarwinAArch64Compiler.txt" > core.txt

# The loader handles SIGALRM itself. Keep the deadline in its parent.
with_deadline() {
    perl -e '
        my $seconds = shift;
        my $child = fork();
        defined $child or die $!;
        if (!$child) { exec @ARGV or die $! }
        $SIG{ALRM} = sub { kill "KILL", $child };
        alarm $seconds;
        waitpid($child, 0);
        exit($? == 0 ? 0 : 1);
    ' "$@"
}

run() {
    if ! with_deadline "$run_timeout" ./OberonLoader "$@" > run.log 2>&1 ||
       grep -Eq 'error:|native signal|Command not successful|Trap [0-9]+' run.log; then
        cat run.log >&2
        exit 1
    fi
}
run execute core.txt
grep -q 'Link successful' run.log
run compile -p=DarwinA2 CSP.Mod CSPChannels.Mod CSPDemo.Mod ConcurrentSieve.Mod DarwinActivities.Mod DarwinCommandWorkers.Mod DarwinActivitiesProbe.Mod
# Networking needs the corrected Darwin errno constant in the symbol file.
# Keep the bootstrap Unix implementation linked into the experimental core.
run compile -p=DarwinA2 --traceModule=Trace --define=UNIX,AARCH64,DESKTOP Darwin.Unix.Mod
run compile -p=DarwinA2 --define=UNIX,AARCH64,DESKTOP Network.Mod Unix.IP.Mod Unix.Sockets.Mod Unix.TCP.Mod
run compile -p=DarwinA2 --define=UNIX,AARCH64,DESKTOP,LIGHTWEIGHT Network.Mod Unix.IP.Mod Unix.Sockets.Mod Unix.TCP.Mod DarwinTCPActivityProbe.Mod
test -s TCP.GofAa
test -s DarwinActivitiesProbe.GofAa
export OBERON_CORE="$work/DarwinAosCompilerAa"
routes='ConcurrentSieve.Run:ConcurrentSieve,CSPDemo.Run:CSP'
if "$command_mode"; then
    export AOSCONFIG="$AOSCONFIG ActivityWorkers ${A2_ACTIVITY_WORKERS:-2} ActivityCommands $routes"
    ./OberonLoader do "$2"
    exit $?
fi
run do DarwinTCPActivityProbe.Run
grep -F "PASS TCP.Receive loopback" run.log
run compile -p=DarwinA2 DarwinLoopCheckpointProbe.Mod
# The rebuilt compiler can create objects without owner read permission.
chmod u+rw DarwinLoopCheckpointProbe.GofAa DarwinLoopCheckpointProbe.SymAa
run do DarwinLoopCheckpointProbe.Control
grep -F 'PASS default compilation' run.log
run compile -p=DarwinA2 --activityCheckpoints DarwinLoopCheckpointProbe.Mod
chmod u+rw DarwinLoopCheckpointProbe.GofAa DarwinLoopCheckpointProbe.SymAa
run do DarwinLoopCheckpointProbe.Run
grep -F 'PASS compiler checkpoints' run.log
run do 'DarwinActivitiesProbe.Run 100000'
grep -F 'PASS GCD socket readiness' run.log
grep -F 'PASS competing native-monitor' run.log
grep -F 'PASS 1000 native/fiber' run.log
grep -F 'PASS 128 lightweight activities on two distinct pthreads' run.log
grep -F 'PASS cooperative CPU loops alternate' run.log
grep -F 'PASS two ACTIVE bodies, contended EXCLUSIVE and 1000 AWAIT exchanges on one pthread' run.log
grep 'PASS single worker, parked GC and exact sieve through 100000: 9592 activities' run.log

# Independently check the entire printed prime sequence and the number of
# ordinary NEW bodies that ran to completion through this scheduler.
check_tree() {
    run do "DarwinActivitiesProbe.$1 $2"
    awk -v limit="$2" '
        BEGIN {
            for (n = 2; n <= limit; n++) if (!composite[n]) {
                primes[++count] = n
                for (i = n+n; i <= limit; i += n) composite[i] = 1
            }
        }
        { sub(/\r$/, "") }
        /^2( |$)/ {
            if (NF != count) exit 1
            for (i = 1; i <= NF; i++) if ($i != primes[i]) exit 1
            exact++
        }
        /^Joined lightweight filter bodies: / { if ($NF == count) joined++ }
        END { if (exact != 1 || joined != 1) exit 1 }
    ' run.log
    if [ "$1" = Mailboxes ]; then grep "^Active-object sieve through " run.log; fi
    echo "PASS $1 through $2, every prime and filter join verified"
}
if [ "$limit" = 100000 ]; then run_timeout=600; fi
check_tree Mailboxes "$limit"
run_timeout=90
check_tree Channels 1000

base_config=$AOSCONFIG
export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinActivitiesProbe.RecordWorker:-"
run do DarwinActivitiesProbe.CheckReuse
grep -F 'PASS one worker reused' run.log
export AOSCONFIG="$base_config ActivityWorkers 4 ActivityCommands $routes,DarwinActivitiesProbe.BlockWorker:-,DarwinActivitiesProbe.ReleaseWorker:-"
run do DarwinActivitiesProbe.CheckRouting
grep -F 'PASS demand scaling' run.log
grep -F 'PASS ordinary commands on two automatically assigned worker pthreads' run.log
if [ "$limit" = 100000 ]; then run_timeout=600; fi
run do "ConcurrentSieve.Run $limit"
grep -F "Active-object sieve through $limit:" run.log
run do 'CSPDemo.Run 1000'
grep -F 'CSP sieve finished; all filter activities joined' run.log

export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinActivitiesProbe.TrapWorker:DarwinActivitiesProbe,DarwinActivitiesProbe.RecordWorker:DarwinActivitiesProbe"
if ! with_deadline 20 ./OberonLoader do DarwinActivitiesProbe.CheckRecovery > trap.log 2>&1 ||
   [ "$(grep -ac 'Trap 5[.]73 ' trap.log)" != 2 ] ||
   [ "$(grep -ac 'native signal' trap.log)" != 2 ] ||
   ! grep -aF 'PASS pooled HALT returned CommandTrapped' trap.log; then
    cat trap.log >&2
    exit 1
fi

export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinActivitiesProbe.ChildTrap:DarwinActivitiesProbe,DarwinActivitiesProbe.RecordWorker:DarwinActivitiesProbe"
if ! with_deadline 20 ./OberonLoader do DarwinActivitiesProbe.CheckChildRecovery > child.log 2>&1 ||
   ! grep -aF 'FailingChild' child.log >/dev/null ||
   ! grep -aF 'PASS child trap unwound parent FINALLY' child.log; then
    cat child.log >&2
    exit 1
fi

export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinActivitiesProbe.NativeWaitTrap:-,DarwinActivitiesProbe.RecordWorker:-"
if ! with_deadline 20 ./OberonLoader do DarwinActivitiesProbe.CheckNativeRecovery > nativewait.log 2>&1 ||
   ! grep -aF 'PASS cancelled native-monitor wait' nativewait.log; then
    cat nativewait.log >&2
    exit 1
fi

export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinActivitiesProbe.SocketWaitTrap:-,DarwinActivitiesProbe.RecordWorker:-"
if ! with_deadline 20 ./OberonLoader do DarwinActivitiesProbe.CheckSocketRecovery > socketwait.log 2>&1 ||
   ! grep -aF 'PASS quiet socket cancellation' socketwait.log; then
    cat socketwait.log >&2
    exit 1
fi

export AOSCONFIG="$base_config ActivityWorkers 1 ActivityCommands DarwinTCPActivityProbe.TrapReceive:-"
if ! with_deadline 20 ./OberonLoader do DarwinTCPActivityProbe.CheckCancellation > tcpwait.log 2>&1 ||
   ! grep -aF 'PASS cancellation releases the TCP reader' tcpwait.log; then
    cat tcpwait.log >&2
    exit 1
fi
