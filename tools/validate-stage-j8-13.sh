#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -Fq 'public func readInstruction16' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'let halfword = try memory.readInstruction16(pc)' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
grep -Fq 'let alignedPC = (pc &+ 4) & ~UInt32(3)' "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift"
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
  "$ROOT/tools/test-stage-j8-13.swift" \
  -o "$TMP/stage-j8-13-test"
"$TMP/stage-j8-13-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ813ARMThumbReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" \
  "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  -emit-module-path "$TMP/StageJ813ARMThumbReleaseCompile.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "ARM/THUMB CONTRACT: state-specific fetch width, canonical PC and bounded Thumb-1 decode"
# Stage J.8.13 remains inside the established J.8.5 umbrella validation chain.
