#!/bin/sh
# Packages the already-signed default plugin apps as .ruyioplugin.zip data inside the host bundle
# (plan §15.3: no unpacked executable bundles in Resources). The outer manifest is the same file as
# the signed inner one, so they are byte-identical (plan §7.1).
set -eu
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/DefaultPlugins"
WORK="${DERIVED_FILE_DIR}/DefaultPlugins"
rm -rf "$DEST" "$WORK"
mkdir -p "$DEST" "$WORK"
for NAME in ClipboardHistory FinderEssentials; do
  PKG="$WORK/$NAME.ruyioplugin"
  mkdir -p "$PKG"
  /usr/bin/ditto "${BUILT_PRODUCTS_DIR}/$NAME.app" "$PKG/$NAME.app"
  /bin/cp "${SRCROOT}/Plugins/$NAME/manifest.json" "$PKG/manifest.json"
  # Release builds (Scripts/release.sh) sign the defaults with the release certificate, the official
  # publisher their host requires (A39); other builds keep Xcode's ad-hoc signature.
  if [ -n "${RUYIO_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$RUYIO_SIGN_IDENTITY" --keychain "$RUYIO_SIGN_KEYCHAIN" \
      --preserve-metadata=entitlements,flags,runtime --timestamp=none "$PKG/$NAME.app"
  fi
  /usr/bin/codesign --verify --deep --strict "$PKG/$NAME.app"
  (cd "$WORK" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$NAME.ruyioplugin" "$DEST/$NAME.ruyioplugin.zip")
done
