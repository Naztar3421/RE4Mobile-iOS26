#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library \
  "$ROOT/RE4MCTPreview/RE4StageJ88SJLJTSDLifecycleModel.swift" \
  "$ROOT/tools/test-stage-j8-8.swift" \
  -o "$TMP/stage-j8-8-test"
"$TMP/stage-j8-8-test"
swiftc -parse-as-library -emit-module -module-name StageJ88ReleaseCompile \
  "$ROOT/RE4MCTPreview/RE4StageJ88SJLJTSDLifecycleModel.swift" \
  -emit-module-path "$TMP/StageJ88ReleaseCompile.swiftmodule"
echo "RELEASE-MODE COMPILE: PASS"
bash "$ROOT/tools/validate-stage-j8-9.sh"
