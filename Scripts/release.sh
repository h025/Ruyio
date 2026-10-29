#!/bin/sh
# Builds a Ruyio release without an Apple Developer ID (decisions A40, A41, A43).
#
# The app, its helpers (which hold their own privacy grants) and the default plugins are signed with the
# project's self-signed release certificate. Its designated requirement (bundle id + certificate) is what
# keeps users' privacy grants across updates and what Ruyio checks before installing one of its own
# updates. The Finder extension and the media decoder keep their build signatures, sealed by the app's,
# as in Scripts/install-local.sh. The archive is signed with the EdDSA update key by Sparkle's sign_update,
# and appcast.xml (Sparkle's format) points Ruyio at it. Users see "unidentified developer" once, when
# they first open a copy downloaded in a browser.
#
# Usage:
#   Scripts/release.sh --ci        GitHub Actions, after the tests pass on main: when HostInfo.version is a
#                                  release version without a published release, build, sign and publish
#                                  it. Keys come from the repository secrets (Scripts/upload-release-secrets.sh).
#   Scripts/release.sh --snapshot  the same build for the current commit on this Mac, kept local
#
# Output: build/release/<label>/  Ruyio-<version>.dmg (people), Ruyio-<version>.zip (updates),
#         appcast.xml, SHA256SUMS
#
# Keys live on the maintainer's Mac and, copied, in the repository secrets. Back the files up: without the
# certificate, updates can no longer prove they come from the same publisher; without the update key,
# installed copies reject new archives.
#   ~/Library/Keychains/ruyio-release-signing.keychain-db  code signing certificate "Ruyio Release Signing"
#   ~/Library/Keychains/ruyio-update-signing.keychain-db   EdDSA (Ed25519) update key
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/Scripts/lib/signing-identity.sh"
REPO=h025/Ruyio
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
SIGNING_NAME="Ruyio Release Signing"
# The certificate every release must carry (also pinned in install.sh): another one would cut installed
# copies off from their updates and privacy grants.
RELEASE_CERT_SHA256=7599d581e90fc58d44f395d3d5f6fc7df11709d33127fd8274dd0b76ee073a35
UPDATE_SERVICE="Ruyio Update Signing"
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

case "${1:-}" in
  --ci) MODE=ci ;;
  --snapshot) MODE=snapshot ;;
  *) echo "usage: Scripts/release.sh --ci | --snapshot" >&2; exit 2 ;;
esac
fail() { echo "release: $*" >&2; exit 1; }

if [ "$MODE" = ci ]; then
  # The workflow's checkout is the commit that passed the tests.
  SRC=$ROOT
  BUILD="$ROOT/build"
else
  # A clean checkout of exactly the current commit; uncommitted edits never reach a build.
  COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
  MAIN=$(dirname "$COMMON")
  BUILD="$MAIN/build"
  SRC="$BUILD/release-src"
  REV=$(git -C "$ROOT" rev-parse --verify HEAD)
  if [ -e "$SRC/.git" ]; then
    git -C "$SRC" checkout -q --force --detach "$REV"
  else
    git -C "$MAIN" worktree add -q --force --detach "$SRC" "$REV"
  fi
fi

# HostInfo.version and MARKETING_VERSION must agree; a release is never a prerelease build.
HOST_LINE=$(grep 'static let version = SemanticVersion' "$SRC/Packages/RuyioKit/Sources/RuyioCore/HostInfo.swift")
VERSION=$(echo "$HOST_LINE" | sed -E 's/.*major: ([0-9]+), minor: ([0-9]+), patch: ([0-9]+).*/\1.\2.\3/')
MARKETING=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$SRC/project.yml")
[ "$VERSION" = "$MARKETING" ] || fail "HostInfo.version ($VERSION) and MARKETING_VERSION ($MARKETING) differ"
if [ "$MODE" = ci ]; then
  if echo "$HOST_LINE" | grep -q prerelease; then echo "release: $VERSION is a prerelease; nothing to publish"; exit 0; fi
  DRAFT=$(gh release view "v$VERSION" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null || echo none)
  case "$DRAFT" in
    false) echo "release: v$VERSION is already published"; exit 0 ;;
    # A run cancelled or failed after creating its draft; start that release over.
    true) gh release delete "v$VERSION" --repo "$REPO" --yes ;;
  esac
  LABEL=$VERSION
else
  LABEL="$VERSION-snapshot.$(git -C "$SRC" rev-parse --short HEAD)"
fi
OUT="$BUILD/release/$LABEL"

# Signing identity and update key: from the secrets on CI, from this Mac's keychains otherwise.
if [ "$MODE" = ci ]; then
  [ -n "${RUYIO_RELEASE_P12:-}" ] && [ -n "${RUYIO_RELEASE_P12_PASSWORD:-}" ] && [ -n "${RUYIO_UPDATE_KEY:-}" ] ||
    fail "release secrets missing; run Scripts/upload-release-secrets.sh on the maintainer's Mac"
  SIGNING_KEYCHAIN="${RUNNER_TEMP:-$BUILD}/ruyio-release-signing.keychain-db"
  WORK=$(mktemp -d)
  trap '/usr/bin/security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null; rm -rf "$WORK"' EXIT
  printf '%s' "$RUYIO_RELEASE_P12" | /usr/bin/base64 -D > "$WORK/release.p12"
  /usr/bin/security create-keychain -p "" "$SIGNING_KEYCHAIN"
  /usr/bin/security set-keychain-settings "$SIGNING_KEYCHAIN"
  /usr/bin/security unlock-keychain -p "" "$SIGNING_KEYCHAIN"
  /usr/bin/security import "$WORK/release.p12" -k "$SIGNING_KEYCHAIN" -P "$RUYIO_RELEASE_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$SIGNING_KEYCHAIN" >/dev/null
  rm -f "$WORK/release.p12"
  HASH=$(/usr/bin/security find-identity -p codesigning "$SIGNING_KEYCHAIN" | awk -v name="\"$SIGNING_NAME\"" 'index($0, name) {print $2; exit}')
  [ -n "$HASH" ] || fail "no \"$SIGNING_NAME\" identity in RUYIO_RELEASE_P12"
  update_key() { printf '%s\n' "$RUYIO_UPDATE_KEY"; }
else
  SIGNING_KEYCHAIN="$HOME/Library/Keychains/ruyio-release-signing.keychain-db"
  UPDATE_KEYCHAIN="$HOME/Library/Keychains/ruyio-update-signing.keychain-db"
  HASH=$(ensure_signing_identity "$SIGNING_KEYCHAIN" "$SIGNING_NAME" 7300)
  if [ ! -f "$UPDATE_KEYCHAIN" ]; then
    /usr/bin/security create-keychain -p "" "$UPDATE_KEYCHAIN"
    /usr/bin/security set-keychain-settings "$UPDATE_KEYCHAIN"
    /usr/bin/security unlock-keychain -p "" "$UPDATE_KEYCHAIN"
    # Any 32 random bytes are an Ed25519 private key (seed), the format sign_update --ed-key-file reads.
    /usr/bin/security add-generic-password -a ed25519 -s "$UPDATE_SERVICE" -T /usr/bin/security \
      -w "$(head -c 32 /dev/urandom | base64)" "$UPDATE_KEYCHAIN"
    echo "created the EdDSA update key in $UPDATE_KEYCHAIN" >&2
  fi
  /usr/bin/security unlock-keychain -p "" "$UPDATE_KEYCHAIN"
  update_key() { /usr/bin/security find-generic-password -a ed25519 -s "$UPDATE_SERVICE" -w "$UPDATE_KEYCHAIN"; }
fi
CERT_SHA256=$(certificate_sha256 "$SIGNING_KEYCHAIN" "$SIGNING_NAME")
if [ "$CERT_SHA256" != "$RELEASE_CERT_SHA256" ]; then
  [ "$MODE" = ci ] && fail "the release certificate is $CERT_SHA256, not the pinned $RELEASE_CERT_SHA256"
  echo "release: warning: signing with certificate $CERT_SHA256, not the release certificate; this build cannot update installed copies" >&2
fi
PUBLIC_KEY=$(update_key | /usr/bin/xcrun swift -e '
import CryptoKit
import Foundation
let seed = Data(base64Encoded: readLine()!)!
print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())')

# Sparkle's signing tool, from its pinned release archive.
SPARKLE="$BUILD/sparkle-$SPARKLE_VERSION"
if [ ! -x "$SPARKLE/bin/sign_update" ]; then
  mkdir -p "$SPARKLE"
  curl -fsSL -o "$SPARKLE.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  [ "$(shasum -a 256 "$SPARKLE.tar.xz" | cut -d' ' -f1)" = "$SPARKLE_SHA256" ] || { rm -f "$SPARKLE.tar.xz"; fail "Sparkle archive checksum mismatch"; }
  tar -xJf "$SPARKLE.tar.xz" -C "$SPARKLE" ./bin/sign_update
  rm -f "$SPARKLE.tar.xz"
fi

echo "release: building $LABEL from $(git -C "$SRC" rev-parse --short HEAD), publisher cert:$CERT_SHA256"
cd "$SRC"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate --quiet
DERIVED="$BUILD/release-DerivedData"
# The build signs the default plugins with the release certificate (package-default-plugins.sh).
with_signing_keychain "$SIGNING_KEYCHAIN" xcodebuild -project Ruyio.xcodeproj -scheme Ruyio -configuration Release -derivedDataPath "$DERIVED" -quiet \
  CURRENT_PROJECT_VERSION="$VERSION" RUYIO_OFFICIAL_PUBLISHER="cert:$CERT_SHA256" \
  RUYIO_UPDATE_FEED="$FEED" RUYIO_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
  RUYIO_SIGN_IDENTITY="$HASH" RUYIO_SIGN_KEYCHAIN="$SIGNING_KEYCHAIN" build

rm -rf "$OUT"
mkdir -p "$OUT"
APP="$OUT/Ruyio.app"
/usr/bin/ditto "$DERIVED/Build/Products/Release/Ruyio.app" "$APP"
# Inside out: the helpers, then the app.
SHA1=$(echo "$HASH" | tr 'A-F' 'a-f')
for CODE in "$APP"/Contents/Helpers/*.app "$APP"; do
  [ -d "$CODE" ] || continue
  with_signing_keychain "$SIGNING_KEYCHAIN" /usr/bin/codesign --force --sign "$HASH" --keychain "$SIGNING_KEYCHAIN" \
    --preserve-metadata=entitlements,flags,runtime --timestamp=none "$CODE"
  /usr/bin/codesign -d -r- "$CODE" 2>&1 | grep -q "certificate leaf = H\"$SHA1\"" || fail "$CODE is not signed with the release certificate"
done
/usr/bin/codesign --verify --deep --strict "$APP"
for CODE in "$APP" "$APP"/Contents/Helpers/*.app "$APP"/Contents/PlugIns/*.appex "$APP"/Contents/XPCServices/*.xpc; do
  [ -d "$CODE" ] || continue
  if /usr/bin/codesign -d --entitlements - "$CODE" 2>/dev/null | grep -q get-task-allow; then fail "$CODE allows debugging"; fi
done
for PACKAGE in "$APP"/Contents/Resources/DefaultPlugins/*.ruyioplugin.zip; do
  CHECK=$(mktemp -d)
  /usr/bin/ditto -x -k "$PACKAGE" "$CHECK"
  for PLUGIN in "$CHECK"/*.ruyioplugin/*.app; do
    /usr/bin/codesign -d -r- "$PLUGIN" 2>&1 | grep -q "certificate leaf = H\"$SHA1\"" || fail "$(basename "$PACKAGE") is not signed with the release certificate"
  done
  rm -rf "$CHECK"
done

ZIP="Ruyio-$LABEL.zip"
(cd "$OUT" && /usr/bin/ditto -c -k --norsrc --noextattr --keepParent Ruyio.app "$ZIP")
# A disk image to drag Ruyio into Applications, the usual way to install by hand.
DMG="Ruyio-$LABEL.dmg"
mkdir "$OUT/dmg"
/usr/bin/ditto "$APP" "$OUT/dmg/Ruyio.app"
ln -s /Applications "$OUT/dmg/Applications"
/usr/bin/hdiutil create -quiet -volname "Ruyio $LABEL" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$OUT/$DMG"
rm -rf "$OUT/dmg" "$APP"
SIGNATURE=$(update_key | "$SPARKLE/bin/sign_update" --ed-key-file - -p "$OUT/$ZIP")
LENGTH=$(stat -f %z "$OUT/$ZIP")
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ruyio</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Ruyio $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
(cd "$OUT" && shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS)
echo "release: $OUT"
ls -l "$OUT"
[ "$MODE" = ci ] || exit 0

NOTES="Early preview of Ruyio: still incomplete. Apple silicon, macOS 15 or later.

**Install or update**

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$REPO/main/Scripts/install.sh | sh
\`\`\`

Or download \`${DMG}\`, open it and drag Ruyio to Applications. Ruyio is not notarized by Apple: the first time, open System Settings › Privacy & Security and click **Open Anyway**. Installed copies update themselves from General settings.

Release certificate SHA-256: \`${CERT_SHA256}\`

---

早期预览版，功能尚未完善。需要 Apple 芯片 Mac、macOS 15 或更新版本。

**安装或更新**：在终端运行上面的命令；或下载 \`${DMG}\`，打开后把 Ruyio 拖到“应用程序”。Ruyio 未经 Apple 公证，第一次打开时请到“系统设置 › 隐私与安全性”点“**仍要打开**”。之后可在“通用设置”中自动更新。

使用说明见 [Wiki](https://github.com/$REPO/wiki)。"
# Draft first: the release, its tag and the appcast become visible only once every file is uploaded.
gh release create "v$VERSION" --repo "$REPO" --target "${GITHUB_SHA:-$(git rev-parse HEAD)}" --draft \
  --title "Ruyio $VERSION" --notes "$NOTES" "$OUT/$DMG" "$OUT/$ZIP" "$OUT/appcast.xml" "$OUT/SHA256SUMS"
gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest
echo "release: published https://github.com/$REPO/releases/tag/v$VERSION"
