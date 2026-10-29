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
set -eu
REPO=h025/Ruyio
# SHA-256 of the "Ruyio Release Signing" certificate (Scripts/release.sh).
CERT_SHA256=7599d581e90fc58d44f395d3d5f6fc7df11709d33127fd8274dd0b76ee073a35
DEST_DIR=${RUYIO_INSTALL_DIR:-/Applications}
DEST="$DEST_DIR/Ruyio.app"
fail() { echo "Ruyio: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "Ruyio needs a Mac with Apple silicon"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Ruyio: looking up the latest release"
/usr/bin/curl -fsSL -o "$WORK/appcast.xml" "https://github.com/$REPO/releases/latest/download/appcast.xml" \
  || fail "could not reach GitHub"
URL=$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "$WORK/appcast.xml" | head -1)
VERSION=$(sed -n 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/p' "$WORK/appcast.xml" | head -1)
case "$URL" in "https://github.com/$REPO/releases/download/"*) ;; *) fail "unexpected download address: $URL" ;; esac

echo "Ruyio: downloading $VERSION"
/usr/bin/curl -fL --progress-bar -o "$WORK/Ruyio.zip" "$URL" || fail "download failed"
/usr/bin/ditto -x -k "$WORK/Ruyio.zip" "$WORK/unpacked"
APP="$WORK/unpacked/Ruyio.app"
[ -d "$APP" ] || fail "the archive does not contain Ruyio.app"
/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null || fail "the app's code signature is invalid"
/usr/bin/codesign -d -r- "$APP" 2>/dev/null | grep -q 'identifier "app.ruyio.mac"' || fail "this is not Ruyio"
/usr/bin/codesign -d --extract-certificates="$WORK/cert" "$APP" 2>/dev/null
[ "$(shasum -a 256 "$WORK/cert0" | cut -d' ' -f1)" = "$CERT_SHA256" ] || fail "the app is not signed with Ruyio's release certificate"

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
  rm -rf "$OLD"
else
  mv "$NEXT" "$DEST"
fi
echo "Ruyio: installed $VERSION in $DEST_DIR"
/usr/bin/open "$DEST"
