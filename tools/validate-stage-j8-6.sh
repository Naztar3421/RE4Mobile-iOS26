#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -D RE4_HOST_TESTING -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ7LandingPadContextModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextRestoreHarness.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextIntegrityGuard.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ82SJLJContextBridge.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ83SJLJResumeCompletionModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ85ForcedResumeCompletionModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ86ForcedResumeChainModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ86ForcedResumeChainTests.swift" \
  "$ROOT/tools/test-stage-j8-6.swift" \
  -o "$TMP/stage-j8-6-test"
"$TMP/stage-j8-6-test" \
  "$ROOT/tools/fixtures/RE4_StageJ6_ExtraProductList_LSDA_Bytes.hex" \
  "$ROOT/tools/fixtures/RE4_StageJ7_Res4_Initializer101_Frame_Evidence.csv" \
  "$ROOT/tools/fixtures/RE4_StageJ7_J1_LSDA_Crosswalk_20.csv"
# Production surface excludes test-only APIs and test runner.
swiftc -parse-as-library -emit-module -module-name StageJ86ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ7LandingPadContextModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextRestoreHarness.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ8SyntheticContextIntegrityGuard.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ82SJLJContextBridge.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ83SJLJResumeCompletionModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ85ForcedResumeCompletionModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ86ForcedResumeChainModel.swift" \
  -emit-module-path "$TMP/StageJ86ReleaseCompile.swiftmodule"
echo "RELEASE-MODE COMPILE: PASS"
