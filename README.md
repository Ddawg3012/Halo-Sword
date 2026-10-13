# Halo Sword

Half Sword's arena against Halo 3's Covenant: **one Elite, then two, then a Brute**, with Halo's announcer. Everything from Halo is read from your own Master Chief Collection.

Melty page: https://melty.gg/m/halo-sword (draft)

## What players get
- **Host: Half Sword.** You play your normal Half Sword fighter, with Half Sword's physics combat.
- **A three-wave gauntlet** starts by itself in the arena (press F7 to restart it):
  1. one Elite;
  2. two Elites;
  3. a Brute, with 1.6x health.
- **Halo 3 brings its Covenant.** Every opponent is a Half Sword fighter wearing the real Halo 3 Elite or Brute model, read at launch from `halo3/maps/*.map` in the player's MCC.
- **Halo 3 brings its announcer.** It calls each wave, Double Kill, Triple Kill, Killing Spree (a flawless run), and victory or defeat. The lines are read from `halo3/fmod/pc/*.fsb` in the player's MCC.
- **Single player.** Half Sword has no online play, so this is a solo gauntlet.

## How it works
| Part | What | Where |
|---|---|---|
| `mod/HaloSword` | UE4SS Lua mod: waves, spawning, death tracking, fitting the Halo model pieces onto Half Sword's bones, event log | `HalfSwordUE5/Binaries/Win64/ue4ss/Mods/HaloSword` |
| `bridge/HaloBridge` | Melty starts this program instead of the game. It reads the Halo 3 models (Reclaimer) and announcer lines (vgmstream) from the player's MCC into `runtime/`, starts Half Sword, then plays announcer lines when the mod logs events. | `.../Mods/HaloSword/bridge` |
| `design/sheets` | The source of truth: opponents, waves, announcer, events, bone map, game hooks, release components. `tools/sheets.py gen` turns it into `sheets_gen.lua` and `Sheets.g.cs`. | |
| `melty.json` | The Melty install recipe | |

Nothing from Halo or Half Sword ships. `runtime/` is generated on each player's PC.

## Build
```
python3 tools/sheets.py preflight   # unfilled cells, broken references, rows not yet checked in game
bash tests/run.sh                   # preflight + the Lua gauntlet against a fake game
bash tools/build_bridge.sh          # HaloBridge.exe (.NET 8 SDK; Reclaimer fetched + patched)
bash tools/package.sh 0.1.0         # dist/HaloSword-0.1.0.zip
```

## Status (v0.1.0)
- **Built and checked offline:** the sheets pass preflight; the Lua gauntlet passes the offline harness (waves, events, multi-kills, spree, defeat, model pieces placed on bones); the bridge compiles for Windows.
- **Not yet run in the real games.** Every engine call is a documented name that has not yet been confirmed here: `design/verification.json` is empty until an in-game run fills it. See MODLOG.md for what to check first.
