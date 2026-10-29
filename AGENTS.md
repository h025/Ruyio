# Notes for coding agents

## Workflow

Several agents work on this repository at the same time, so nobody edits the main working copy
(`~/Developer/Ruyio`): it stays on `main`, which only moves forward through `Scripts/land.sh`.

1. Start every task on its own branch in its own worktree, from the main working copy:
   `git worktree add ../Ruyio-wt/<agent>-<topic> -b <agent>/<topic> main`
2. Commit as often as you like. Branch commits run nothing remotely; run the tests you need locally.
3. To finish, rebase on `main` (`git rebase main`) and run `Scripts/land.sh <agent>/<topic>`. It runs
   `Scripts/check.sh` (all package tests plus a Release app build of that exact commit, in a clean
   worktree) and fast-forwards `main` only if it passes. Then remove your worktree and branch.
4. Publish to GitHub with `Scripts/publish-code.sh` when landed work should go public. It publishes only
   `main`, removes `docs/` and `design/` from the whole history, and GitHub CI runs once per publish.
   Never add a GitHub remote or `git push` directly; that would publish the private docs.

## Releasing

`Scripts/release.sh` builds `main` at the version in `HostInfo.swift` (`MARKETING_VERSION` must match; no
prerelease suffix), signs it with the release certificate, signs the archive with the EdDSA update key,
writes `appcast.xml`, publishes the code and creates the GitHub release when the GitHub CLI is signed in.
`--snapshot` builds the current commit the same way without publishing. Both keys live in their own
keychains (`ruyio-release-signing`, `ruyio-update-signing` in `~/Library/Keychains`); losing either breaks
updates for installed copies, so never recreate them casually. Versions are 0.0.x for now.

## Installing

- Install into `/Applications` only with `Scripts/install-local.sh` (pass a built `Ruyio.app`, or no
  argument to build Release). Copying an ad-hoc build over `/Applications/Ruyio.app` voids the user's
  Accessibility and pasteboard grants while System Settings still shows them on.
- Builds you launch from DerivedData or `/tmp` register their Finder extension and can take it over from
  the installed copy. Run them only when needed; the install script unregisters them again.
