# Notes for coding agents

- Install into `/Applications` only with `Scripts/install-local.sh` (pass a built `Ruyio.app`, or no
  argument to build Release). Copying an ad-hoc build over `/Applications/Ruyio.app` voids the user's
  Accessibility and pasteboard grants while System Settings still shows them on.
- Builds you launch from DerivedData or `/tmp` register their Finder extension and can take it over from
  the installed copy. Run them only when needed; the install script unregisters them again.
