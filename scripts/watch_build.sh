#!/bin/bash
# Rebuilds and re-tests whenever a source file changes, and writes results to files an assistant can read.
# Start once in Terminal:   cd ~/Projects/Damson && scripts/watch_build.sh
# Outputs (in the project folder): build.log, test.log, status.txt
# Stop with Control+C.
cd "$(dirname "$0")/.." || exit 1

fingerprint() {
  find Sources Tests Package.swift -type f \( -name '*.swift' -o -name 'Package.swift' -o -name '*.plist' \) -print0 2>/dev/null \
    | xargs -0 stat -f '%N %m' 2>/dev/null | sort | shasum | cut -d' ' -f1
}

run_once() {
  local started
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "RUNNING since $started" > status.txt
  echo "[$started] swift build..."
  if swift build > build.log 2>&1; then
    echo "[$started] build OK, running tests..."
    if swift test > test.log 2>&1; then
      echo "PASS: build and tests OK ($started)" > status.txt
    else
      echo "FAIL: tests failed ($started). See test.log" > status.txt
    fi
  else
    echo "FAIL: build failed ($started). See build.log" > status.txt
    echo "(tests skipped because the build failed)" > test.log
  fi
  cat status.txt
}

last=""
echo "Watching for changes. Results go to build.log, test.log and status.txt. Control+C to stop."
while true; do
  now="$(fingerprint)"
  if [ "$now" != "$last" ]; then
    last="$now"
    run_once
  fi
  sleep 3
done
