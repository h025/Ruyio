#!/bin/bash
# Packs what CI's macOS 14 job runs: the package test bundles left by Scripts/ci-test.sh, the test runtime of
# the Xcode that built them (swiftpm-testing-helper, Swift Testing, XCTest), and the Release and Debug apps.
# Ruyio needs the macOS 26 SDK, whose Xcode does not run on macOS 14, so everything is built on the newer
# runner and only run on the older one (A46).
#
# Usage: Scripts/ci-pack-macos14.sh <output.tar>
# Run from the repository root after `Scripts/ci-test.sh` and Release and Debug builds into build/DerivedData.
set -euo pipefail
OUT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

DEV=$(xcode-select -p)
PLATFORM="$DEV/Platforms/MacOSX.platform/Developer"
mkdir -p "$STAGE/runtime"
cp "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper" "$STAGE/runtime/"
ditto "$PLATFORM/Library/Frameworks" "$STAGE/runtime/Frameworks"
ditto "$PLATFORM/Library/PrivateFrameworks" "$STAGE/runtime/PrivateFrameworks"
ditto "$PLATFORM/usr/lib" "$STAGE/runtime/lib"

PRODUCTS=build/DerivedData/Build/Products
ditto "$PRODUCTS/Release/Ruyio.app" "$STAGE/Ruyio.app"
ditto "$PRODUCTS/Debug/Ruyio.app" "$STAGE/Ruyio-Debug.app"

# The bundles find the test plugin, resources and fixtures through absolute paths, so they go back to the same
# place in the other checkout. .build/debug links to the build system's own folder; both are kept.
cd Packages/RuyioKit
DEBUG=$(cd .build/debug && pwd -P)
DEBUG=${DEBUG#"$PWD/"}
FILES=(.build/debug "$DEBUG"/*.xctest "$DEBUG/RuyioTestPlugin")
for extra in "$DEBUG"/*.bundle "$DEBUG/PackageFrameworks"; do
  [ -e "$extra" ] && FILES+=("$extra")
done
tar -cf "$STAGE/tests.tar" "${FILES[@]}"
tar -cf "$OUT" -C "$STAGE" .
echo "packed $(du -sh "$OUT" | cut -f1) into $OUT"
