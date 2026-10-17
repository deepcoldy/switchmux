#!/bin/bash
# Build SwitchMux.app without Xcode (Command Line Tools suffice).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP_NAME="SwitchMux"
BUNDLE_ID="dev.shenhan.switchmux"
APP="$BUILD/$APP_NAME.app"
DEPLOYMENT_TARGET="13.0"

echo "==> Compiling Swift sources"
SWIFT_FILES=()
while IFS= read -r line; do SWIFT_FILES+=("$line"); done < <(
  find "$ROOT/Sources" -name '*.swift' \
    -not -path "$ROOT/Sources/CaptureHelper/*" | sort
)
HELPER_FILES=()
while IFS= read -r line; do HELPER_FILES+=("$line"); done < <(
  find "$ROOT/Sources/CaptureHelper" -name '*.swift' | sort
)

compile() {
  local arch="$1" out="$2"
  echo "    [$arch]"
  swiftc -O \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -swift-version 5 \
    "${SWIFT_FILES[@]}" \
    -o "$out"
}

compileHelper() {
  local arch="$1" out="$2"
  echo "    [helper $arch]"
  swiftc -O \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -swift-version 5 \
    "${HELPER_FILES[@]}" \
    -o "$out"
}

mkdir -p "$BUILD/obj"
compile arm64 "$BUILD/obj/SwitchMux-arm64"
compile x86_64 "$BUILD/obj/SwitchMux-x86_64"
compileHelper arm64 "$BUILD/obj/Helper-arm64"
compileHelper x86_64 "$BUILD/obj/Helper-x86_64"

echo "==> Creating universal binaries"
lipo -create "$BUILD/obj/SwitchMux-arm64" "$BUILD/obj/SwitchMux-x86_64" \
  -output "$BUILD/obj/SwitchMux"
lipo -create "$BUILD/obj/Helper-arm64" "$BUILD/obj/Helper-x86_64" \
  -output "$BUILD/obj/SwitchMuxCaptureHelper"

echo "==> Assembling .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/obj/SwitchMux" "$APP/Contents/MacOS/SwitchMux"
cp "$BUILD/obj/SwitchMuxCaptureHelper" "$APP/Contents/MacOS/SwitchMuxCaptureHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Generating icon"
swift "$ROOT/scripts/make_icon.swift" "$BUILD/icon_1024.png"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
sips -z 16 16     "$BUILD/icon_1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$BUILD/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$BUILD/icon_1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$BUILD/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$BUILD/icon_1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$BUILD/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$BUILD/icon_1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$BUILD/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$BUILD/icon_1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$BUILD/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc code signing"
# Sign the helper first, then the app bundle so the sealed bundle references it.
codesign --force --sign - --identifier "$BUNDLE_ID.capture-helper" \
  "$APP/Contents/MacOS/SwitchMuxCaptureHelper"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo ""
echo "Build complete: $APP"
echo "Run: open \"$APP\"   (then grant Accessibility in System Settings)"
