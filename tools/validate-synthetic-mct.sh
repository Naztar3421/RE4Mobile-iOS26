#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "$ROOT/RE4MCTPreview/RE4MCTTextureDecoder.swift" "$ROOT/tools/main.swift" -o "$TMP/mct-decoder-test"

run_case() {
  local name="$1" format="$2" compression="$3"
  python3 "$ROOT/tools/make_synthetic_mct.py" "$TMP/$name.mct" --format "$format" --compression "$compression"
  "$TMP/mct-decoder-test" "$TMP/$name.mct" "$TMP/$name.rgba" "$TMP/$name.mct.expected.rgba" "$format" "$compression"
}
run_case raw-rgba 2 0
run_case indexed-rgb 6 0
run_case indexed-rgba 7 0
run_case indexed-rgb-lzw 6 1

echo "All synthetic MCT decoder cases passed (format 2, format 6, format 7, and compressed format 6)."
