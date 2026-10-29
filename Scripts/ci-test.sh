#!/bin/bash
# CI package tests with a watchdog. A hung test can no longer hold the job for hours: after the time limit
# the tests that started but never finished are reported and the run is stopped. GitHub job logs need a
# signed-in account, so failures are also written as check annotations, which anyone can read through the
# public API (GET /repos/{owner}/{repo}/check-runs/{job id}/annotations).
#
# Usage: Scripts/ci-test.sh
#   RUYIO_TEST_LIMIT  overall seconds (default 1500)
#   RUYIO_TEST_STALL  seconds without any test starting or ending once tests run (default 120)
#   RUYIO_TEST_SERIAL non-empty to run tests one at a time
#   RUYIO_TEST_RUNTIME run the bundles an earlier run left in Packages/RuyioKit/.build/debug with the test
#                      runtime packed beside them (Scripts/ci-pack-macos14.sh) instead of building and testing
set -uo pipefail
LIMIT=${RUYIO_TEST_LIMIT:-1500}
STALL=${RUYIO_TEST_STALL:-120}
PARALLEL=$([ -n "${RUYIO_TEST_SERIAL:-}" ] && echo --no-parallel || echo --parallel)
LOG=$(mktemp)
MARK="$LOG.timedout"
# swift test holds a test process's console output until that process ends, so a hung test prints
# nothing; Swift Testing's event stream is written as each test starts and ends.
EVENTS="$LOG.events"
# Event files of this run are newer than this marker. The log itself keeps changing, so comparing with it
# hid event files once console output had moved on, and a stall then showed up only at the time limit.
START="$LOG.started"
: > "$START"

run_tests() {
  if [ -z "${RUYIO_TEST_RUNTIME:-}" ]; then
    exec swift test --package-path Packages/RuyioKit "$PARALLEL" --experimental-event-stream-output "$EVENTS" --experimental-event-stream-version 0
  fi
  # An older macOS whose Xcode cannot build Ruyio: the runner, Swift Testing and XCTest come from the Xcode
  # that built the bundles. Each bundle streams to its own event file, named like those of swift test.
  local status=0 bundle name binary
  export DYLD_FRAMEWORK_PATH="$RUYIO_TEST_RUNTIME/Frameworks:$RUYIO_TEST_RUNTIME/PrivateFrameworks"
  export DYLD_LIBRARY_PATH="$RUYIO_TEST_RUNTIME/lib" NO_COLOR=1
  for bundle in Packages/RuyioKit/.build/debug/*.xctest; do
    name=$(basename "$bundle" .xctest)
    binary="$bundle/Contents/MacOS/$name"
    "$RUYIO_TEST_RUNTIME/swiftpm-testing-helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing "$PARALLEL" \
      --experimental-event-stream-output "${TMPDIR:-/tmp}/event-stream-$name.jsonl" --experimental-event-stream-version 0 || status=1
    cat "${TMPDIR:-/tmp}/event-stream-$name.jsonl" >> "$EVENTS" 2>/dev/null
  done
  [ -n "${bundle:-}" ] && [ -e "$bundle" ] || { echo "error: no test bundles in Packages/RuyioKit/.build/debug"; status=1; }
  exit "$status"
}

# Own process group, so the watchdog can stop swift test together with the test runner it starts.
set -m
run_tests > >(tee "$LOG") 2>&1 &
TESTS=$!
set +m
# Detached from the output, and its sleep stopped with it, so an early finish never waits on the watchdog.
(
  # Acts at the overall limit, or as soon as the live event files (one per test process) have been
  # quiet for STALL seconds: a hang is reported in minutes instead of at the limit.
  BEGAN=$(date +%s)
  REASON=""
  while [ -z "$REASON" ]; do
    sleep 10 &
    wait $!
    kill -0 "$TESTS" 2>/dev/null || exit 0
    NOW=$(date +%s)
    [ $((NOW - BEGAN)) -ge "$LIMIT" ] && REASON="time limit ${LIMIT}s"
    LAST=$(find "${TMPDIR:-/tmp}" -name "event-stream-*.jsonl" -newer "$START" \
      -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1)
    [ -n "$LAST" ] && [ $((NOW - LAST)) -ge "$STALL" ] && REASON="no test started or ended for ${STALL}s"
  done
  if kill -0 "$TESTS" 2>/dev/null; then
    echo "$REASON" > "$MARK"
    find "${TMPDIR:-/tmp}" -name "event-stream-*.jsonl" -newer "$START" -exec cat {} + >> "$EVENTS.live" 2>/dev/null
    # Paused first, so it cannot start another test process between the listing and the kill.
    kill -STOP "$TESTS" 2>/dev/null
    # What every stuck process is waiting on. swift test starts the test runner (and tools such as xcrun)
    # in other process groups, so walk the parent chain rather than the group. Children first: they are
    # what swift test waits for. sudo is passwordless on hosted runners and needed for Apple-signed tools.
    {
      ALL=$(ps -A -o pid=,ppid=)
      FOUND=""
      QUEUE="$TESTS"
      while [ -n "$QUEUE" ]; do
        set -- $QUEUE
        CURRENT=$1
        shift
        QUEUE="$*"
        for CHILD in $(echo "$ALL" | awk -v p="$CURRENT" '$2 == p {print $1}'); do
          FOUND="$FOUND $CHILD"
          QUEUE="$QUEUE $CHILD"
        done
      done
      ps -o pid,ppid,pgid,etime,stat,command -p "$(echo $TESTS $FOUND | tr ' ' ',')"
      for pid in $FOUND $TESTS; do
        case "$(ps -o comm= -p "$pid")" in *tee|*bash|*sleep) continue ;; esac
        # Each test process streams events to its own file; swift test merges them only at the end.
        STREAM=$(ps -o command= -p "$pid" | grep -o -- '--experimental-event-stream-output [^ ]*' | head -1 | cut -d' ' -f2)
        [ -n "$STREAM" ] && [ -f "$STREAM" ] && cat "$STREAM" >> "$EVENTS.live"
        echo "== $(ps -o command= -p "$pid" | cut -c1-160) ($pid)"
        { sudo -n sample "$pid" 2 2>/dev/null || sample "$pid" 2 2>/dev/null; } | sed -n '/Call graph:/,/Total number in stack/p' > "$LOG.sample"
        # Each thread's deepest frames: what it is actually blocked in.
        python3 - "$LOG.sample" <<'LEAF'
import re, sys
threads, current = [], None
for line in open(sys.argv[1], errors="replace"):
    if re.match(r"^    \d+ Thread_", line):
        current = [line.strip()]
        threads.append(current)
    elif current is not None and line.strip():
        current.append(line.rstrip("\n"))
for thread in threads:
    head, frames = thread[0], thread[1:]
    if not frames:
        continue
    depth = lambda l: len(l) - len(l.lstrip(" +!:|"))
    deepest = max(range(len(frames)), key=lambda i: depth(frames[i]))
    path = [frames[deepest]]
    for line in reversed(frames[:deepest]):
        if depth(line) < depth(path[-1]):
            path.append(line)
        if len(path) == 7:
            break
    clean = lambda l: re.sub(r"\s*\[0x[0-9a-f]+\]|load address 0x[0-9a-f]+ \+ |\+ \d+ ", "", l.strip(" +!:|")).strip()
    print("  " + re.sub(r"\s+", " ", head)[:110])
    for line in reversed(path):
        print("    " + clean(line)[:150])
LEAF
      done
    } > "$LOG.stacks" 2>&1
    # Children in other groups too, or one left alive keeps the output pipe, and the step, open.
    kill -TERM -- "-$TESTS" $FOUND 2>/dev/null
    kill -CONT "$TESTS" 2>/dev/null
    sleep 15
    kill -KILL -- "-$TESTS" $FOUND 2>/dev/null
  fi
) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$TESTS"
STATUS=$?
pkill -P "$WATCHDOG" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null
sleep 1

python3 - "$LOG" "$([ -e "$MARK" ] && echo timeout || echo "$STATUS")" "${GITHUB_WORKSPACE:-$PWD}" "$EVENTS" "$MARK" <<'PY'
import json, os, re, sys
log, outcome, workspace, events, mark = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/") + "/", sys.argv[4], sys.argv[5]
reason = open(mark).read().strip() if os.path.exists(mark) else ""
lines = open(log, errors="replace").read().splitlines()

def escape(text):
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")

started, finished = [], set()
for line in lines:
    if m := re.search(r"Test (.+?) started\.$", line):
        started.append(m.group(1))
    elif m := re.search(r"[✔✘➜] Test (.+?) (passed|failed|skipped)", line):
        finished.add(m.group(1))

# Test functions (IDs with a "/") that started and never ended, from the event stream.
streamed = []
ended = set()
for path in (events, events + ".live"):
    if not os.path.exists(path):
        continue
    for line in open(path, errors="replace"):
        try:
            payload = json.loads(line).get("payload", {})
        except ValueError:
            continue
        if payload.get("kind") == "testStarted" and "/" in payload.get("testID", ""):
            streamed.append(payload["testID"])
        elif payload.get("kind") == "testEnded":
            ended.add(payload.get("testID"))
streamed = [test for test in dict.fromkeys(streamed) if test not in ended]

if outcome == "timeout":
    # Console fallback: the run itself and parameterized cases have no matching end line.
    hung = streamed or [name for name in dict.fromkeys(started)
                        if name not in finished and name != "run" and not name.startswith("case ")]
    # GitHub keeps ten annotations per step: one for all unfinished tests, a short tail, then stacks.
    print(f"::error title=Stopped: {reason}. Tests that did not finish ({len(hung)})::{escape(chr(10).join(hung)[:4000])}")
    print(f"::error title=Last test output before the time limit::{escape(chr(10).join(lines[-12:]))}")
    if os.path.exists(log + ".stacks"):
        stacks = open(log + ".stacks", errors="replace").read()
        # Annotations are short; spread the samples over a few of them.
        for part in range(0, min(len(stacks), 28000), 4000):
            print(f"::error title=Stuck processes and stacks ({part // 4000 + 1})::{escape(stacks[part:part + 4000])}")
elif outcome != "0":
    issues = [l for l in lines if " recorded an issue at " in l or re.search(r"error: ", l)]
    for line in issues[:8]:
        if m := re.search(r"Test (.+?) recorded an issue at (.+?):(\d+):\d+: (.*)$", line):
            path = m.group(2).replace(workspace, "")
            print(f"::error file={path},line={m.group(3)},title={escape(m.group(1))}::{escape(m.group(4))}")
        else:
            print(f"::error title=swift test::{escape(line.strip()[:500])}")
    if not issues:
        print(f"::error title=swift test exited {outcome}::{escape(chr(10).join(lines[-40:]))}")
PY

[ -e "$MARK" ] && exit 1
exit "$STATUS"
