#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$ROOT/tools/fixtures/RE4_StageJ8_9_Res4_Context_Restore_Evidence.csv"
grep -Fq 'RES4_SAVE_VFP_REGISTERS,0x00005194,0xED2D8B10' "$FIXTURE"
grep -Fq 'PROVIDER_RESTORE_R7,0x358CF9D0,0xE5947020' "$FIXTURE"
grep -Fq 'PROVIDER_RESTORE_SP,0x358CF9D4,0xE594D028' "$FIXTURE"
grep -Fq 'PROVIDER_RESTORE_PC,0x358CF9D8,0xE5940024' "$FIXTURE"
grep -Fq 'RES4_RESTORE_CORE_AND_RETURN_LR,0x0000562C,0xE8BD80F0' "$FIXTURE"
swiftc -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/tools/test-stage-j8-9.swift" \
  -o "$TMP/stage-j8-9-test"
"$TMP/stage-j8-9-test"
swiftc -parse-as-library -emit-module -module-name StageJ89ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  -emit-module-path "$TMP/StageJ89ReleaseCompile.swiftmodule"
echo "RELEASE-MODE COMPILE: PASS"
echo "EVIDENCE FIXTURE: $FIXTURE"

# The forced-Resume CPU context adapter contract follows the J.8.9 preflight.
bash "$ROOT/tools/validate-stage-j8-10.sh"
