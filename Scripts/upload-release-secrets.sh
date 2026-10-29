#!/bin/sh
# Copies the release signing certificate and the EdDSA update key from this Mac's keychains into the
# repository's GitHub Actions secrets, so the release job in .github/workflows/ci.yml can sign and publish
# releases with the same keys as before (A43). Run it once, and again only if the keys ever change.
# The values go straight from the keychains to the GitHub CLI; nothing is printed or left on disk.
#
# Needs the GitHub CLI, signed in with access to the repository:  brew install gh && gh auth login
set -eu
REPO=h025/Ruyio
SIGNING_KEYCHAIN="$HOME/Library/Keychains/ruyio-release-signing.keychain-db"
UPDATE_KEYCHAIN="$HOME/Library/Keychains/ruyio-update-signing.keychain-db"
fail() { echo "upload-release-secrets: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "install the GitHub CLI first: brew install gh"
gh auth status >/dev/null 2>&1 || fail "sign in first: gh auth login"
[ -f "$SIGNING_KEYCHAIN" ] && [ -f "$UPDATE_KEYCHAIN" ] || fail "release keychains not found in ~/Library/Keychains"

# Upload only the keys every installed copy trusts; Scripts/release.sh pins the same values.
. "$(cd "$(dirname "$0")" && pwd)/lib/signing-identity.sh"
PINNED_CERT=$(sed -n 's/^RELEASE_CERT_SHA256=//p' "$(dirname "$0")/release.sh")
PINNED_KEY=$(sed -n 's/^RELEASE_UPDATE_PUBLIC_KEY=//p' "$(dirname "$0")/release.sh")
/usr/bin/security unlock-keychain -p "" "$SIGNING_KEYCHAIN"
[ "$(certificate_sha256 "$SIGNING_KEYCHAIN" "Ruyio Release Signing")" = "$PINNED_CERT" ] ||
  fail "the certificate in $SIGNING_KEYCHAIN is not the pinned release certificate"
/usr/bin/security unlock-keychain -p "" "$UPDATE_KEYCHAIN"
PUBLIC=$(/usr/bin/security find-generic-password -a ed25519 -s "Ruyio Update Signing" -w "$UPDATE_KEYCHAIN" | /usr/bin/xcrun swift -e '
import CryptoKit
import Foundation
print(try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: readLine()!)!).publicKey.rawRepresentation.base64EncodedString())')
[ "$PUBLIC" = "$PINNED_KEY" ] || fail "the update key in $UPDATE_KEYCHAIN is not the pinned release key"

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
# The PKCS#12 password only protects the file in transit to the secret; it is stored beside it.
PASSWORD=$(head -c 24 /dev/urandom | base64)
/usr/bin/security unlock-keychain -p "" "$SIGNING_KEYCHAIN"
echo "macOS now asks whether \"security\" may export the key \"Ruyio Release Signing\": leave the password empty and click Allow."
echo "系统会询问是否允许 security 导出钥匙串中的密钥：密码留空，点“允许”。"
/usr/bin/security export -k "$SIGNING_KEYCHAIN" -t identities -f pkcs12 -P "$PASSWORD" -o "$WORK/release.p12" >/dev/null
/usr/bin/base64 -i "$WORK/release.p12" | gh secret set RUYIO_RELEASE_P12 --repo "$REPO"
rm -f "$WORK/release.p12"
printf '%s' "$PASSWORD" | gh secret set RUYIO_RELEASE_P12_PASSWORD --repo "$REPO"
/usr/bin/security unlock-keychain -p "" "$UPDATE_KEYCHAIN"
/usr/bin/security find-generic-password -a ed25519 -s "Ruyio Update Signing" -w "$UPDATE_KEYCHAIN" | tr -d '\n' |
  gh secret set RUYIO_UPDATE_KEY --repo "$REPO"
echo "upload-release-secrets: RUYIO_RELEASE_P12, RUYIO_RELEASE_P12_PASSWORD and RUYIO_UPDATE_KEY are set on $REPO"
