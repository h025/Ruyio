#!/bin/sh
# Merge gate: runs all package tests and a Release app build for one commit in a dedicated worktree
# (build/check of the main working copy), so uncommitted edits anywhere never affect the result.
# A pass is recorded per code tree, ignoring docs/ and design/ (never published, see publish-code.sh),
# so commits that only touch those reuse the earlier pass. land.sh and publish-code.sh call this first;
# it returns at once for code that already passed.
#
# Usage: Scripts/check.sh [rev]   (default: HEAD)
set -eu
COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
MAIN=$(dirname "$COMMON")
REV=$(git rev-parse --verify "${1:-HEAD}^{commit}")
SHORT=$(git rev-parse --short "$REV")
KEY=$(git ls-tree "$REV" | awk -F'\t' '$2 != "docs" && $2 != "design"' | git hash-object --stdin)
STAMP="$COMMON/ruyio-checks/$KEY"
if [ -f "$STAMP" ]; then
  echo "check: $SHORT already passed"
  exit 0
fi

LOCK="$COMMON/ruyio-check.lock"
until mkdir "$LOCK" 2>/dev/null; do
  echo "check: waiting for another check to finish"
  sleep 10
done
trap 'rmdir "$LOCK"' EXIT INT TERM

CHECK="$MAIN/build/check"
if [ -e "$CHECK/.git" ]; then
  git -C "$CHECK" checkout -q --force --detach "$REV"
else
  git -C "$MAIN" worktree add -q --force --detach "$CHECK" "$REV"
fi
LOG="$MAIN/build/check.log"
: > "$LOG"
run() {
  "$@" >> "$LOG" 2>&1 || {
    tail -40 "$LOG"
    echo "check: $SHORT FAILED at: $* (full log: $LOG)" >&2
    exit 1
  }
}
echo "check: testing $SHORT (log: $LOG)"
cd "$CHECK"
run swift test --package-path Packages/RuyioKit
run xcodegen generate --quiet
run xcodebuild -project Ruyio.xcodeproj -scheme Ruyio -configuration Release \
  -derivedDataPath "$MAIN/build/check-DerivedData" build
mkdir -p "$(dirname "$STAMP")"
echo "$REV $(date '+%Y-%m-%dT%H:%M:%S')" > "$STAMP"
echo "check: $SHORT passed"
