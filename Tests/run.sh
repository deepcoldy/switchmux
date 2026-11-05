#!/bin/bash
# Model / migration tests. Builds a small executable from the model sources
# and runs it against a throwaway config directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 \
  "$ROOT"/Sources/Model/*.swift \
  "$ROOT"/Sources/Services/DockReader.swift \
  "$ROOT"/Sources/Services/HotkeyEventTap.swift \
  "$ROOT"/Tests/ModelTests/main.swift \
  -o "$OUT/model-tests"
mkdir -p "$OUT/config"
SWITCHMUX_CONFIG_DIR="$OUT/config" "$OUT/model-tests"
