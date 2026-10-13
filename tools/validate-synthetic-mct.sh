#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$ROOT/tools/make_synthetic_mct.py" "$TMP/synthetic.mct"
swiftc "$ROOT/RE4MCTPreview/RE4MCTTextureDecoder.swift" "$ROOT/tools/main.swift" -o "$TMP/mct-decoder-test"
"$TMP/mct-decoder-test" "$TMP/synthetic.mct" "$TMP/synthetic.rgba"
test "$(wc -c < "$TMP/synthetic.rgba" | tr -d ' ')" = "256"
echo "Synthetic MCT decoder test passed."
