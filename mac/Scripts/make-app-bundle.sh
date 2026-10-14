#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Wraps the built binary in a companion.app bundle and signs it with the local development
# identity. Notarisation is not done here; DEPLOYMENT.md owns the release path.
#
#   ./Scripts/make-app-bundle.sh [debug|release]
#
# The signature is what keeps the microphone working across builds. An ad hoc signature is
# tied to the cdhash of the binary, so every rebuild looks like a different application to
# macOS and the permission granted to the previous one is silently void.
# `Scripts/make-dev-signing-identity.sh` creates the certificate that fixes it; without it
# this script still builds, ad hoc, and says what that costs.
#
#   COMPANION_APP_DIR   where to put the bundle (default: next to the built binary)

set -euo pipefail

CONFIGURATION="${1:-release}"
IDENTITY="${COMPANION_SIGNING_IDENTITY:-companion-dev}"
SIGNING_KEYCHAIN="${COMPANION_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/companion-dev.keychain-db}"
SIGNING_PASSWORD_FILE="${COMPANION_SIGNING_PASSWORD_FILE:-$HOME/Library/Application Support/companion-dev-signing/keychain.password}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$(cd "$PACKAGE_DIR/.." && pwd)"
cd "$PACKAGE_DIR"

# The shell spawns this itself when the socket is dead (`DaemonLauncher.swift`), so it has to
# be in the bundle, not merely on the machine that built it.
CARGO_PROFILE_FLAG=""
CARGO_TARGET_SUBDIR="debug"
if [ "$CONFIGURATION" = "release" ]; then
    CARGO_PROFILE_FLAG="--release"
    CARGO_TARGET_SUBDIR="release"
fi
# Three binaries, not one. companion-hook is what Claude Code calls for Stop, SubagentStop
# and Notification, and companion registers it: both are named by an absolute path inside the
# bundle, so a bundle without them installs hooks that point at a build directory.
( cd "$CORE_DIR" && cargo build -p companion-daemon -p companion-cli $CARGO_PROFILE_FLAG )
BUILT_DIR="$CORE_DIR/target/$CARGO_TARGET_SUBDIR"
DAEMON_BIN="$BUILT_DIR/companion-daemon"

# SwiftPM cannot build the Rust wakeword library; without it the link fails.
./Scripts/build-wakeword.sh "$CONFIGURATION"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="${COMPANION_APP_DIR:-$BIN_PATH/companion.app}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/companion-mac" "$APP_DIR/Contents/MacOS/companion-mac"
cp "$DAEMON_BIN" "$APP_DIR/Contents/MacOS/companion-daemon"
cp "$BUILT_DIR/companion-hook" "$APP_DIR/Contents/MacOS/companion-hook"
cp "$BUILT_DIR/companion" "$APP_DIR/Contents/MacOS/companion"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# The keychain has to be unlocked and in the search list before codesign can find the key.
# `find-certificate` against the file alone answers whether the identity exists at all, which
# is the question that decides between a signed and an ad hoc bundle.
if [ -f "$SIGNING_KEYCHAIN" ] && security find-certificate -c "$IDENTITY" "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
    if [ -f "$SIGNING_PASSWORD_FILE" ]; then
        security unlock-keychain -p "$(cat "$SIGNING_PASSWORD_FILE")" "$SIGNING_KEYCHAIN"
    fi
    # `Resources/companion.entitlements` carries the three keys the hardened runtime
    # otherwise switches off: the microphone, the calendar and the location the three usage
    # descriptions in Info.plist ask about. It has no comments in it on purpose — the parser
    # that reads entitlements at signing time rejects an XML comment with
    # "AMFIUnserializeXML: syntax error", measured here on 05.09.2026.
    #
    # Every nested binary of its own, then the bundle. All four used to be copied in and only
    # two of them signed, so `companion-hook` and `companion` stayed ad hoc and linker-signed
    # (Befund 5 of the reviewer pass of 05.09.2026). `codesign --verify --deep --strict` goes
    # through on that, because an ad hoc signature is a signature for a local check —
    # notarisation is where it is refused, which is one build and one upload later.
    #
    # Only the two that need them get the entitlements: the shell asks for the microphone and
    # the location, the daemon reads the calendar. The hook and the CLI ask the daemon over
    # its socket and touch none of the three, and an entitlement handed to a binary that has
    # no use for it is a privilege waiting for whoever finds a way to run it.
    #
    # Inner first, outer last: a signature seals what is inside it, so signing the bundle
    # before the binaries in it would seal something that is about to change.
    sign_with_identity() {
        codesign --force --keychain "$SIGNING_KEYCHAIN" --sign "$IDENTITY" \
            --options runtime --timestamp=none "$@"
    }
    for nested in companion-daemon companion-hook companion; do
        # Written out rather than collected in an array: `set -u` under the bash 3.2 that
        # ships with macOS refuses to expand an empty one at all.
        if [ "$nested" = companion-daemon ]; then
            sign_with_identity --entitlements Resources/companion.entitlements \
                "$APP_DIR/Contents/MacOS/$nested"
        else
            sign_with_identity "$APP_DIR/Contents/MacOS/$nested"
        fi
    done
    sign_with_identity --entitlements Resources/companion.entitlements "$APP_DIR"
    echo "signiert mit \"$IDENTITY\"" >&2
    codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/^designated => /  designated requirement: /p' >&2
else
    # Not an error: a fresh clone has no certificate, and the build has to work anyway. It
    # does have to say what is missing, because the symptom otherwise is a microphone that
    # stops working after the next build with nothing on screen to explain it.
    echo "HINWEIS: keine Signaturidentität \"$IDENTITY\" gefunden – das Bundle ist ad hoc signiert." >&2
    echo "  Damit ändert sich die Code-Identität mit jedem Neubau, und macOS vergisst die" >&2
    echo "  Mikrofonfreigabe, ohne noch einmal zu fragen." >&2
    echo "  Einmalig anlegen: ./Scripts/make-dev-signing-identity.sh" >&2
fi

echo "$APP_DIR"
