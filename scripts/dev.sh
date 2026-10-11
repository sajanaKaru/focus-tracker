#!/bin/bash
# Dev loop: rebuilds the debug binary and relaunches it whenever a source file changes.
# Debug builds skip the license gate. Ctrl+C to stop.
set -uo pipefail
cd "$(dirname "$0")/.."

PID=""
stop_app() { [ -n "$PID" ] && kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null; PID=""; }
trap 'stop_app; exit 0' INT TERM

stamp() { find Sources Package.swift -type f \( -name '*.swift' -o -name Package.swift \) -exec stat -f '%m %N' {} + | sort | md5; }

LAST=""
while true; do
  NOW="$(stamp)"
  if [ "$NOW" != "$LAST" ]; then
    LAST="$NOW"
    echo "==> Building..."
    if swift build; then
      stop_app
      "$(swift build --show-bin-path)/FocusTracker" &
      PID=$!
      echo "==> Running (pid $PID)"
    else
      echo "==> Build failed; keeping previous run"
    fi
  fi
  sleep 1
done
