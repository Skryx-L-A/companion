#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the wakeword static library and puts it where the Swift package links from.
#
# `companion-wakeword-ffi` is a Rust staticlib. SwiftPM cannot build it, so this script does,
# and everything that runs `swift build` or `swift test` on this package runs this first —
# without the archive the link fails with "library not found for -lcompanion_wakeword_ffi".
#
#   ./Scripts/build-wakeword.sh [debug|release]        default debug
#
# The archive lands in Vendor/, which is out of git: it is 14 MB of build output, and the
# source it comes from is two directories over.

set -euo pipefail

CONFIGURATION="${1:-debug}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$(cd "$PACKAGE_DIR/.." && pwd)"
VENDOR_DIR="$PACKAGE_DIR/Vendor"
ARCHIVE="libcompanion_wakeword_ffi.a"

case "$CONFIGURATION" in
  debug)   CARGO_FLAGS=() ;;
  release) CARGO_FLAGS=(--release) ;;
  *) echo "unbekannte Konfiguration: $CONFIGURATION (debug oder release)" >&2; exit 2 ;;
esac

cd "$APP_DIR"
cargo build -p companion-wakeword-ffi ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"}

BUILT="$APP_DIR/target/$CONFIGURATION/$ARCHIVE"
if [ ! -f "$BUILT" ]; then
  echo "cargo hat $BUILT nicht erzeugt" >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"
# Copied rather than symlinked: a link into target/ breaks the moment somebody runs
# `cargo clean`, and the linker error it leaves behind names neither of the two.
cp "$BUILT" "$VENDOR_DIR/$ARCHIVE"
echo "$VENDOR_DIR/$ARCHIVE ($CONFIGURATION)"
