#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ7LandingPadContextModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextRestoreHarness.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextRestoreTests.swift" \
  "$ROOT/tools/test-stage-j8.swift" \
  -o "$TMP/stage-j8-test"
"$TMP/stage-j8-test" \
  "$ROOT/tools/fixtures/RE4_StageJ7_Res4_Initializer101_Frame_Evidence.csv" \
  "$ROOT/tools/fixtures/RE4_StageJ7_J1_LSDA_Crosswalk_20.csv"
