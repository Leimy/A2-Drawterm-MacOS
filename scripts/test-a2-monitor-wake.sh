#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$repo/tests/MonitorWakeMain.Mod" .
cat >Makefile <<'MAKE'
PROGRAM = monitor-test
MODULES = MonitorWakeMain
A2_PROFILE = activities
A2_EXTRA_DEFINE = MONITORTEST
include $(A2_BRANCH)/build/standalone.mk
MAKE
make A2_BRANCH="$repo"
# Use a parent watchdog since the runtime controls the child's signal mask.
perl -e '
    my $pid = fork(); defined $pid or die "fork: $!";
    if (!$pid) { exec "./monitor-test"; die "exec: $!" }
    $SIG{ALRM} = sub { warn "monitor-test timed out waiting for progress\n"; kill "KILL", $pid; };
    alarm 60; waitpid($pid, 0); exit($? == 0 ? 0 : 1);
' > result 2>&1 || { cat result >&2; exit 1; }
grep -F 'PASS 64 posts before park' result
