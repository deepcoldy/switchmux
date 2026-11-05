#!/usr/bin/env bash
# Build the polished drag-to-install DMG.
#
#   scripts/make_dmg.sh <path/to/SwitchMux.app> <out.dmg>
#
# - renders the background (scripts/dmg_background.swift, @1x + @2x -> HiDPI TIFF)
# - installs dmgbuild + deps from scripts/dmg-requirements.txt (exact versions,
#   sha256 hashes, wheels only, no dependency resolution) into a throwaway venv
# - lays out SwitchMux.app + an /Applications link via scripts/dmg_settings.py
# Signing/notarization is done by the caller (CI) afterwards.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <app> <out.dmg>" >&2
  exit 2
fi

[ -d "$1" ] || { echo "error: app not found: $1" >&2; exit 1; }

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
VOLNAME="$(basename "$APP" .app)"
mkdir -p "$(dirname "$OUT")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make_dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering background"
swift "$SCRIPTS/dmg_background.swift" "$WORK/bg"
tiffutil -cathidpicheck "$WORK/bg/dmg_background.png" "$WORK/bg/dmg_background@2x.png" \
  -out "$WORK/bg/dmg_background.tiff"

echo "==> Installing hash-pinned dmgbuild into a throwaway venv"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check \
  --no-input --require-hashes --no-deps --only-binary :all: \
  -r "$SCRIPTS/dmg-requirements.txt"

ICON_ARGS=()
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  ICON_ARGS=(-D "icon=$APP/Contents/Resources/AppIcon.icns")
fi

echo "==> Building $OUT"
rm -f "$OUT"
"$WORK/venv/bin/dmgbuild" -s "$SCRIPTS/dmg_settings.py" \
  -D "app=$APP" \
  -D "background=$WORK/bg/dmg_background.tiff" \
  ${ICON_ARGS[@]+"${ICON_ARGS[@]}"} \
  "$VOLNAME" "$OUT"

hdiutil verify "$OUT" >/dev/null
echo "==> Done: $OUT"
