#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Wraps the built binary in a companion.app bundle. Signing and notarisation are not done
# here; DEPLOYMENT.md owns the release path.
#
#   ./Scripts/make-app-bundle.sh [debug|release]

set -euo pipefail

CONFIGURATION="${1:-release}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PACKAGE_DIR"

# SwiftPM cannot build the Rust wakeword library; without it the link fails.
./Scripts/build-wakeword.sh "$CONFIGURATION"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$BIN_PATH/companion.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/companion-mac" "$APP_DIR/Contents/MacOS/companion-mac"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "$APP_DIR"
