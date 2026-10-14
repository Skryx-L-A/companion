#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Creates the local code signing identity "companion-dev", so a rebuilt bundle keeps the
# microphone permission it was already given.
#
#   ./Scripts/make-dev-signing-identity.sh
#
# Why this exists. An ad hoc signature has no certificate, so its designated requirement is
# the cdhash of the binary itself — a different value after every build. macOS records that
# requirement in TCC.db next to the bundle id when a permission is granted, and on the next
# build nothing matches it any more: the microphone is neither granted nor asked for again,
# and the app records in silence. Measured on 2026-09-05 with a bundle from 28.08 still
# holding `kTCCServiceMicrophone | de.skryx.companion.mac | 2`.
#
# A certificate fixes that. Signed with one, the designated requirement reads
# `identifier "de.skryx.companion.mac" and certificate leaf = H"<hash of the certificate>"`,
# and that stays the same across builds as long as the certificate does. A Developer ID would
# do it too — this is the stand-in until there is one (STATUS.md names it as a blocker), and
# it is enough for TCC, which asks whether the requirement matches and not who vouched for it.
#
# The identity lives in a keychain of its own rather than in the login keychain. Importing a
# private key into the login keychain leaves it with an empty partition list, and the first
# `codesign` then waits on a graphical password dialog that a script cannot answer — measured
# here, the process hung until it was killed. `security set-key-partition-list` closes that,
# but it needs the login keychain's password, which no script should ask for. A separate
# keychain has a password this script generates and stores, so the whole thing runs through
# without a dialog.
#
# Idempotent: run it as often as you like. It creates nothing that is already there, and it
# never replaces an existing certificate — that would break exactly the permission it exists
# to keep.

set -euo pipefail

IDENTITY="${COMPANION_SIGNING_IDENTITY:-companion-dev}"
KEYCHAIN="${COMPANION_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/companion-dev.keychain-db}"
PASSWORD_FILE="${COMPANION_SIGNING_PASSWORD_FILE:-$HOME/Library/Application Support/companion-dev-signing/keychain.password}"
# Ten years. The certificate is the anchor of the permission; an expiry in the middle of a
# working year would take the microphone away without anybody having changed a thing.
DAYS=3650

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Dieses Skript ist für macOS. Hier läuft $(uname -s)." >&2
    exit 2
fi

# Already there? Then say what it is and stop. Re-creating it would produce a certificate with
# a different hash, and every permission granted to the old one would be void.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identität \"$IDENTITY\" gibt es schon in $KEYCHAIN."
    security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" 2>/dev/null | grep '^SHA-1 hash:' || true
    exit 0
fi

mkdir -p "$(dirname "$PASSWORD_FILE")"
if [ ! -f "$PASSWORD_FILE" ]; then
    umask 077
    openssl rand -hex 24 > "$PASSWORD_FILE"
fi
chmod 600 "$PASSWORD_FILE"
PASSWORD="$(cat "$PASSWORD_FILE")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# `codeSigning` in the extended key usage is what makes macOS offer the certificate to
# codesign at all; without it the identity is in the keychain and invisible to the signer.
cat > "$WORK_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3

[dn]
CN = $IDENTITY

[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -days "$DAYS" -config "$WORK_DIR/openssl.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$PASSWORD" -name "$IDENTITY" >/dev/null 2>&1

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
# No auto-lock and no timeout: a locked keychain in the middle of a build is another dialog
# nobody can answer.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# The partition list is the part that decides whether codesign gets the private key without a
# dialog. Set here, with the password this script owns.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# codesign searches the keychain search list, not the keychain named on its command line, so
# an identity in a keychain outside the list is "no identity found". Appended, never replaced.
CURRENT_LIST="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
if ! printf '%s\n' "$CURRENT_LIST" | grep -Fqx "$KEYCHAIN"; then
    # shellcheck disable=SC2086 # the list is one path per line and must expand to arguments
    security list-keychains -d user -s $CURRENT_LIST "$KEYCHAIN"
fi

echo "Identität \"$IDENTITY\" angelegt in $KEYCHAIN."
security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" 2>/dev/null | grep '^SHA-1 hash:' || true
echo "Passwort des Schlüsselbunds: $PASSWORD_FILE (nur lesbar für dich, gehört nicht ins Repo)."
echo "make-app-bundle.sh signiert von jetzt an damit."
