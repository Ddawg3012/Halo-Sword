-- Offline harness: runs mod/HaloSword/Scripts/main.lua against a fake UE4SS/Half Sword so the gauntlet rules,
-- events and the model-fitting maths can be checked without the game. It proves the script's logic only;
-- every engine call it fakes still has to be confirmed in the real game (design/verification.json).
--   lua5.4 tests/harness.lua <copy of mod/HaloSword>      (tests/run.sh makes the copy)
local MODDIR = arg[1]
local RUNTIME = os.getenv("LOCALAPPDATA") .. "/HaloSword/runtime"
package.path = MODDIR .. "/Scripts/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    io.write((cond and "PASS " or "FAIL ") .. msg .. "\n")
    if not cond then failures = failures + 1 end
end

-- fake UObject ---------------------------------------------------------------
local next_addr = 1000
local function obj(fields)
    next_addr = next_addr + 1
    local o = fields or {}
    o.__addr = next_addr
    o.__valid = true
    o.IsValid = function(self) return self.__valid end
    o.GetAddress = function(self) return self.__addr end
    return o
end
local function fname_str(n) return type(n) == "table" and n.s or n end

local bones = { "root", "pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head",
    "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l", "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
    "thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r" }
local bone_pos = { root = { 0, 0, 0 }, pelvis = { 0, 0, 95 }, spine_01 = { 0, 0, 105 }, spine_02 = { 0, 0, 118 }, spine_03 = { 0, 0, 132 },
    neck_01 = { 0, 0, 150 }, head = { 0, 0, 160 }, clavicle_l = { 0, -5, 145 }, upperarm_l = { 0, -18, 145 }, lowerarm_l = { 0, -22, 118 },
    hand_l = { 0, -24, 92 }, clavicle_r = { 0, 5, 145 }, upperarm_r = { 0, 18, 145 }, lowerarm_r = { 0, 22, 118 }, hand_r = { 0, 24, 92 },
    thigh_l = { 0, -10, 92 }, calf_l = { 0, -11, 50 }, foot_l = { 0, -11, 8 }, thigh_r = { 0, 10, 92 }, calf_r = { 0, 11, 50 }, foot_r = { 0, 11, 8 } }

local world_actors = {}
destroyed = 0
local attached = {}

local function make_willie(loc, player, team)
    local w = obj({ Health = 100.0, ["Team Int"] = team or 0, __loc = loc, __player = player })
    w.Mesh = obj({
        VisibilityBasedAnimTickOption = 3,
        GetBoneIndex = function(_, n) for i, b in ipairs(bones) do if b == fname_str(n) then return i - 1 end end return -1 end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) return { ToString = function() return bones[i + 1] end } end,
        GetSocketTransform = function(_, n, _)
            local p = bone_pos[fname_str(n)]
            return { Translation = { X = w.__loc.X + p[1], Y = w.__loc.Y + p[2], Z = w.__loc.Z + p[3] - 95 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
        end,
        SetVisibility = function(self, vis) self.__visible = vis end,
    })
    w.IsPlayerControlled = function() return player end
    w.K2_GetActorLocation = function() return w.__loc end
    w.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
    w.K2_DestroyActor = function(self) self.__valid = false; destroyed = destroyed + 1 end
    w.GetFullName = function() return "Willie_BP_C /Game/Map_Arena_Pit.Willie_" .. w.__addr end
    w.GetClass = function() return obj({}) end
    w.GetWorld = function() return _G.__world end
    w.Death = function(self) self.Health = -1 end
    w["Remove Armor"] = function() end
    w.AddComponentByClass = function()
        local c = obj({})
        c.CreateMeshSection_LinearColor = function(_, sec, verts, tris, n, uv0, uv1, uv2, uv3, colors, tangents, coll, srgb)
            assert(type(srgb) == "boolean", "UE5 signature: 12 arguments")
            assert(#tris % 3 == 0, "triangles not a multiple of 3")
            for _, t in ipairs(tris) do assert(t >= 0 and t < #verts, "triangle index out of range") end
            assert(#colors == #verts, "one colour per vertex")
            c.__verts = verts
        end
        c.SetMaterial = function() end
        c.SetCollisionEnabled = function() end
        c.K2_AttachToComponent = function(_, parent, bone) attached[#attached + 1] = { comp = c, bone = fname_str(bone), owner = w } end
        return c
    end
    world_actors[#world_actors + 1] = w
    return w
end

local player = make_willie({ X = 0, Y = 0, Z = 95 }, true, 0)
local native = make_willie({ X = 500, Y = 0, Z = 95 }, false, 1) -- the fighter Free play spawned on its own
local spawner_calls = 0
local spawner = obj({ ["Spawn Player"] = false })
spawner["Spawn Willies"] = function(_, n)
    spawner_calls = spawner_calls + 1
    for i = 1, n do make_willie({ X = 600, Y = i * 100, Z = 95 }, false, 1) end
end
local player_spawner = obj({ ["Spawn Player"] = true })
player_spawner["Spawn Willies"] = function() error("player spawner must not be used") end
local level = "Map_Arena_Pit"
local gi = obj({ ["Free Mode Activated"] = true })
local pc = obj({ Pawn = player })

local loop_fn, hooks, keys = nil, {}, {}
_G.print = function(s) io.write(s) end
_G.FName = function(s) return { s = s } end
_G.FindAllOf = function(cls)
    if cls == "PlayerController" then return { pc } end
    if cls == "Willie_BP_C" then return world_actors end
    if cls == "BP_SpawnerPoint_Willies_C" then return { player_spawner, spawner } end
end
_G.FindFirstOf = function(cls)
    if cls == "GI_Settings_C" then return gi end
end
_G.StaticFindObject = function(path) return obj({ path = path }) end
_G.LoadAsset = function(path) return obj({ path = path }) end
_G.RegisterHook = function(name, fn) hooks[name] = fn end
_G.RegisterKeyBind = function(k, fn) keys[k] = fn end
_G.Key = { F7 = "F7" }
_G.ExecuteInGameThread = function(fn) fn() end
_G.LoopInGameThreadWithDelay = function(ms, fn) loop_fn = fn end
package.loaded["UEHelpers"] = { GetGameplayStatics = function() return { GetCurrentLevelName = function() return { ToString = function() return level end } end } end }

-- fake runtime written by HaloBridge -------------------------------------------
os.execute("mkdir -p '" .. RUNTIME .. "/models'")
local cf = io.open(RUNTIME .. "/config.lua", "w"); cf:write('return { halo = "reading", test = false }'); cf:close()
-- a crude two-box "model" per opponent with Halo node names, in UE axes/cm, standing on z = 0
local function box(cx, cy, cz, sx, sy, sz, base)
    local vs, ts = {}, {}
    for _, dx in ipairs({ -1, 1 }) do for _, dy in ipairs({ -1, 1 }) do for _, dz in ipairs({ -1, 1 }) do
        vs[#vs + 1] = string.format("%g,%g,%g", cx + dx * sx, cy + dy * sy, cz + dz * sz)
    end end end
    local quads = { { 0, 1, 3, 2 }, { 4, 6, 7, 5 }, { 0, 4, 5, 1 }, { 2, 3, 7, 6 }, { 0, 2, 6, 4 }, { 1, 5, 7, 3 } }
    for _, q in ipairs(quads) do ts[#ts + 1] = string.format("%d,%d,%d,%d,%d,%d", q[1], q[2], q[3], q[1], q[3], q[4]) end
    return table.concat(vs, ","), table.concat(ts, ",")
end
local function write_models()
for _, id in ipairs({ "elite", "brute" }) do
    local f = io.open(RUNTIME .. "/models/" .. id .. ".lua", "w")
    local tv, tt = box(0, 0, 150, 20, 25, 40)
    local lv, lt = box(0, -12, 60, 8, 8, 50)
    f:write(string.format([[return { id = "%s", tag = [[test\%s]] .. "]]" .. [[, min_z = 0, max_z = 240, pelvis_z = 110, tint = {0.2,0.3,0.6},
  nodes = { ["pelvis"] = {0,0,110}, ["spine"] = {0,0,130}, ["spine1"] = {0,0,160}, ["l_thigh"] = {0,-12,105}, ["l_calf"] = {0,-12,55} },
  pieces = { { node = "spine", verts = {%s}, tris = {%s} }, { node = "l_thigh", verts = {%s}, tris = {%s} } } }]], id, id, tv, tt, lv, lt))
    f:close()
end
end
local ef = io.open(RUNTIME .. "/events.log", "w"); ef:close()

-- run -----------------------------------------------------------------------
dofile(MODDIR .. "/Scripts/main.lua")
check(loop_fn ~= nil, "mod registers its game-thread loop")
check(hooks["/Script/Engine.PlayerController:ClientRestart"] ~= nil, "mod hooks ClientRestart")

local function ticks(n) for _ = 1, n do loop_fn() end end
local function ours() local r = {} for _, a in ipairs(world_actors) do if a ~= player and a.__valid and a.Health > 0 then r[#r + 1] = a end end return r end

-- Progression first: nothing may happen there
gi["Free Mode Activated"] = false
level = "Map_Arena_Yard"
ticks(30)
check(#attached == 0 and spawner_calls == 0, "Progression: no gauntlet, no Halo models, nothing spawned")
check(native.__valid, "Progression: the arena's fighter is left alone")
gi["Free Mode Activated"] = true
level = "Map_Arena_Pit"

ticks(12)
check(#attached == 0, "before HaloBridge has read the models, the Elite waits undressed")
write_models() -- HaloBridge finishes reading MCC while the fight is already on
ticks(12)
local w1 = ours()
check(#w1 == 1 and w1[1] == native, "wave 1: the fighter Free play spawned is the Elite (" .. #w1 .. ")")
check(native.__valid, "the arena's own fighter is never removed")
check(#attached > 0 and attached[#attached].owner == w1[1], "Elite is dressed in Halo pieces attached to its bones")
check(w1[1].Mesh.__visible == false, "the Half Sword body under the Elite is hidden")
local spine_piece
for _, a in ipairs(attached) do if a.bone == "spine_01" then spine_piece = a end end
check(spine_piece ~= nil, "the Halo 'spine' piece rides the fighter's spine_01 bone")
do
    local vs, c = spine_piece.comp.__verts, { X = 0, Y = 0, Z = 0 }
    for _, p in ipairs(vs) do c.X, c.Y, c.Z = c.X + p.X / #vs, c.Y + p.Y / #vs, c.Z + p.Z / #vs end
    local d = math.sqrt(c.X ^ 2 + c.Y ^ 2 + c.Z ^ 2)
    check(d < 60, string.format("the torso piece sits on its bone (centre %.1f cm from spine_01)", d))
end

w1[1].Health = -1 ; ticks(1)
ticks(40)
local w2 = ours()
check(#w2 == 2 and spawner_calls == 1, "wave 2: the arena's spawner sends two Elites (" .. #w2 .. ")")
w2[1].Health = -1 ; ticks(2) ; w2[2].Health = -1 ; ticks(1)
ticks(40)
local w3 = ours()
check(#w3 == 1, "wave 3 sends one Brute (" .. #w3 .. ")")
check(w3[1].Health > 100, "the Brute is tougher (health " .. w3[1].Health .. ")")
w3[1].Health = -1 ; ticks(2)

local evs = {}
for line in io.lines(RUNTIME .. "/events.log") do evs[#evs + 1] = line:match("^%d+ (%S+)") end
local seq = table.concat(evs, " ")
io.write("events: " .. seq .. "\n")
check(seq == "READY WAVE_START KILL WAVE_START KILL KILL MULTI_2 WAVE_START KILL SPREE VICTORY", "event sequence for a clean run")

-- every event the mod wrote is one the sheets define
local S = require("sheets_gen")
local known = {}
for id in pairs(S.events) do known[id] = true end
local all_known = true
for _, e in ipairs(evs) do if not known[e] then all_known = false end end
check(all_known, "every event written is in the events sheet")
check(destroyed == 0, "no fighter was ever destroyed by the mod")

-- defeat path: a new Free play fight (new player pawn)
player.__valid = false
player = make_willie({ X = 0, Y = 0, Z = 95 }, true, 0)
pc.Pawn = player
make_willie({ X = 500, Y = 0, Z = 95 }, false, 1)
hooks["/Script/Engine.PlayerController:ClientRestart"]()
ticks(30)
player.Health = -5 ; ticks(1)
local last
for line in io.lines(RUNTIME .. "/events.log") do last = line:match("^%d+ (%S+)") end
check(last == "DEFEAT", "player death during the gauntlet announces DEFEAT")

io.write((failures == 0 and "ALL PASS" or (failures .. " FAILED")) .. "\n")
os.exit(failures == 0 and 0 or 1)
