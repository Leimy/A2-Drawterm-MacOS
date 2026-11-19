#!/bin/sh
# TLA2TOOLS is the absolute path of tla2tools.jar. JAVA can select a JRE.
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/../tests/model" && pwd)
: "${TLA2TOOLS:?Set TLA2TOOLS to the absolute path of tla2tools.jar}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$src/MonitorWake.tla" .
run() { "${JAVA:-java}" -XX:+UseParallelGC -cp "$TLA2TOOLS" "$@"; }
run pcal.trans MonitorWake.tla
run tlc2.TLC -config "$src/MonitorWake.cfg" MonitorWake
# Make the faulty algorithm exhibit a liveness violation even if TLC finds
# a deadlock first with the default deadlock checker.
sed 's/DropEarly = FALSE/DropEarly = TRUE/' "$src/MonitorWake.cfg" > Lost.cfg
if run tlc2.TLC -deadlock -config Lost.cfg MonitorWake >trace.log 2>&1; then
    echo 'Lost early notification unexpectedly passed' >&2; exit 1
fi
grep -F 'Temporal properties were violated' trace.log || { cat trace.log; exit 1; }
cat trace.log
