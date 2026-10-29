# Sourced by install-local.sh and release.sh.
#
# A self-signed code signing identity in its own keychain with an empty password, kept out of the search
# list, so codesign never prompts. Unlike an ad-hoc signature, its certificate is the same for every build,
# and so is the designated requirement (bundle id + certificate) that privacy grants, plugin publisher
# checks and Ruyio's own update check rely on. No Apple Developer Program account is involved (A39-A41).

# ensure_signing_identity KEYCHAIN NAME DAYS
# Creates the identity on first use and prints its SHA-1, the value codesign --sign takes.
ensure_signing_identity() {
  _keychain=$1 _name=$2 _days=$3
  if [ ! -f "$_keychain" ]; then
    _work=$(mktemp -d)
    cat > "$_work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $_name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    # LibreSSL, not a Homebrew OpenSSL 3: `security import` cannot read OpenSSL 3's default PKCS#12.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$_days" -config "$_work/cert.cnf" \
      -keyout "$_work/key.pem" -out "$_work/cert.pem" 2>/dev/null
    # Explicit legacy algorithms: `security import` reads these whatever the OpenSSL build defaults to.
    /usr/bin/openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -inkey "$_work/key.pem" -in "$_work/cert.pem" -name "$_name" -out "$_work/identity.p12" -passout pass:ruyio
    /usr/bin/security create-keychain -p "" "$_keychain"
    /usr/bin/security set-keychain-settings "$_keychain"
    /usr/bin/security unlock-keychain -p "" "$_keychain"
    /usr/bin/security import "$_work/identity.p12" -k "$_keychain" -P ruyio -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$_keychain" >/dev/null
    rm -rf "$_work"
    echo "created signing identity \"$_name\" in $_keychain" >&2
  fi
  /usr/bin/security unlock-keychain -p "" "$_keychain"
  _hash=$(/usr/bin/security find-identity -p codesigning "$_keychain" | awk -v name="\"$_name\"" 'index($0, name) {print $2; exit}')
  [ -n "$_hash" ] || { echo "error: no \"$_name\" identity in $_keychain" >&2; return 1; }
  echo "$_hash"
}

# certificate_sha256 KEYCHAIN NAME
# SHA-256 of the certificate in lowercase hex: Ruyio's publisher ID for it is "cert:" followed by this.
certificate_sha256() {
  /usr/bin/security find-certificate -c "$2" -Z "$1" | awk '/^SHA-256 hash:/ {print tolower($3); exit}'
}

# with_signing_keychain KEYCHAIN COMMAND...
# Runs COMMAND with KEYCHAIN on the user's keychain search list. codesign on macOS 26 and earlier finds
# identities only in listed keychains (--keychain alone reports "no identity found"); macOS 27 does not
# need this. Afterwards only KEYCHAIN is taken off again, so changes other scripts made meanwhile stay,
# also when interrupted. Paths are passed as data, never through eval.
with_signing_keychain() {
  _keychain=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  shift
  _listed=
  if ! _ruyio_keychains | grep -qxF "$_keychain"; then
    { _ruyio_keychains; printf '%s\n' "$_keychain"; } | _ruyio_set_keychains
    _listed=1
    trap '_ruyio_unlist "$_keychain"; exit 130' INT TERM
  fi
  if "$@"; then _status=0; else _status=$?; fi
  if [ -n "$_listed" ]; then
    _ruyio_unlist "$_keychain"
    trap - INT TERM
  fi
  return "$_status"
}

# The user's keychain search list, one path per line.
_ruyio_keychains() {
  /usr/bin/security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

# Sets the search list from paths on standard input, one per line.
_ruyio_set_keychains() {
  _list=$(cat)
  if [ -z "$_list" ]; then
    /usr/bin/security list-keychains -d user -s
  else
    printf '%s\n' "$_list" | tr '\n' '\0' | xargs -0 /usr/bin/security list-keychains -d user -s
  fi
}

_ruyio_unlist() {
  _ruyio_keychains | grep -vxF "$1" | _ruyio_set_keychains
}
