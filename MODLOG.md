# MODLOG: Halo Sword

## Design (from the interview)
- **Host:** Half Sword, Melty slug `custom-half-sword`, not in Melty's catalog. **Companion:** Halo: The Master Chief Collection, slug `halo-mcc`.
- **The game:** you play the normal Half Sword fighter. A gauntlet sends one Elite, then two Elites, then a Brute, with Halo's announcer calling each wave and Double Kill / Killing Spree.
- **What Halo brings, read from the player's own MCC:**
  - the Halo 3 Elite model (`riverworld.map`) and Brute model (`030_outskirts.map`);
  - Halo 3's announcer (`halo3/fmod/pc/*.fsb` plus `.fsb.info`).
  - Halo 3 was chosen over Halo CE because CE has no Brutes.
- **Solo.** License MIT; open to remixes.

## Route
- **Half Sword:** UE 5.4, UE4SS Lua (loader-api).
  - UE4SS is pinned to experimental `v3.0.1-1152-ge3ba1016`, the build the universal-modder field note verified on Half Sword EA 0.6.1.5.
  - Melty has no loader for Half Sword, so UE4SS is bundled (MIT).
- **Halo 3 files:** HaloBridge.exe, a .NET 8 self-contained program built on Reclaimer.
  - The same reader the Halo 3 MCC field note used headless.
  - Reclaimer is patched to build on .NET 8 without WPF; see `tools/build_bridge.sh`.
- **The two talk through a file.** The Lua mod appends to `Mods/HaloSword/runtime/events.log`; HaloBridge tails it and plays the announcer line.
- **Models:** each Halo node's triangles become one ProceduralMeshComponent.
  - Each component is attached to the matching Half Sword bone (`design/sheets/bone_map.json`).
  - The model is scaled so its pelvis height matches the fighter's.
  - Each piece is turned to follow the fighter's limb direction.
  - It is drawn in a flat tint with baked shading, because textures are not converted in v0.1.

## Environment notes
- **Built in a cloud Linux container.**
  - Neither game is installed there, and there is no Windows and no Melty app, so nothing has run in game yet.
  - .NET 9 downloads were blocked, so the build uses Ubuntu's .NET 8 SDK. Runtime packs come from nuget.org.

## First in-game session: what to check, in order
1. **Bridge reads Halo 3.** `HaloBridge.exe --game <HalfSword> --halo <MCC> --extract-only`, then read `runtime/bridge.log`.
   - The `render_model seen:` lines give the real Elite and Brute tag names. Fix `opponents.halo_model_candidates` if needed.
   - The `nodes:` line gives the Halo node names. Fix `bone_map.halo_node` if needed.
   - `runtime/halo3_dialog_index.txt` lists the real announcer paths. Fix `announcer.match`.
   - If the `.fsb.info` record layout differs from 280 bytes with the path at +24, `Announcer.ReadIndex` is where to fix it.
2. **UE4SS loads the mod.** `UE4SS.log` should show `[HaloSword] loaded from ...`.
3. **The fighter's bone names.** The first dressed fighter logs `Half Sword fighter bones (...)`. Correct `bone_map.willie_bones` from that list.
4. **Arena level name.** The gauntlet logs `gauntlet starts (level X)`. Check that it does not start in menus or the tavern.
5. **Engine calls.** Check that these work:
   - ProceduralMeshComponent exists;
   - `AddComponentByClass`;
   - the `CreateMeshSection_LinearColor` signature;
   - `VertexColorMaterial`.
   - The `dressed:` log line says which one failed.
6. **Death detection** (`Health <= 0`), the Brute's health multiplier, and the announcer playing.
7. Fill in `design/verification.json` (`{"sheet": {"row id": true}}`) for every row checked.

## Melty
- **Draft listing:** modId `1cfbef5a-b76d-40c3-92ae-4c1ce26fe5fb`, slug `halo-sword`.
  - Linked to GitHub Ddawg3012/Halo-Sword. License MIT, remixes allowed.
- **Release 0.1.0** (draft, release `dd42c962-f8cd-4655-8a0d-1108cb351dbf`).
  - one_click_check: yes. Nothing left on its to-finish list.
  - Review notes:
    - It ships executables (UE4SS, HaloBridge, vgmstream).
    - UE4SS's dwmapi.dll needs the VC++ 2015-2022 runtime. Half Sword (UE5) already requires that runtime and Steam installs it with the game.
    - Microsoft's download host was blocked from the build container, so the DLLs are not shipped app-local yet.
- **Still needed before publishing:**
  - a real gameplay screenshot;
  - test_release passing 2+ played runs on a PC with both games.
