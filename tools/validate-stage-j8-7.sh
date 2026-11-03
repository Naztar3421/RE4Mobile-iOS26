#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -D RE4_HOST_TESTING -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ87ProviderABIModel.swift" \
  "$ROOT/tools/test-stage-j8-7.swift" \
  -o "$TMP/stage-j8-7-test"
"$TMP/stage-j8-7-test"
swiftc -parse-as-library -emit-module -module-name StageJ87ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4StageJ6SJLJPersonalityModel.swift" \
  "$ROOT/RE4MCTPreview/RE4StageJ87ProviderABIModel.swift" \
  -emit-module-path "$TMP/StageJ87ReleaseCompile.swiftmodule"
echo "RELEASE-MODE COMPILE: PASS"
