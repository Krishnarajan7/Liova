#!/bin/bash
# Launches a built Liova.app and checks that it starts, stays up and answers on its socket.
#
#   scripts/ci/launch-check.sh build/Build/Products/Debug/Liova.app [seconds]
#
# CI runs this on the oldest macOS versions Liova supports, with an app built on the newest:
# the unit tests only ever run where the app was built, so this is what catches a start-up
# crash that only an older macOS has. Exits 0 when the app is healthy.
set -euo pipefail

app="${1:?Usage: launch-check.sh path/to/Liova.app [seconds]}"
seconds="${2:-20}"
executable="$app/Contents/MacOS/Liova"
cli="$app/Contents/Helpers/liova"
reports="$HOME/Library/Logs/DiagnosticReports"

[ -x "$executable" ] || { echo "Not a Liova app: $app"; exit 2; }
if pgrep -x Liova > /dev/null; then
  # A second copy hands off to the first and quits, which would look like a failure.
  echo "Liova is already running. Quit it first."
  exit 2
fi

# A private socket, so the check never talks to (or disturbs) another copy's.
work="$(mktemp -d)"
export LIOVA_SOCKET="$work/liova.sock"
marker="$work/started"
touch "$marker"

sw_vers
"$executable" -hasSeenWelcome '<true/>' -automaticUpdateChecks '<false/>' > "$work/output.log" 2>&1 &
pid=$!

finish() {
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  rm -rf "$work"
}
trap finish EXIT

fail() {
  echo "FAILED: $1"
  echo "--- output"
  cat "$work/output.log" || true
  echo "--- crash reports"
  find "$reports" -iname 'Liova*' -newer "$marker" -print -exec head -c 20000 {} \; 2> /dev/null || true
  echo "--- log"
  log show --last 2m --predicate 'subsystem == "app.liova.Liova"' --style compact 2> /dev/null | tail -60 || true
  exit 1
}

answered=no
for _ in $(seq "$seconds"); do
  sleep 1
  kill -0 "$pid" 2> /dev/null || fail "Liova quit within $seconds s of starting"
  if [ "$answered" = no ] && [ -x "$cli" ] && "$cli" ping > /dev/null 2>&1; then
    answered=yes
  fi
done

if [ -x "$cli" ]; then
  [ "$answered" = yes ] || fail "Liova never answered 'liova ping'"
  # Still answering at the end: the main thread isn't stuck.
  "$cli" ping > /dev/null 2>&1 || fail "Liova stopped answering 'liova ping'"
else
  echo "No bundled liova tool (run 'make bundle-cli'); skipping the socket check."
fi

if [ -n "$(find "$reports" -iname 'Liova*' -newer "$marker" 2> /dev/null)" ]; then
  fail "macOS wrote a crash report"
fi
echo "Liova started and stayed up for $seconds s."
