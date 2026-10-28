#!/bin/sh
# Installs Ruyio into /Applications signed with a local self-signed identity, so privacy grants
# (Accessibility for auto-paste, pasteboard, files) survive rebuilds. An ad-hoc signature pins every
# grant to one cdhash: after a rebuild, or after another copy is dropped over /Applications/Ruyio.app,
# System Settings still shows the switch on but tccd no longer matches the app ("Failed to match existing
# code requirement"). With this identity the designated requirement is the bundle id plus the local
# certificate, which stays the same across builds.
#
# Only the outer app and the helpers that hold their own grants (Contents/Helpers) are re-signed. Other
# nested code and the packaged default plugins keep their build signatures, so plugin identities and data
# directories are unaffected.
#
# Usage: Scripts/install-local.sh [path/to/Ruyio.app]   (no argument: build Release first)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=/Applications/Ruyio.app
KEYCHAIN="$HOME/Library/Keychains/ruyio-local-signing.keychain-db"
IDENTITY="Ruyio Local Signing"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# A dedicated keychain with an empty password, kept out of the search list: signing never prompts,
# and the key only signs this developer's local builds.
if [ ! -f "$KEYCHAIN" ]; then
  WORK=$(mktemp -d)
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  # LibreSSL, not a Homebrew OpenSSL 3: `security import` cannot read OpenSSL 3's default PKCS#12.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
    -out "$WORK/identity.p12" -passout pass:ruyio
  /usr/bin/security create-keychain -p "" "$KEYCHAIN"
  /usr/bin/security set-keychain-settings "$KEYCHAIN"
  /usr/bin/security unlock-keychain -p "" "$KEYCHAIN"
  /usr/bin/security import "$WORK/identity.p12" -k "$KEYCHAIN" -P ruyio -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
  rm -rf "$WORK"
fi
/usr/bin/security unlock-keychain -p "" "$KEYCHAIN"
HASH=$(/usr/bin/security find-identity -p codesigning "$KEYCHAIN" | awk -v name="\"$IDENTITY\"" 'index($0, name) {print $2; exit}')
[ -n "$HASH" ] || { echo "error: no \"$IDENTITY\" identity in $KEYCHAIN" >&2; exit 1; }

if [ $# -gt 0 ]; then
  SRC=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
else
  if command -v xcodegen >/dev/null 2>&1; then (cd "$ROOT" && xcodegen generate --quiet); fi
  /usr/bin/xcodebuild -project "$ROOT/Ruyio.xcodeproj" -scheme Ruyio -configuration Release \
    -derivedDataPath "$ROOT/build/DerivedData" -quiet build
  SRC="$ROOT/build/DerivedData/Build/Products/Release/Ruyio.app"
fi
[ -d "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

STAGE="$ROOT/build/install-staging/Ruyio.app"
rm -rf "$ROOT/build/install-staging"
mkdir -p "$ROOT/build/install-staging"
/usr/bin/ditto "$SRC" "$STAGE"
# Inside out: the capture helper holds Screen Recording, so it needs the stable identity too.
for HELPER in "$STAGE"/Contents/Helpers/*.app; do
  [ -d "$HELPER" ] || continue
  /usr/bin/codesign --force --sign "$HASH" --keychain "$KEYCHAIN" \
    --preserve-metadata=entitlements,flags,runtime --timestamp=none "$HELPER"
done
/usr/bin/codesign --force --sign "$HASH" --keychain "$KEYCHAIN" \
  --preserve-metadata=entitlements,flags,runtime --timestamp=none "$STAGE"
/usr/bin/codesign --verify --deep --strict "$STAGE"

requirement() { /usr/bin/codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
OLD_REQ=$( [ -d "$DEST" ] && requirement "$DEST" || true )
NEW_REQ=$(requirement "$STAGE")

running() { /usr/bin/pgrep -f "^$DEST/Contents/MacOS/Ruyio( |\$)" || true; }
if [ -n "$(running)" ]; then
  /usr/bin/osascript -e 'tell application id "app.ruyio.mac" to quit' >/dev/null 2>&1 || true
  i=0
  while [ -n "$(running)" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  PID=$(running)
  [ -z "$PID" ] || kill $PID
fi

rm -rf "$DEST"
/usr/bin/ditto "$STAGE" "$DEST"
rm -rf "$ROOT/build/install-staging"

# Grants recorded for a different signature can never match again, and toggling the switch does not
# rewrite them; clear them so macOS asks afresh for this identity.
if [ "$OLD_REQ" != "$NEW_REQ" ]; then
  for ID in app.ruyio.mac app.ruyio.mac.CaptureHelper; do
    /usr/bin/tccutil reset All "$ID" >/dev/null 2>&1 || true
  done
  RESET=1
else
  RESET=0
fi

# Only the installed copy may provide the Finder extension; build copies elsewhere would win the election.
/usr/bin/pluginkit -mAv -i app.ruyio.mac.FinderSync 2>/dev/null | awk -F'\t' 'NF > 1 {print $NF}' |
  while IFS= read -r EXT; do
    case "$EXT" in
      "$DEST"/*) ;;
      *) /usr/bin/pluginkit -r "$EXT" 2>/dev/null || true
         "$LSREGISTER" -u "${EXT%/Contents/PlugIns/*}" 2>/dev/null || true ;;
    esac
  done
[ "$SRC" = "$DEST" ] || "$LSREGISTER" -u "$SRC" 2>/dev/null || true
"$LSREGISTER" -f "$DEST"
/usr/bin/pluginkit -a "$DEST/Contents/PlugIns/RuyioFinderSync.appex"
/usr/bin/pkill -f "RuyioFinderSync.appex/Contents/MacOS/RuyioFinderSync" 2>/dev/null || true
/usr/bin/open "$DEST"

echo "Installed $DEST"
echo "  requirement: $NEW_REQ"
if [ "$RESET" = 1 ]; then
  echo "  signing identity changed: privacy grants were reset; grant Accessibility again on the first auto-paste"
fi
