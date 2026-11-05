#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EVIDENCE="$ROOT/tools/fixtures/RE4_StageJ8_9_Res4_Context_Restore_Evidence.csv"
grep -Fq 'RES4_EPILOGUE_REBASE_SP_FOR_VFP,0x0000561C,0xE247D058' "$EVIDENCE"
grep -Fq 'RES4_RESTORE_VFP_REGISTERS,0x00005620,0xECBD8B10' "$EVIDENCE"
grep -Fq 'RES4_EPILOGUE_REBASE_SP_FOR_CORE,0x00005624,0xE247D018' "$EVIDENCE"
grep -Fq 'RES4_RESTORE_EXTENDED_CORE_REGISTERS,0x00005628,0xE8BD0D00' "$EVIDENCE"
grep -Fq 'RES4_RESTORE_CORE_AND_RETURN_LR,0x0000562C,0xE8BD80F0' "$EVIDENCE"

COMMON=(
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift"
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift"
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
  "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift"
  "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift"
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift"
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift"
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift"
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift"
)

swiftc -D RE4_HOST_TESTING -parse-as-library "${COMMON[@]}" \
  "$ROOT/tools/test-stage-j8-16.swift" -o "$TMP/stage-j8-16-test"
"$TMP/stage-j8-16-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ816SyntheticInitializerEpilogueReplay \
  "${COMMON[@]}" \
  -emit-module-path "$TMP/StageJ816SyntheticInitializerEpilogueReplay.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "EPILOGUE: 0x561C -> 0x5620 -> 0x5624 -> 0x5628 -> 0x562C -> caller stop hook"
echo "BOUNDARY: synthetic stack/code only; no original Guest fetch."
