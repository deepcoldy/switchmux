#!/bin/bash
# Re-sign a locally built SwitchMux.app with the Developer ID certificate so
# macOS keeps treating it as the same app as the official releases: the
# Accessibility / Screen Recording grants stay valid across rebuilds.
#
# Usage:
#   scripts/sign-local.sh [path/to/SwitchMux.app] [path/to/DeveloperID.p12]
#   (prompts for the .p12 password; SWITCHMUX_P12 overrides the .p12 path)
#
# The .p12 is imported into a throwaway keychain that is deleted on exit; the
# login keychain and its search list are left as they were. The password is
# only handed to openssl through its environment, never on a command line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/SwitchMux.app}"
P12="${2:-${SWITCHMUX_P12:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/开发者证书/Apple签名-8VP93PY3E9/developer-id-application.p12}}"
TEAM_ID="8VP93PY3E9"

[ -d "$APP" ] || { echo "No app at $APP (run ./build.sh first)" >&2; exit 1; }
if ! head -c 1 "$P12" >/dev/null 2>&1; then
  echo "Cannot read $P12." >&2
  echo "If it lives in iCloud Drive, download it first (Finder → right-click → Download Now)." >&2
  exit 1
fi

read -r -s -p "Password for $(basename "$P12"): " PASS; echo

WORK="$(mktemp -d)"
KC="$WORK/switchmux-sign.keychain-db"
KCPASS="$(openssl rand -hex 24)"
ORIG_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && ORIG_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)

cleanup() {
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security list-keychains -d user -s "$KC" "${ORIG_KEYCHAINS[@]}"

# The leaf only forms a valid identity together with Apple's G2 intermediate.
# Cached after the first download so later (offline) runs still work.
G2="$HOME/Library/Caches/switchmux/DeveloperIDG2CA.cer"
if [ ! -s "$G2" ]; then
  mkdir -p "$(dirname "$G2")"
  curl -fsSL -o "$G2.tmp" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer && mv "$G2.tmp" "$G2"
fi
security import "$G2" -k "$KC" >/dev/null

TMPPASS="$(openssl rand -hex 24)"
# Extract key + certificate (password via environment only), then re-wrap
# them with a one-off password for `security import`. Older .p12 files use
# ciphers OpenSSL 3+ only reads with -legacy, so try both.
extract() { # $1 = -nocerts | -nokeys, $2 = output
  P12PASS="$PASS" openssl pkcs12 -in "$P12" -passin env:P12PASS -nodes "$1" -out "$2" 2>/dev/null \
    || P12PASS="$PASS" openssl pkcs12 -legacy -in "$P12" -passin env:P12PASS -nodes "$1" -out "$2" 2>/dev/null
}
umask 077
if extract -nocerts "$WORK/key.pem" && extract -nokeys "$WORK/certs.pem" \
   && TMPPASS="$TMPPASS" openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certs.pem" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout env:TMPPASS -out "$WORK/identity.p12" 2>/dev/null; then
  # (SHA1/3DES: the only PKCS#12 encoding macOS `security import` reads.)
  rm -f "$WORK/key.pem"
  security import "$WORK/identity.p12" -k "$KC" -P "$TMPPASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
else
  rm -f "$WORK/key.pem"
  echo "Could not open $(basename "$P12") — wrong password?" >&2
  exit 1
fi
unset PASS
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null

IDENTITY="$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in $(basename "$P12")" >&2; exit 1; }
echo "==> Signing with: $IDENTITY"

sign() {
  # Timestamp when online; fall back to none so offline rebuilds still work.
  codesign --force --options runtime --timestamp --keychain "$KC" --sign "$IDENTITY" "$@" 2>/dev/null \
    || codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "$IDENTITY" "$@"
}
# Same identifiers as the CI release build, so existing grants match.
sign --identifier "SwitchMuxCaptureHelper" "$APP/Contents/MacOS/SwitchMuxCaptureHelper"
sign --identifier "dev.shenhan.switchmux" "$APP"

codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" \
  || { echo "Signed, but team identifier is not $TEAM_ID" >&2; exit 1; }
echo "==> Signed $APP (team $TEAM_ID)"
