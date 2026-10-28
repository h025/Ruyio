#!/bin/sh
# Publishes the committed code to GitHub without product and design material: `docs/` and `design/`
# are removed from every commit, so they never reach the remote's history either. The rewrite is
# deterministic (same commits in, same hashes out), so each run fast-forwards the remote.
# Only main is published, and only once its code passed Scripts/check.sh; uncommitted work never is.
# GitHub CI then runs once per publish, however many commits it carries.
#
# Usage: Scripts/publish-code.sh [--dry-run]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = "--dry-run" ] || "$ROOT/Scripts/check.sh" main
REMOTE=${RUYIO_PUBLIC_REMOTE:-git@github.com:h025/Ruyio.git}
EXCLUDED="docs design"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q --no-local --single-branch --branch main "$ROOT" "$WORK/repo"
cd "$WORK/repo"
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --prune-empty \
  --index-filter "git rm -r -q --cached --ignore-unmatch $EXCLUDED" HEAD >/dev/null

if git log --name-only --format= | grep -q -E "^(docs|design)/"; then
  echo "error: excluded paths are still in the rewritten history" >&2
  exit 1
fi
echo "$(git rev-list --count HEAD) commits, head $(git rev-parse --short HEAD)"

if [ "${1:-}" = "--dry-run" ]; then
  git ls-tree -r --name-only HEAD | cut -d/ -f1 | sort | uniq -c
  exit 0
fi
git push "$REMOTE" HEAD:refs/heads/main
