#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -D RE4_HOST_TESTING -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  "$ROOT/tools/test-stage-j8-11.swift" \
  -o "$TMP/stage-j8-11-test"
"$TMP/stage-j8-11-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ811ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestMemoryRegions.swift" \
  "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
  "$ROOT/RE4MCTPreview/RE4ARMv6InstructionSetState.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ89ContextRestorePreconditions.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ810GuestCPUContextAdapter.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ811CoreArchitecturalState.swift" \
  -emit-module-path "$TMP/StageJ811ReleaseCompile.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "ATOMIC COMMIT CONTRACT: preflight-all-fields -> stale-source check -> no-throw modeled-state apply"
