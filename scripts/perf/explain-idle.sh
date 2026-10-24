#!/bin/bash
# Records what Liova does while it should be idle, to explain a failed idle CPU or wakeups
# budget. Launches the app the way liova-perf does, lets it settle, then for SECONDS:
#   - samples every thread's stack (`sample`) to show which code runs,
#   - takes a spindump when it can (sudo; passwordless on CI runners) for per-thread CPU,
#   - and keeps every log line Liova's process wrote, including macOS frameworks'.
# Usage: scripts/perf/explain-idle.sh <Liova.app> [OUT_DIR] [SECONDS]
set -euo pipefail

app="${1:?usage: explain-idle.sh <Liova.app> [OUT_DIR] [SECONDS]}"
out="${2:-build/idle-diagnosis}"
seconds="${3:-30}"
settle=20
executable="$app/Contents/MacOS/Liova"
mkdir -p "$out"

"$executable" -hasSeenWelcome YES > /dev/null 2>&1 &
pid=$!
trap 'kill $pid 2> /dev/null || true' EXIT
echo "Liova started (pid $pid); settling for $settle s"
sleep "$settle"

start=$(date "+%Y-%m-%d %H:%M:%S")
echo "Recording $seconds s of idle"
if sudo -n true 2> /dev/null; then
    sudo spindump "$pid" "$seconds" 10 -file "$out/spindump.txt" > /dev/null 2>&1 &
    spindump=$!
fi
sample "$pid" "$seconds" 1 -file "$out/sample.txt" > /dev/null 2>&1
if [ -n "${spindump:-}" ]; then
    wait "$spindump" || echo "spindump failed"
fi
/usr/bin/log show --start "$start" --style compact --info --debug \
    --predicate "processID == $pid" > "$out/log.txt" 2>&1 || true

echo "Log lines by sender while idle:"
awk 'NR > 1 { print $5 }' "$out/log.txt" | sort | uniq -c | sort -rn | head -20
echo "Busiest stacks (sample):"
grep -A 40 "Sort by top of stack" "$out/sample.txt" | head -40 || true
echo "Files in $out"
