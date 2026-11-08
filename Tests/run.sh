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
# One process per scenario: the stores load their config once per launch.
for scenario in main upgrade seed usage; do
  mkdir -p "$OUT/$scenario/config"
  SWITCHMUX_TEST_SCENARIO="$scenario" SWITCHMUX_CONFIG_DIR="$OUT/$scenario/config" \
    SWITCHMUX_CLOUD_DIR="$OUT/$scenario/cloud" "$OUT/model-tests"
done
