#!/usr/bin/env bash
# Offline checks: sheet preflight, then the Lua gauntlet against a fake game (tests/harness.lua).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tools/sheets.py" gen >/dev/null
python3 "$ROOT/tools/sheets.py" preflight | grep -v "not yet checked"
T="$(mktemp -d)"
cp -r "$ROOT/mod/HaloSword" "$T/HaloSword"
mkdir -p "$T/localappdata/HaloSword/runtime"
LOCALAPPDATA="$T/localappdata" lua5.4 "$ROOT/tests/harness.lua" "$T/HaloSword"
