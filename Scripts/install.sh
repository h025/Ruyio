#!/bin/sh
# Installs or updates Ruyio from its latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/h025/Ruyio/main/Scripts/install.sh | sh
#
# Ruyio is not notarized by Apple (the project does without the paid Developer Program), so a copy
# downloaded in a browser needs "Open Anyway" in System Settings the first time. A download by curl carries
# no quarantine flag; instead of Gatekeeper, this script checks the app against the release certificate
# pinned below before it replaces anything. Installed copies then update themselves from Ruyio's settings.
#
# RUYIO_INSTALL_DIR overrides the destination folder (default /Applications).
#
# Everything runs inside main, called on the last line: a download of this script cut off midway
# runs nothing at all.
set -eu

main() {
  REPO=h025/Ruyio
  # SHA-256 of the "Ruyio Release Signing" certificate (Scripts/release.sh).
  CERT_SHA256=7599d581e90fc58d44f395d3d5f6fc7df11709d33127fd8274dd0b76ee073a35
  DEST_DIR=${RUYIO_INSTALL_DIR:-/Applications}
  DEST="$DEST_DIR/Ruyio.app"

  # A Terminal running under Rosetta reports x86_64 from uname; ask the hardware.
  [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || fail "Ruyio needs a Mac with Apple silicon"
  WORK=$(mktemp -d)
  NEXT=
  trap 'rm -rf "$WORK"; [ -z "$NEXT" ] || rm -rf "$NEXT"' EXIT

  echo "Ruyio: looking up the latest release"
  /usr/bin/curl -fsSL -o "$WORK/appcast.xml" "https://github.com/$REPO/releases/latest/download/appcast.xml" \
    || fail "no release found at https://github.com/$REPO/releases (or GitHub is unreachable)"
  URL=$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "$WORK/appcast.xml" | head -1)
  VERSION=$(sed -n 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/p' "$WORK/appcast.xml" | head -1)
  case "$URL" in "https://github.com/$REPO/releases/download/"*) ;; *) fail "unexpected download address: $URL" ;; esac

  if [ -d "$DEST" ]; then
    INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || true)
    # A newer copy has migrated its data; an older version must not open it.
    if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$VERSION" ] &&
       [ "$(printf '%s\n%s\n' "$INSTALLED" "$VERSION" | sort -V | tail -1)" = "$INSTALLED" ]; then
      fail "Ruyio $INSTALLED is newer than the latest release $VERSION; nothing to do"
    fi
  fi

  echo "Ruyio: downloading $VERSION"
  /usr/bin/curl -fL --progress-bar -o "$WORK/Ruyio.zip" "$URL" || fail "download failed"
  /usr/bin/ditto -x -k "$WORK/Ruyio.zip" "$WORK/unpacked"
  APP="$WORK/unpacked/Ruyio.app"
  [ -d "$APP" ] || fail "the archive does not contain Ruyio.app"
  /usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null || fail "the app's code signature is invalid"
  /usr/bin/codesign -d -r- "$APP" 2>/dev/null | grep -q 'identifier "app.ruyio.mac"' || fail "this is not Ruyio"
  /usr/bin/codesign -d --extract-certificates="$WORK/cert" "$APP" 2>/dev/null
  [ "$(shasum -a 256 "$WORK/cert0" | cut -d' ' -f1)" = "$CERT_SHA256" ] || fail "the app is not signed with Ruyio's release certificate"

  [ -d "$DEST_DIR" ] || mkdir -p "$DEST_DIR"
  [ -w "$DEST_DIR" ] || fail "$DEST_DIR is not writable; run with RUYIO_INSTALL_DIR=\"\$HOME/Applications\""
  # Asking Ruyio to quit through Apple Events would make macOS ask whether Terminal may control it.
  if /usr/bin/pgrep -qx Ruyio; then
    fail "Ruyio is running. Quit it from its menu bar icon (or update it from General settings), then run this again"
  fi
  # Copy beside the destination first, then swap, so a failure never leaves Ruyio missing.
  NEXT="$DEST_DIR/.ruyio-install-$$.app"
  /usr/bin/ditto "$APP" "$NEXT"
  if [ -e "$DEST" ]; then
    OLD="$DEST_DIR/.ruyio-previous-$$.app"
    mv "$DEST" "$OLD"
    mv "$NEXT" "$DEST" || { mv "$OLD" "$DEST"; fail "could not replace $DEST"; }
    # The new copy is in place; a leftover old one is only clutter.
    rm -rf "$OLD" || true
  else
    mv "$NEXT" "$DEST"
  fi
  NEXT=
  echo "Ruyio: installed $VERSION in $DEST_DIR"
  /usr/bin/open "$DEST"
}

fail() { echo "Ruyio: $*" >&2; exit 1; }

main "$@"
