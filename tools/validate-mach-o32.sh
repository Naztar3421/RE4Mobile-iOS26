#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "$ROOT/RE4MCTPreview/RE4MachO32Parser.swift" "$ROOT/tools/test-mach-o32.swift" -o "$TMP/macho32-test"
"$TMP/macho32-test"
