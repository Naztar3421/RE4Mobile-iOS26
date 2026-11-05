#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
  "$ROOT/tools/test-stage-j8-15.swift" -o "$TMP/stage-j8-15-test"
"$TMP/stage-j8-15-test"

swiftc -parse-as-library -emit-module \
  -module-name StageJ815SyntheticInstallContextCoreApply \
  "${COMMON[@]}" \
  -emit-module-path "$TMP/StageJ815SyntheticInstallContextCoreApply.swiftmodule"

echo "RELEASE-MODE COMPILE: PASS"
echo "BOUNDARY: synthetic marker instruction only; hook stops before next fetch."

# Stage J.8.16: replay the audited #101 epilogue over a synthetic stack/code image.
bash "$ROOT/tools/validate-stage-j8-16.sh"
