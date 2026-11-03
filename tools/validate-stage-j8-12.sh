#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
  "$ROOT/tools/test-stage-j8-12.swift" \
  -o "$TMP/stage-j8-12-test"
"$TMP/stage-j8-12-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ812VFPReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  -emit-module-path "$TMP/StageJ812VFPReleaseCompile.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "VFP STACK CONTRACT: full-range Guest Memory transfer before SP/VFP publish"

# Stage J.8.13: state-aware ARM/Thumb fetch and bounded Thumb-1 stepping.
bash "$ROOT/tools/validate-stage-j8-13.sh"
