#!/usr/bin/env bash
# Builds dist/HaloSword-<version>.zip: UE4SS (pinned), the HaloSword Lua mod, HaloBridge.exe and vgmstream.
# Layout: Win64/ -> {game}/HalfSwordUE5/Binaries/Win64 (see melty.json). Nothing from either game is included.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
UE4SS_URL=https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-1152-ge3ba1016.zip
UE4SS_SHA=af8ea9d8975e8eff7967423f43b8b50875e66a29a0f434cffce6e0867ea17252
VGM_URL=https://github.com/vgmstream/vgmstream/releases/download/r2117/vgmstream-win64.zip
VGM_SHA=6c4a8a3813864fefed081bbd337dbc0ad93bf88e0b92f5db98d7ab258b22dc6c
DL="$ROOT/build/downloads"; mkdir -p "$DL"
fetch() { [ -f "$DL/$3" ] || curl -sSfL -o "$DL/$3" "$1"; echo "$2  $DL/$3" | sha256sum -c --quiet; }
fetch "$UE4SS_URL" "$UE4SS_SHA" ue4ss.zip
fetch "$VGM_URL" "$VGM_SHA" vgmstream.zip

bash "$ROOT/tests/run.sh" > "$ROOT/build/offline-tests.log" 2>&1 || { cat "$ROOT/build/offline-tests.log"; exit 1; }
[ -f "$ROOT/build/bridge/dotnet.exe" ] || bash "$ROOT/tools/build_bridge.sh"

STAGE="$ROOT/build/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/Win64"
unzip -q "$DL/ue4ss.zip" -d "$STAGE/Win64"
M="$STAGE/Win64/ue4ss/Mods"
mkdir -p "$M/HaloSword/Scripts" "$M/HaloSword/bridge/vgmstream"
cp "$ROOT/mod/HaloSword/Scripts/"*.lua "$M/HaloSword/Scripts/"
: > "$M/HaloSword/enabled.txt"
cp -r "$ROOT/build/bridge/." "$M/HaloSword/bridge/"
unzip -q "$DL/vgmstream.zip" -d "$M/HaloSword/bridge/vgmstream"
cp "$ROOT/LICENSE" "$M/HaloSword/LICENSE.txt"
cp "$ROOT/CREDITS.md" "$M/HaloSword/CREDITS.md"
cp "$ROOT/build/reclaimer/LICENSE" "$M/HaloSword/bridge/Reclaimer-LICENSE.txt"
# ship only what Halo Sword needs: UE4SS's sample mods are dropped (Melty looks for every bundled mod to start),
# shared/ (UEHelpers) stays, and both mod lists name only HaloSword
for d in "$M"/*/; do n=$(basename "$d"); case "$n" in HaloSword|shared) ;; *) rm -rf "$d";; esac; done
printf 'HaloSword : 1\n' > "$M/mods.txt"
printf '[\n    {\n        "mod_name": "HaloSword",\n        "mod_enabled": true\n    }\n]\n' > "$M/mods.json"
mkdir -p "$ROOT/dist"; OUT="$ROOT/dist/HaloSword-$VERSION.zip"; rm -f "$OUT"
(cd "$STAGE" && zip -q -r -X "$OUT" Win64)
ls -la "$OUT"; sha256sum "$OUT"
