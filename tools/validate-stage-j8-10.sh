#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$ROOT/tools/fixtures/RE4_StageJ8_10_Forced_Resume_Context_Transfer_Evidence.csv"
grep -Fq 'FORCED_PHASE2_RESTORE_R7,0x358CF8DC,0xE5947020' "$FIXTURE"
grep -Fq 'FORCED_PHASE2_RESTORE_SP,0x358CF8E0,0xE594D028' "$FIXTURE"
grep -Fq 'FORCED_PHASE2_LOAD_PC_TO_R0,0x358CF8E4,0xE5940024' "$FIXTURE"
grep -Fq 'FORCED_PHASE2_BX_R0,0x358CF8E8,0xE12FFF10' "$FIXTURE"
grep -Fq 'NORMAL_PHASE2_RESTORE_R7,0x358CF9D0,0xE5947020' "$FIXTURE"
grep -Fq 'let word = try memory.readInstruction32(pc)' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'registers[15] = target & ~3' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'if word == 0xED2D8B10 { registers[13] = registers[13] &- 64; return true }' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'if word == 0xECBD8B10 { registers[13] = registers[13] &+ 64; return true }' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
swiftc -D RE4_HOST_TESTING -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/tools/test-stage-j8-10.swift" \
  -o "$TMP/stage-j8-10-test"
"$TMP/stage-j8-10-test"
swiftc -parse-as-library -emit-module -module-name StageJ810ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  -emit-module-path "$TMP/StageJ810ReleaseCompile.swiftmodule"
echo "RELEASE-MODE COMPILE: PASS"
echo "FORCED/NORMAL PROVIDER EVIDENCE: $FIXTURE"
