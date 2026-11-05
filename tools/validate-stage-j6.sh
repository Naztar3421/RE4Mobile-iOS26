#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityTests.swift" \
  "$ROOT/tools/test-stage-j6.swift" \
  -o "$TMP/stage-j6-test"
"$TMP/stage-j6-test" \
  "$ROOT/tools/fixtures/RE4_StageJ6_ExtraProductList_LSDA_Bytes.hex" \
  "$ROOT/tools/fixtures/RE4_StageJ6_ExtraProductList_LSDA_Crosswalk_20.csv"
