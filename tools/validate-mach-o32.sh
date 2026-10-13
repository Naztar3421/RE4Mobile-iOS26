#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "$ROOT/RE4MCTPreview/RE4GuestMemoryReading.swift" \
       "$ROOT/RE4MCTPreview/RE4GuestARMv6Runtime.swift" \
       "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" \
       "$ROOT/RE4MCTPreview/RE4MachO32Loader.swift" \
       "$ROOT/RE4MCTPreview/RE4MachO32ImportBindingPlan.swift" \
       "$ROOT/RE4MCTPreview/RE4MachO32HLEBinder.swift" \
       "$ROOT/tools/test-mach-o32.swift" \
       -o "$TMP/macho32-test"
"$TMP/macho32-test"
