#!/bin/sh
# Lands a branch on main. main only fast-forwards, and only to a commit whose code passed
# Scripts/check.sh, so it is always installable and publishable. If main has moved on, rebase first.
# The fast-forward stops without changing anything if it would touch files edited in the main
# working copy.
#
# Usage: Scripts/land.sh <branch>
set -eu
[ $# -eq 1 ] || { echo "usage: Scripts/land.sh <branch>" >&2; exit 2; }
DIR=$(cd "$(dirname "$0")" && pwd)
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
REV=$(git rev-parse --verify "$1^{commit}")
if ! git merge-base --is-ancestor main "$REV"; then
  echo "error: $1 does not contain the current main; run: git rebase main" >&2
  exit 1
fi
"$DIR/check.sh" "$REV"
[ "$(git -C "$MAIN" branch --show-current)" = main ] || { echo "error: $MAIN is not on main" >&2; exit 1; }
git -C "$MAIN" merge -q --ff-only "$REV"
echo "land: main is now $(git -C "$MAIN" rev-parse --short HEAD)"
