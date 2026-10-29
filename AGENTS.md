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

## Documentation

User and plugin-developer documentation lives in the GitHub wiki (`git@github.com:h025/Ruyio.wiki.git`,
checked out beside this repository as `../Ruyio.wiki`). Whenever a change alters something the wiki
describes (behaviour, settings, UI text, permissions, the manifest or SDK, packaging, signing,
installation, releases or this workflow), update the affected wiki pages in the same task, and push them
once the code is published, so the wiki never describes unpublished behaviour. The plugin market
repository (`h025/ruyio-market`) repeats the plugin-writing essentials in `WRITING_PLUGINS.md`; keep it in
step as well.

## Releasing

Releases are published by GitHub Actions (A43). To release, land a commit on `main` that sets the new
version in both `HostInfo.swift` and `MARKETING_VERSION` (no prerelease suffix; 0.0.x for now), then run
`Scripts/publish-code.sh`. After the tests pass, the `release` job runs `Scripts/release.sh --ci`: it
builds that commit, signs it with the release certificate from the repository secrets (refusing any other
certificate or update key; both are pinned in release.sh), signs the archive with the EdDSA update key,
refuses versions below the latest release, and publishes the GitHub release with the DMG,
the zip, `appcast.xml` and `SHA256SUMS`. Pushes whose version is already released publish nothing.
`Scripts/release.sh --snapshot` builds the current commit the same way on this Mac, without publishing.

The keys live in two keychains on the maintainer's Mac (`ruyio-release-signing`, `ruyio-update-signing` in
`~/Library/Keychains`) and, copied by `Scripts/upload-release-secrets.sh`, in the repository secrets
`RUYIO_RELEASE_P12`, `RUYIO_RELEASE_P12_PASSWORD` and `RUYIO_UPDATE_KEY`. Losing them breaks updates for
installed copies, so never recreate them casually.

## Installing

- Install into `/Applications` only with `Scripts/install-local.sh` (pass a built `Ruyio.app`, or no
  argument to build Release). Copying an ad-hoc build over `/Applications/Ruyio.app` voids the user's
  Accessibility and pasteboard grants while System Settings still shows them on.
- Builds you launch from DerivedData or `/tmp` register their Finder extension and can take it over from
  the installed copy. Run them only when needed; the install script unregisters them again.
