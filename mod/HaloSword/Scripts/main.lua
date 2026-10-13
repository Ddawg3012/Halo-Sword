-- Halo Sword: a Covenant gauntlet in Half Sword's Free play arena.
-- One Elite, then two, then a Brute. Wave 1 is the fighter Free play itself spawned (never removed); waves 2 and 3
-- come from the arena's own spawner. Each fighter wears the Halo 3 model HaloBridge read from the player's own
-- Master Chief Collection; Halo 3's announcer calls the waves and multi-kills (HaloBridge plays them from events.log).
-- Tables come from sheets_gen.lua, generated from design/sheets. Change the sheets, not the tables.

local S = require("sheets_gen")
local UEHelpers = require("UEHelpers")

local function mod_dir()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*)[/\\]Scripts[/\\]main%.lua$")
    return dir or "ue4ss/Mods/HaloSword"
end
local MOD = mod_dir()
local RUNTIME = MOD .. "/runtime"

local function log(fmt, ...)
    print(string.format("[HaloSword] " .. fmt .. "\n", ...))
end

local HOOKS = {}
for id, row in pairs(S.hooks) do HOOKS[id] = row.name end

local TICK_MS = 250
local MULTI_KILL_TICKS = 4000 // TICK_MS -- Halo's 4 second multi-kill window

------------------------------------------------------------------------------
-- state
local now = 0                 -- ms since the mod loaded, counted by the game-thread loop
local config = { halo_ok = false, test = false }
local models = {}             -- opponent id -> model table written by HaloBridge
local g                       -- current gauntlet, nil when idle

local function emit(ev, arg)
    local f = io.open(RUNTIME .. "/events.log", "a")
    if f then
        f:write(string.format("%d %s%s\n", now, ev, arg and (" " .. tostring(arg)) or ""))
        f:close()
    end
    log("event %s %s", ev, arg or "")
end

local function load_runtime()
    local ok, c = pcall(dofile, RUNTIME .. "/config.lua")
    if ok and type(c) == "table" then config = c else log("no runtime/config.lua (started without HaloBridge?)") end
    for id, _ in pairs(S.opponents) do
        local okm, m = pcall(dofile, RUNTIME .. "/models/" .. id .. ".lua")
        if okm and type(m) == "table" then
            models[id] = m
            log("model %s: %s, %d pieces", id, m.tag, #m.pieces)
        else
            log("model %s not available: %s", id, tostring(m))
        end
    end
end

------------------------------------------------------------------------------
-- small vector / quaternion helpers (UE: X forward, Y right, Z up, cm)
local function v(x, y, z) return { X = x, Y = y, Z = z } end
local function vsub(a, b) return v(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function vadd(a, b) return v(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
local function vscale(a, s) return v(a.X * s, a.Y * s, a.Z * s) end
local function vdot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function vcross(a, b) return v(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
local function vlen(a) return math.sqrt(vdot(a, a)) end
local function vnorm(a) local l = vlen(a); if l < 1e-6 then return v(0, 0, 0) end return vscale(a, 1 / l) end

local function qrot(q, p) -- rotate vector p by unit quaternion q {X,Y,Z,W}
    local u = v(q.X, q.Y, q.Z)
    local t = vscale(vcross(u, p), 2)
    return vadd(vadd(p, vscale(t, q.W)), vcross(u, t))
end
local function qinv(q) return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W } end
local function qfromto(a, b) -- shortest rotation taking direction a to direction b
    a, b = vnorm(a), vnorm(b)
    local d = vdot(a, b)
    if d > 0.99999 then return { X = 0, Y = 0, Z = 0, W = 1 } end
    if d < -0.99999 then
        local axis = vnorm(vcross(a, v(0, 0, 1)))
        if vlen(axis) < 1e-6 then axis = vnorm(vcross(a, v(0, 1, 0))) end
        return { X = axis.X, Y = axis.Y, Z = axis.Z, W = 0 }
    end
    local c = vcross(a, b)
    local q = { X = c.X, Y = c.Y, Z = c.Z, W = 1 + d }
    local l = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    return { X = q.X / l, Y = q.Y / l, Z = q.Z / l, W = q.W / l }
end
local function yawquat(yaw_deg)
    local h = math.rad(yaw_deg) / 2
    return { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) }
end

------------------------------------------------------------------------------
-- game access
local function valid(o) return o ~= nil and o:IsValid() end
local function name_of(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and n or "?"
end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) and valid(pc.Pawn) and pc.Pawn:IsPlayerControlled() then return pc.Pawn, pc end
    end
    return nil
end

local function health(w)
    local ok, h = pcall(function() return w[HOOKS.health] end)
    return ok and h or nil
end

local function first_bone(mesh, names)
    for _, n in ipairs(names) do
        local ok, idx = pcall(function() return mesh:GetBoneIndex(FName(n)) end)
        if ok and idx and idx >= 0 then return n end
    end
    return nil
end

local logged_bones = false
local function log_bones(mesh)
    if logged_bones then return end
    logged_bones = true
    local ok, n = pcall(function() return mesh:GetNumBones() end)
    if not ok then return end
    local names = {}
    for i = 0, n - 1 do names[#names + 1] = mesh:GetBoneName(i):ToString() end
    log("Half Sword fighter bones (%d): %s", n, table.concat(names, ", "))
end

local function bone_world(mesh, name)
    local t = mesh:GetSocketTransform(FName(name), 0) -- RTS_World
    return v(t.Translation.X, t.Translation.Y, t.Translation.Z),
        { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W }
end

------------------------------------------------------------------------------
-- dressing a Half Sword fighter in a Halo 3 model
local procmesh_class, vc_material

local function strip_armor(w)
    -- SDK: Remove Armor(SpawnTransform, Slot, Disable Collision With, out Spawned Armor); the dropped piece is destroyed
    local xf = { Rotation = { W = 1.0, X = 0.0, Y = 0.0, Z = 0.0 }, Translation = v(0, 0, 0), Scale3D = v(1, 1, 1) }
    for slot = 0, 9 do
        pcall(function()
            local out = {}
            w[HOOKS.remove_armor](w, xf, slot, nil, out)
            for _, dropped in pairs(out) do
                if type(dropped) == "userdata" and valid(dropped) then dropped:K2_DestroyActor() end
            end
        end)
    end
end

local function hide_body(w, mesh)
    pcall(function() mesh.VisibilityBasedAnimTickOption = 0 end) -- AlwaysTickPoseAndRefreshBones: keep physics/anim with the mesh hidden
    pcall(function() mesh:SetVisibility(false, false) end)
end

local function dress(w, opp_id)
    local m = models[opp_id]
    if not m then return false, "no model" end
    procmesh_class = procmesh_class or StaticFindObject(HOOKS.procmesh_class)
    if not valid(procmesh_class) then return false, "ProceduralMeshComponent not in this build" end
    vc_material = valid(vc_material) and vc_material or StaticFindObject(HOOKS.vertex_color_material)

    local mesh = w[HOOKS.mesh]
    if not valid(mesh) then return false, "fighter has no Mesh" end
    log_bones(mesh)
    local opp = S.opponents[opp_id]

    -- bone_map rows for this skeleton, resolved against the fighter's real bones
    local map = {}
    for _, row in pairs(S.bone_map) do
        if row.skeleton == opp.skeleton then
            local wb = first_bone(mesh, row.willie_bones)
            if wb then
                map[row.halo_node] = { bone = wb, aim_h = row.aim_halo_child, aim_w = first_bone(mesh, row.aim_willie_child) }
            end
        end
    end
    local pel = map["pelvis"]
    if not pel or not m.nodes["pelvis"] then return false, "no pelvis in bone map" end

    -- scale the Halo model so its pelvis height matches the fighter's
    local pel_w = bone_world(mesh, pel.bone)
    local foot = first_bone(mesh, { "foot_l", "LeftFoot", "foot_r" })
    local floor_z = foot and (bone_world(mesh, foot).Z - 8) or (pel_w.Z - 95)
    local h_pel = m.nodes["pelvis"]
    local s = (pel_w.Z - floor_z) / math.max(1, h_pel[3] - m.min_z)
    local face = yawquat(w:K2_GetActorRotation().Yaw)
    local function halo_world(p) -- Halo model point {x,y,z} -> world, pelvis on pelvis
        return vadd(pel_w, qrot(face, vscale(v(p[1] - h_pel[1], p[2] - h_pel[2], p[3] - h_pel[3]), s)))
    end

    local light = vnorm(v(0.4, 0.3, 0.85))
    local made = 0
    for i, piece in ipairs(m.pieces) do
        local mp = map[piece.node]
        local jn = m.nodes[piece.node]
        if mp and jn then
            local bpos, brot = bone_world(mesh, mp.bone)
            local j_h = halo_world(jn)
            local turn = { X = 0, Y = 0, Z = 0, W = 1 }
            if mp.aim_w and mp.aim_h ~= piece.node and m.nodes[mp.aim_h] then
                local dir_h = vsub(halo_world(m.nodes[mp.aim_h]), j_h)
                local dir_w = vsub(bone_world(mesh, mp.aim_w), bpos)
                turn = qfromto(dir_h, dir_w)
            end
            local inv = qinv(brot)
            local verts, colors, world = {}, {}, {}
            local vs = piece.verts
            for k = 1, #vs, 3 do
                local wp = vadd(bpos, qrot(turn, vsub(halo_world({ vs[k], vs[k + 1], vs[k + 2] }), j_h)))
                world[#world + 1] = wp
                verts[#verts + 1] = qrot(inv, vsub(wp, bpos))
            end
            -- flat tint, shaded per vertex from face normals (the material is unlit vertex colour)
            local shade = {}
            local t = piece.tris
            for k = 1, #t, 3 do
                local a, b, c = world[t[k] + 1], world[t[k + 1] + 1], world[t[k + 2] + 1]
                local n = vnorm(vcross(vsub(c, a), vsub(b, a)))
                for _, idx in ipairs({ t[k], t[k + 1], t[k + 2] }) do
                    shade[idx] = (shade[idx] or 0) + math.max(0, vdot(n, light))
                end
            end
            for k = 1, #verts do
                local f = 0.45 + 0.55 * math.min(1, shade[k - 1] or 0.5)
                colors[k] = { R = m.tint[1] * f, G = m.tint[2] * f, B = m.tint[3] * f, A = 1.0 }
            end
            local ok, err = pcall(function()
                local comp = w:AddComponentByClass(procmesh_class, false, { Rotation = { W = 1, X = 0, Y = 0, Z = 0 }, Translation = v(0, 0, 0), Scale3D = v(1, 1, 1) }, false)
                -- UE5: (Section, Vertices, Triangles, Normals, UV0, UV1, UV2, UV3, VertexColors, Tangents, bCreateCollision, bSRGBConversion)
                local okm = pcall(function() comp:CreateMeshSection_LinearColor(0, verts, t, {}, {}, {}, {}, {}, colors, {}, false, false) end)
                if not okm then -- UE4 signature, in case this build differs
                    comp:CreateMeshSection_LinearColor(0, verts, t, {}, {}, colors, {}, false)
                end
                if valid(vc_material) then comp:SetMaterial(0, vc_material) end
                comp:SetCollisionEnabled(0)
                comp:K2_AttachToComponent(mesh, FName(mp.bone), 2, 2, 2, false) -- SnapToTarget: verts are bone-local
            end)
            if ok then made = made + 1 else log("piece %d (%s) failed: %s", i, piece.node, tostring(err)) end
        end
    end
    if made == 0 then return false, "no pieces attached" end
    if opp.strip_armor then strip_armor(w) end
    if opp.hide_host_body then hide_body(w, mesh) end
    return true, string.format("%d pieces", made)
end

------------------------------------------------------------------------------
-- status file: what the gauntlet is doing, in words (runtime/status.txt, rewritten as it changes)
local status_lines = {}
local function status(key, text)
    if status_lines[key] == text then return end
    status_lines[key] = text
    log("%s: %s", key, text)
    local keys = {}
    for k in pairs(status_lines) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(RUNTIME .. "/status.txt", "w")
    if f then
        for _, k in ipairs(keys) do f:write(k, ": ", status_lines[k], "\n") end
        f:close()
    end
end

------------------------------------------------------------------------------
-- where we are: Free play, on an arena map
local function level_name(pawn)
    local lvl = ""
    pcall(function() lvl = UEHelpers.GetGameplayStatics():GetCurrentLevelName(pawn, true):ToString() end)
    return lvl
end

local function free_play_flag()
    local gi
    pcall(function() gi = FindFirstOf(HOOKS.game_instance_class) end)
    if not valid(gi) then return nil end
    for _, name in ipairs({ HOOKS.free_mode_flag, (HOOKS.free_mode_flag:gsub(" ", "_")) }) do
        local ok, val = pcall(function() return gi[name] end)
        if ok and type(val) == "boolean" then return val end
    end
    return nil
end

local function in_free_play_arena(pawn)
    local lvl = level_name(pawn)
    local arena = lvl:sub(1, #HOOKS.arena_level_prefix) == HOOKS.arena_level_prefix
    local free = free_play_flag()
    status("mode", string.format("level %s, arena=%s, free play=%s", lvl, tostring(arena), tostring(free)))
    return arena and free ~= false
end

------------------------------------------------------------------------------
-- fighters
local function team_of(w)
    local ok, t = pcall(function() return w[HOOKS.team] end)
    return (ok and type(t) == "number") and t or nil
end

local function alive(w)
    local h = health(w)
    return valid(w) and h ~= nil and h > 0
end

-- every living fighter that is not on the player's team
local function foes(pawn)
    local r = {}
    local pt = team_of(pawn)
    for _, w in pairs(FindAllOf("Willie_BP_C") or {}) do
        if valid(w) and not same(w, pawn) and alive(w) and not w:IsPlayerControlled() then
            local t = team_of(w)
            if pt == nil or t == nil or t ~= pt then r[#r + 1] = w end
        end
    end
    return r
end

local function is_ours(w)
    if not g then return false end
    for _, a in ipairs(g.all) do
        if same(a, w) then return true end
    end
    return false
end

local function adopt(w, opp_id)
    local f = { actor = w, id = opp_id, dressed = false, dead = false, born = now }
    table.insert(g.fighters, f)
    table.insert(g.all, w)
    log("wave %d: %s joins as %s", g.wave, name_of(w), opp_id)
end

-- wave 2+ : the arena's own spawner, so fighters get the game's full character setup
local function spawn_with_spawner(pawn, count)
    local spawners = FindAllOf(HOOKS.spawner_class) or {}
    local best
    for _, s in pairs(spawners) do
        local ok, is_player = pcall(function() return s[HOOKS.spawner_is_player] end)
        if valid(s) and not (ok and is_player == true) then best = best or s end
    end
    if not best then return false, "no " .. HOOKS.spawner_class .. " in this arena" end
    local ok, err = pcall(function() best[HOOKS.spawner_fn](best, count) end)
    if not ok then return false, tostring(err) end
    return true, name_of(best)
end

-- fallback: deferred spawn of the player's own fighter class, as Half Sword Enhancer does
local function spawn_fallback(pawn, count)
    local gs = UEHelpers.GetGameplayStatics()
    local cls = pawn:GetClass()
    local loc = pawn:K2_GetActorLocation()
    local yaw = pawn:K2_GetActorRotation().Yaw
    for i = 1, count do
        local a = math.rad(yaw + (i - (count + 1) / 2) * 25)
        local at = v(loc.X + math.cos(a) * 700, loc.Y + math.sin(a) * 700, loc.Z + 50)
        local xf = { Rotation = yawquat(yaw + 180), Translation = at, Scale3D = v(1, 1, 1) }
        local ok, err = pcall(function()
            local w = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 2, nil, 0) -- AdjustIfPossibleButAlwaysSpawn
            if valid(w) then
                local pt = team_of(pawn) or 0
                pcall(function() w[HOOKS.team] = pt + 1 end)
                gs:FinishSpawningActor(w, xf, 0)
            end
        end)
        if not ok then return false, tostring(err) end
    end
    return true, "deferred spawn"
end

local function start_wave(pawn)
    g.wave = g.wave + 1
    g.fighters = {}
    local row = S.waves[g.wave]
    g.want = row.opponents
    emit("WAVE_START", g.wave)
    if row.source == "arena" then
        g.claim_until = now + 8000 -- Free play's own opening fighters
    else
        local ok, how = spawn_with_spawner(pawn, #row.opponents)
        if not ok then
            status("spawner", "unavailable (" .. how .. "), using fallback spawn")
            ok, how = spawn_fallback(pawn, #row.opponents)
        end
        status("wave" .. g.wave, ok and ("spawned via " .. how) or ("spawn failed: " .. how))
        g.claim_until = now + 6000
    end
end

-- give every unclaimed foe a Covenant role: the wave's list first, extra arena fighters become Elites
local function claim(pawn)
    for _, w in ipairs(foes(pawn)) do
        if not is_ours(w) then
            local idx = #g.fighters + 1
            local id = g.want[idx] or "elite"
            adopt(w, id)
        end
    end
end

local function start_gauntlet(reason)
    g = { wave = 0, fighters = {}, all = {}, want = {}, kills = 0, chain = 0, last_kill = -100000, player_died = false, claim_until = 0 }
    status("gauntlet", "started (" .. reason .. ")")
end

local function on_kill(f)
    f.dead = true
    g.kills = g.kills + 1
    if now - g.last_kill <= MULTI_KILL_TICKS * TICK_MS then g.chain = g.chain + 1 else g.chain = 1 end
    g.last_kill = now
    emit("KILL", f.id)
    if g.chain == 2 then emit("MULTI_2") elseif g.chain == 3 then emit("MULTI_3") end
end

local test_kill_after = 4000 -- test mode: each fighter is finished off this long after it appears

local function tick()
    now = now + TICK_MS
    local pawn = player_pawn()
    if not pawn then return end

    if not g then
        if now >= (config.idle_until or 0) then
            config.idle_until = now + 2000
            if in_free_play_arena(pawn) and alive(pawn) then start_gauntlet("Free play arena") end
        end
        return
    end
    if g.done then return end

    if not alive(pawn) and not g.player_died then
        g.player_died = true
        g.done = true
        emit("DEFEAT")
        status("gauntlet", "lost in wave " .. g.wave)
        return
    end

    if g.wave == 0 then start_wave(pawn) end
    if now <= g.claim_until then claim(pawn) end

    for _, f in ipairs(g.fighters) do
        if not f.dead then
            if not valid(f.actor) then
                on_kill(f)
            else
                if not f.dressed and now - f.born >= 500 then
                    f.dressed = true
                    local ok, msg = dress(f.actor, f.id)
                    status("dress " .. f.id, (ok and "ok: " or "FAILED: ") .. tostring(msg))
                    local opp = S.opponents[f.id]
                    if opp.health_mult ~= 1.0 then
                        pcall(function() f.actor[HOOKS.health] = f.actor[HOOKS.health] * opp.health_mult end)
                    end
                end
                if config.test and now - f.born >= test_kill_after then
                    pcall(function()
                        f.actor[HOOKS.health] = -1.0
                        f.actor[HOOKS.death_fn](f.actor)
                    end)
                end
                local h = health(f.actor)
                if h and h <= 0 then on_kill(f) end
            end
        end
    end

    local cleared = #g.fighters > 0 and (#g.fighters >= #g.want or now > g.claim_until)
    for _, f in ipairs(g.fighters) do
        if not f.dead then cleared = false end
    end
    if now > g.claim_until and #g.fighters == 0 then
        status("wave" .. g.wave, "no fighters appeared")
        g.claim_until = now + 4000 -- keep looking; Free play may still be spawning
        return
    end
    if not cleared then return end

    if g.wave >= S.wave_count then
        if g.kills >= 4 and not g.player_died then emit("SPREE") end
        emit("VICTORY")
        status("gauntlet", "won")
        g.done = true
        return
    end
    if not g.next_at then
        g.next_at = now + S.waves[g.wave + 1].delay_s * 1000
    elseif now >= g.next_at then
        g.next_at = nil
        start_wave(pawn)
    end
end

------------------------------------------------------------------------------
load_runtime()
local f = io.open(RUNTIME .. "/events.log", "a")
if f then f:close() end
emit("READY")
status("halo", config.halo_ok and "Halo files read by HaloBridge" or "HaloBridge did not run or could not read Halo (start from Melty)")
for id, _ in pairs(S.opponents) do
    status("model " .. id, models[id] and (#models[id].pieces .. " pieces from " .. models[id].tag) or "missing (see runtime/bridge.log)")
end

-- a new level (or Free play restarting the fight) starts a new gauntlet
local last_pawn_addr
RegisterHook(HOOKS.restart_hook, function()
    local pawn = player_pawn()
    local addr = valid(pawn) and pawn:GetAddress() or nil
    if addr ~= last_pawn_addr then
        if g then log("new level or respawn: gauntlet reset") end
        g = nil
        config.idle_until = now + 3000
        last_pawn_addr = addr
    end
end)

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local pawn = player_pawn()
        if pawn and in_free_play_arena(pawn) then start_gauntlet("F7") end
    end)
end)

LoopInGameThreadWithDelay(TICK_MS, function()
    local ok, err = pcall(tick)
    if not ok then log("tick error: %s", tostring(err)) end
end)

log("loaded from %s (halo_ok=%s, test=%s)", MOD, tostring(config.halo_ok), tostring(config.test))
