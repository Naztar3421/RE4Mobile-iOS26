#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

grep -Fq 'branchRegisterOpcode == 0x4700 || branchRegisterOpcode == 0x4780' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'linkRegisterValue: isBLX ? (pc &+ 4) : nil' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'let link = isBLX ? ((pc &+ 2) | 1) : nil' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'instructionSetState = transition.targetState' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'let rawTarget = try reg(rm, pc: pc)' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'guard !isBLX || rm != 15' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'unsupportedARMBranchTargetAlignment' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"

swiftc -D RE4_HOST_TESTING -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  "$ROOT/tools/test-stage-j8-14.swift" \
  -o "$TMP/stage-j8-14-test"
"$TMP/stage-j8-14-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ814BXBLXReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  -emit-module-path "$TMP/StageJ814BXBLXReleaseCompile.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "BX/BLX INTERWORKING: A32/T16 decode, target-state publication, canonical PC and source-state LR"

# Stage J.8.15: apply only a prepared synthetic #101 context to the bounded Core.
bash "$ROOT/tools/validate-stage-j8-15.sh"

# Stage J.8.15: gated synthetic InstallContext-to-Core application.
bash "$ROOT/tools/validate-stage-j8-15.sh"
