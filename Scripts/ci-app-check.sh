#!/bin/bash
# App checks for CI's macOS 14 job, where the apps were built elsewhere (Scripts/ci-pack-macos14.sh).
#
# Usage: Scripts/ci-app-check.sh launch <Ruyio.app> [seconds]
#          Opens the app through Launch Services (so LSMinimumSystemVersion applies), then fails if after the
#          given time (default 20) it or Clipboard History, the default plugin that runs in the background,
#          is not running, or anything left a crash report.
#        Scripts/ci-app-check.sh gallery <Ruyio-Debug.app> <output folder>
#          Renders the UI gallery (Apps/Ruyio/Debug/UIGallery.swift). A crash, hang or any other error fails;
#          captures the runner could not take only warn, as window activation on hosted runners is not
#          guaranteed.
set -uo pipefail
MODE=${1:?usage: Scripts/ci-app-check.sh launch|gallery <app> ...}
APP=$(cd "${2:?app bundle}" && pwd)
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
START=$(mktemp)

escape() { python3 -c 'import sys; print(sys.stdin.read().replace("%", "%25").replace("\r", "").replace("\n", "%0A")[:4000])'; }

# The host, its helpers and services (all named Ruyio…), and the default plugins.
crash_reports() {
  find "$REPORTS" -newer "$START" \( -name "$EXECUTABLE*" -o -name 'Ruyio*' -o -name 'ClipboardHistory*' -o -name 'FinderEssentials*' \) 2>/dev/null
}

fail_with_crashes() {
  local found=$1
  for report in $found; do
    echo "::error title=Crash report $(basename "$report")::$(head -c 3500 "$report" | escape)"
  done
}

case "$MODE" in
  launch)
    WAIT=${3:-20}
    open -n "$APP" || { echo "::error title=open refused $APP::$(sw_vers | escape)"; exit 1; }
    sleep "$WAIT"
    PID=$(pgrep -f "$BINARY" | head -1)
    PLUGIN=$(pgrep -f 'ClipboardHistory.app/Contents/MacOS/ClipboardHistory' | head -1)
    FOUND=$(crash_reports)
    log show --last "$((WAIT + 10))s" --style compact --predicate "process == \"$EXECUTABLE\" AND messageType >= 16" 2>/dev/null | tail -30
    [ -n "$PID" ] && kill "$PID"
    if [ -z "$PID" ] || [ -z "$PLUGIN" ] || [ -n "$FOUND" ]; then
      [ -z "$PID" ] && echo "::error title=$EXECUTABLE not running after ${WAIT}s::$(sw_vers | escape)"
      [ -n "$PID" ] && [ -z "$PLUGIN" ] && echo "::error title=Clipboard History not running after ${WAIT}s::$(ps -axo pid,command | grep -i -e ruyio -e clipboard -e finder | grep -v grep | escape)"
      fail_with_crashes "$FOUND"
      exit 1
    fi
    echo "$EXECUTABLE and Clipboard History ran for ${WAIT}s on macOS $(sw_vers -productVersion)"
    ;;
  gallery)
    OUT=${3:?output folder}
    mkdir -p "$OUT"
    LIMIT=${RUYIO_GALLERY_LIMIT:-600}
    "$BINARY" --ui-gallery "$OUT" > "$OUT/gallery.log" 2>&1 &
    GALLERY=$!
    ELAPSED=0
    while kill -0 "$GALLERY" 2>/dev/null && [ "$ELAPSED" -lt "$LIMIT" ]; do
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done
    if kill -0 "$GALLERY" 2>/dev/null; then
      kill -KILL "$GALLERY"
      echo "::error title=UI gallery still running after ${LIMIT}s::$(tail -20 "$OUT/gallery.log" | escape)"
      exit 1
    fi
    wait "$GALLERY"
    STATUS=$?
    cat "$OUT/gallery.log"
    FOUND=$(crash_reports)
    if [ "$STATUS" -gt 1 ] || [ -n "$FOUND" ]; then
      echo "::error title=UI gallery exited $STATUS::$(tail -20 "$OUT/gallery.log" | escape)"
      fail_with_crashes "$FOUND"
      exit 1
    fi
    if [ "$STATUS" -eq 1 ]; then
      # Only captures the runner could not take are tolerated; a gallery that failed to start or stopped on
      # an error took none or lists other errors.
      OTHER=$(grep -e 'GALLERY failed:' -e 'GALLERY error' "$OUT/gallery.log" | grep -v -e 'inactive capture skipped' -e 'capture failed')
      if [ -n "$OTHER" ] || ! grep -q 'GALLERY captured' "$OUT/gallery.log"; then
        echo "::error title=UI gallery failed::$( (echo "$OTHER"; tail -5 "$OUT/gallery.log") | escape)"
        exit 1
      fi
      echo "::warning title=UI gallery skipped captures::$(grep 'GALLERY error' "$OUT/gallery.log" | head -20 | escape)"
    fi
    ;;
  *)
    echo "usage: Scripts/ci-app-check.sh launch|gallery <app> ..." >&2
    exit 2
    ;;
esac
