#!/bin/bash
# Tests the Mac app for real: builds a test copy against a scratch copy of this repo, then lets it
# click through its own window (a CSV export, the Help link, PORT's file import, server start and
# stop) and prints its report. A window appears for about half a minute; your own data isn't touched.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
copy="$work/amber-terminal"
rsync -a --exclude .git --exclude data "$here/../" "$copy/"
QT_SELFTEST=1 QT_APP_FOLDER="$copy" "$here/build.sh" "$work" >/dev/null
mkdir -p "$work/out" "$work/downloads"

# A broker's positions export for the import step.
csv="$work/selftest-positions.csv"
printf 'Symbol,Quantity,Average Cost\nAAPL,10,150\nMSFT,5,300\n' >"$csv"

QT_SELFTEST_OUT="$work/out" QT_SELFTEST_DOWNLOADS="$work/downloads" QT_SELFTEST_FILE="$csv" \
  "$work/Amber Terminal Selftest.app/Contents/MacOS/Amber Terminal Selftest" &
pid=$!
for _ in $(seq 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "The test app didn't finish within 2 minutes." >&2
fi
# Prints "was not running" when the app's Stop Server and Quit already stopped it.
node "$copy/scripts/stop.js"
cat "$work/out/report.json" 2>/dev/null || echo "No report was written." >&2
echo "Snapshots, downloads and the scratch copy: $work"
