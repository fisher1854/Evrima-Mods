--[[
  Teno / Galli AI herd for carnivore food (demand-driven, soft ecology).

  Ecosystem completely hardened against memory bleeding and asset overrides.
  Target limits scale dynamically based on player presence, immune to 0 caps.
]]

-- 1. ADAPTIVE ECOLOGY & FLOATING ZONES HARD-DISABLED
adaptiveEcologyEnabled = false
useDynamicFloatingZones = false
print("[AI HERD DEBUG] ai.lua loaded")
AI_HERD_PATH = SAVED_DIR .. "/ai_herd.json"
AI_HERD = {
    enabled = true,
    targetTeno = 0,
    targetDibble = 12,
    targetGalli = 12,

    -- Legacy aliases kept for old status/inbox paths.
    capTeno = 0,
    capDibble = 12,
    capGalli = 12,

    stabilityCeiling = 40,
    perCarniTeno = 0,
    perCarniDibble = 2,
    perCarniGalli = 1,
  
    growthMin = 0.40,
    growthMax = 0.55,
    spawnMin = 10000,   -- 100m
    spawnMax = 30000,  -- 300m
    playerClear = 6000,
    herbClear = 20000,
    herdClear = 8000,
    fillGap = 240,
    deathGap = 300,
    bootWait = 90,
    callsMode = "spawn",
    callGap = 240,
    callGapPop = 15,
    callHearUU = 25000,
    callMagnitude = 1.0,
    callsEnabled = true,
    spawnMinGap = 60,
    lastSpawnAttemptClock = 0,
    nextSpawnAllowedClock = 0,
    consecutiveSpawnFailures = 0,
    emergencyDisabledUntil = 0,
    pollGap = 30,
    nextPollAt = 0,
    allowDibble = true,
    cullWhenDisabled = true,
    requirePreyProximity = true, 
    preyArmPaddingUU = 20000, 
    proxCacheSec = 20,
    proxDisarmCullSec = 300,
    proxArmed = false,
    proxArmedCount = 0,
    proxArmedAnchors = {},
    nextProxAt = 0,
    proxDisarmedSince = 0,
    nextSpawnAt = 0,
    loadedAt = os.time(),
    nextTenoAt = 0,
    nextDibbleAt = 0,
    nextGalliAt = 0,
    nextCfgAt = 0,
    nextCallAt = 0,
    nextCullAt = 0,
    nextWipeAt = 0,
    lastTeno = 0,
    lastDibble = 0,
    lastGalli = 0,
    blacklistGridUU = 1000,
    blacklistTtlSec = 600,
    idleMoveMinUU = 150,
    idleCullSec = 600,
    wipeGap = 1800,
    announced = false,
    tracked = {},
    lastSweepCounts = { teno = 0, dibble = 0, galli = 0 },
    pendingTrackedAdds = {},
    respawnQueue = {},
    biasRegions = {},
    world = nil,
    pawnCls = {},
    ctrlCls = {},
    kismet = nil,
}
AI_SPAWN_TELEMETRY = AI_SPAWN_TELEMETRY or {
    attempts = 0,
    success = 0,
    deaths = 0,
    respawns = 0,
    avg_health = 0,
    avg_food = 0,
    avg_thirst = 0,
    health_samples = 0,
    food_samples = 0,
    thirst_samples = 0,
    health_sum = 0,
    food_sum = 0,
    thirst_sum = 0,
    culled_idle = 0,
    pending_respawns = 0,
    collision = 0,
    bad_ground = 0,
    bad_address = 0,
    other = 0,
    by_kind = {},
    last = nil,
}
AI_SPAWN_BLACKLIST = AI_SPAWN_BLACKLIST or {}
AI_SPAWN_CRASH_SITES = AI_SPAWN_CRASH_SITES or {}
AI_SPAWN_SITE_FAILURES = AI_SPAWN_SITE_FAILURES or {}
if type(AI_SPAWN_CRASH_SITES) ~= "table" then AI_SPAWN_CRASH_SITES = {} end
if type(AI_SPAWN_SITE_FAILURES) ~= "table" then AI_SPAWN_SITE_FAILURES = {} end

function aiRecordCrashSite(x, y, z, reason, now)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x == nil or y == nil or z == nil or (x == 0 and y == 0 and z == 0) then return end
    now = tonumber(now) or os.time()
    local key = aiBlacklistGridKey(x, y)
    local sites = AI_SPAWN_CRASH_SITES
    for i = #sites, 1, -1 do
        local site = sites[i]
        if type(site) ~= "table" or (tonumber(site.expiresAt) or 0) <= now then
            table.remove(sites, i)
        elseif site.key == key then
            table.remove(sites, i)
        end
    end
    table.insert(sites, 1, {
        key = key, x = x, y = y, z = z,
        reason = tostring(reason or "spawn failure"),
        expiresAt = now + 300,
    })
    while #sites > 10 do table.remove(sites) end
end

function aiIsCrashSiteDisabled(x, y, now)
    now = tonumber(now) or os.time()
    local key = aiBlacklistGridKey(x, y)
    for i = #AI_SPAWN_CRASH_SITES, 1, -1 do
        local site = AI_SPAWN_CRASH_SITES[i]
        if type(site) ~= "table" or (tonumber(site.expiresAt) or 0) <= now then
            table.remove(AI_SPAWN_CRASH_SITES, i)
        elseif site.key == key then
            return true
        end
    end
    return false
end

function aiSpawnLog(kind, step, detail)
    pcall(function()
        log(string.format("ai spawn step=%s kind=%s detail=%s",
            tostring(step or "unknown"), tostring(kind or "unknown"), tostring(detail or "ok")))
    end)
end

-- Shared classifier for possession/controller-spawn failure messages, used
-- both to decide whether to add a site to the exponential backoff/blacklist
-- tracking (aiRecordSpawnTelemetry) and to decide the retry backoff severity
-- in aiPollHerdUnsafe. Kept in one place so the two call sites can't drift
-- out of sync if the failure message wording ever changes.
function aiIsPossessFailureMsg(msg)
    if type(msg) ~= "string" then return false end
    return msg:find("possess failed", 1, true) ~= nil
        or msg:find("controller spawn failed", 1, true) ~= nil
end

function aiEnsureKindTelemetry(kind)
    AI_SPAWN_TELEMETRY.by_kind[kind] = AI_SPAWN_TELEMETRY.by_kind[kind] or {
        attempts = 0,
        success = 0,
        deaths = 0,
        respawns = 0,
        avg_health = 0,
        avg_food = 0,
        avg_thirst = 0,
        health_samples = 0,
        food_samples = 0,
        thirst_samples = 0,
        health_sum = 0,
        food_sum = 0,
        thirst_sum = 0,
        culled_idle = 0,
        pending_respawns = 0,
        collision = 0,
        bad_ground = 0,
        other = 0
    }
    return AI_SPAWN_TELEMETRY.by_kind[kind]
end

function aiBlacklistGridKey(x, y)
    local grid = math.max(250, math.floor(tonumber(AI_HERD.blacklistGridUU) or 1000))
    local fx = (tonumber(x) or 0) / grid
    local fy = (tonumber(y) or 0) / grid
    local gx = (fx >= 0) and math.floor(fx + 0.5) or math.ceil(fx - 0.5)
    local gy = (fy >= 0) and math.floor(fy + 0.5) or math.ceil(fy - 0.5)
    return tostring(gx) .. ":" .. tostring(gy), gx, gy, grid
end

function aiPruneSpawnBlacklist(now)
    now = tonumber(now) or os.time()
    local active = 0
    -- TTL expiry: each blacklisted cell self-expires after blacklistTtlSec (5-10 minutes).
    for key, row in pairs(AI_SPAWN_BLACKLIST or {}) do
        if row == nil or (tonumber(row.expiresAt) or 0) <= now then
            AI_SPAWN_BLACKLIST[key] = nil
        else
            active = active + 1
        end
    end
    return active
end

function aiAddSpawnBlacklist(x, y, z, outcome, now)
    now = tonumber(now) or os.time()
    local ttl = math.max(300, math.min(600, math.floor(tonumber(AI_HERD.blacklistTtlSec) or 600)))
    local key, gx, gy, grid = aiBlacklistGridKey(x, y)
    local previous = AI_SPAWN_SITE_FAILURES[key]
    local failures = type(previous) == "table" and now - (tonumber(previous.lastFailureAt) or 0) <= 3600
        and ((tonumber(previous.failures) or 0) + 1) or 1
    local backoffSeconds = math.min(300, 30 * (2 ^ math.min(failures - 1, 4)))
    AI_SPAWN_SITE_FAILURES[key] = { failures = failures, backoffSeconds = backoffSeconds, lastFailureAt = now }
    -- Timestamped cell blacklist prevents immediate retries on collision/bad ground spots.
    AI_SPAWN_BLACKLIST[key] = {
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
        z = tonumber(z) or 0,
        gx = gx,
        gy = gy,
        grid = grid,
        outcome = tostring(outcome or "collision"),
        failures = failures,
        backoffSeconds = backoffSeconds,
        at = now,
        expiresAt = now + ttl,
    }
end

function aiIsSpawnBlacklisted(x, y, now)
    now = tonumber(now) or os.time()
    local key = aiBlacklistGridKey(x, y)
    local row = AI_SPAWN_BLACKLIST[key]
    if row == nil then
        return false
    end
    if (tonumber(row.expiresAt) or 0) <= now then
        AI_SPAWN_BLACKLIST[key] = nil
        return false
    end
    return true
end

function aiReadVitals(pawn)
    if not aiObjOk(pawn) then return nil, nil, nil end
    local health = nil
    local food = nil
    local thirst = nil
    if type(tryNumber) == "function" then
        health = tryNumber(pawn, { "GetHealth", "Health", "GetCurrentHealth", "CurrentHealth" })
        food = tryNumber(pawn, { "GetFood", "Food", "GetCurrentFoodValue", "CurrentFoodValue", "FoodValue" })
        thirst = tryNumber(pawn, { "GetThirst", "Thirst", "GetCurrentThirst", "CurrentThirst" })
    end
    if health == nil then pcall(function() health = pawn:GetHealth() end) end
    if food == nil then pcall(function() food = pawn:GetFood() end) end
    if thirst == nil then pcall(function() thirst = pawn:GetThirst() end) end
    return tonumber(health), tonumber(food), tonumber(thirst)
end

function aiRecordVitals(kind, health, food, thirst)
    kind = tostring(kind or "unknown")
    local k = aiEnsureKindTelemetry(kind)
    local t = AI_SPAWN_TELEMETRY
    local h = tonumber(health)
    local f = tonumber(food)
    local th = tonumber(thirst)
    if h ~= nil then
        t.health_sum = (t.health_sum or 0) + h
        t.health_samples = (t.health_samples or 0) + 1
        k.health_sum = (k.health_sum or 0) + h
        k.health_samples = (k.health_samples or 0) + 1
        t.avg_health = (t.health_sum or 0) / math.max(1, t.health_samples or 1)
        k.avg_health = (k.health_sum or 0) / math.max(1, k.health_samples or 1)
    end
    if f ~= nil then
        t.food_sum = (t.food_sum or 0) + f
        t.food_samples = (t.food_samples or 0) + 1
        k.food_sum = (k.food_sum or 0) + f
        k.food_samples = (k.food_samples or 0) + 1
        t.avg_food = (t.food_sum or 0) / math.max(1, t.food_samples or 1)
        k.avg_food = (k.food_sum or 0) / math.max(1, k.food_samples or 1)
    end
    if th ~= nil then
        t.thirst_sum = (t.thirst_sum or 0) + th
        t.thirst_samples = (t.thirst_samples or 0) + 1
        k.thirst_sum = (k.thirst_sum or 0) + th
        k.thirst_samples = (k.thirst_samples or 0) + 1
        t.avg_thirst = (t.thirst_sum or 0) / math.max(1, t.thirst_samples or 1)
        k.avg_thirst = (k.thirst_sum or 0) / math.max(1, k.thirst_samples or 1)
    end
end

function aiRecomputePendingRespawns()
    local total = 0
    for _, row in pairs(AI_SPAWN_TELEMETRY.by_kind or {}) do
        total = total + math.max(0, math.floor(tonumber((row or {}).pending_respawns) or 0))
    end
    AI_SPAWN_TELEMETRY.pending_respawns = total
end

function aiQueueDeathForRespawn(species)
    AI_SPAWN_TELEMETRY.deaths = (AI_SPAWN_TELEMETRY.deaths or 0) + 1
    local byKind = aiEnsureKindTelemetry(species)
    byKind.deaths = (byKind.deaths or 0) + 1
    byKind.pending_respawns = (byKind.pending_respawns or 0) + 1
    AI_HERD.respawnQueue[species] = (AI_HERD.respawnQueue[species] or 0) + 1
end

function aiRecordSpawnTelemetry(kind, outcome, msg, x, y, z)
    kind = tostring(kind or "unknown")
    outcome = tostring(outcome or "other")
    msg = tostring(msg or "")
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    z = tonumber(z) or 0

    AI_SPAWN_TELEMETRY.attempts = (AI_SPAWN_TELEMETRY.attempts or 0) + 1
    local byKind = aiEnsureKindTelemetry(kind)
    byKind.attempts = byKind.attempts + 1

    if outcome == "success" then
        AI_SPAWN_TELEMETRY.success = AI_SPAWN_TELEMETRY.success + 1
        byKind.success = byKind.success + 1
    elseif outcome == "collision" then
        AI_SPAWN_TELEMETRY.collision = AI_SPAWN_TELEMETRY.collision + 1
        byKind.collision = byKind.collision + 1
        aiAddSpawnBlacklist(x, y, z, outcome)
    elseif outcome == "bad_ground" then
        AI_SPAWN_TELEMETRY.bad_ground = AI_SPAWN_TELEMETRY.bad_ground + 1
        byKind.bad_ground = byKind.bad_ground + 1
        aiAddSpawnBlacklist(x, y, z, outcome)
    elseif outcome == "bad_address" then
        AI_SPAWN_TELEMETRY.bad_address = AI_SPAWN_TELEMETRY.bad_address + 1
        byKind.other = (byKind.other or 0) + 1
        -- Bad-address failures (nullptr pawn/controller/possession) get the
        -- same progressive per-site backoff as collision/bad_ground so a
        -- consistently unsafe cell stops being retried aggressively.
        aiAddSpawnBlacklist(x, y, z, outcome)
    else
        AI_SPAWN_TELEMETRY.other = (AI_SPAWN_TELEMETRY.other or 0) + 1
        byKind.other = (byKind.other or 0) + 1
        -- Possession failures (including the Maiasaura shared-controller
        -- path) are otherwise the least protected failure category: extend
        -- the same exponential per-site backoff tracking used for
        -- collisions/bad-ground so repeated possess failures at one spot
        -- escalate their retry delay instead of resetting to the flat
        -- crash-site TTL every time.
        if aiIsPossessFailureMsg(msg) then
            aiAddSpawnBlacklist(x, y, z, outcome)
        end
    end

    AI_SPAWN_TELEMETRY.last = {
        kind = kind,
        outcome = outcome,
        msg = msg,
        x = x,
        y = y,
        z = z,
        at = os.time(),
    }
    if outcome ~= "success" then
        aiRecordCrashSite(x, y, z, msg)
    end
end

function aiDumpSpawnTelemetry()
    if AI_SPAWN_TELEMETRY == nil then return end
    local now = os.time()
    local activeBlacklist = aiPruneSpawnBlacklist(now)
    local t = AI_SPAWN_TELEMETRY
    log(string.format(
        "ai spawn telemetry attempts=%d success=%d deaths=%d respawns=%d culled_idle=%d collision=%d bad_ground=%d bad_address=%d other=%d avg_health=%.1f avg_food=%.1f avg_thirst=%.1f",
        t.attempts or 0,
        t.success or 0,
        t.deaths or 0,
        t.respawns or 0,
        t.culled_idle or 0,
        t.collision or 0,
        t.bad_ground or 0,
        t.bad_address or 0,
        t.other or 0,
        tonumber(t.avg_health) or 0,
        tonumber(t.avg_food) or 0,
        tonumber(t.avg_thirst) or 0
    ))
    local d = aiEnsureKindTelemetry("dibble")
    local g = aiEnsureKindTelemetry("galli")
    log(string.format(
        "ai survival telemetry dibble(deaths=%d respawns=%d culled_idle=%d avg_h=%.1f avg_f=%.1f avg_t=%.1f) galli(deaths=%d respawns=%d culled_idle=%d avg_h=%.1f avg_f=%.1f avg_t=%.1f)",
        d.deaths or 0, d.respawns or 0, d.culled_idle or 0, tonumber(d.avg_health) or 0, tonumber(d.avg_food) or 0, tonumber(d.avg_thirst) or 0,
        g.deaths or 0, g.respawns or 0, g.culled_idle or 0, tonumber(g.avg_health) or 0, tonumber(g.avg_food) or 0, tonumber(g.avg_thirst) or 0
    ))
    local shown = 0
    local chunks = {}
    for key, row in pairs(AI_SPAWN_BLACKLIST or {}) do
        if shown >= 4 then break end
        shown = shown + 1
        chunks[#chunks + 1] = string.format("%s(%ss)", key, math.max(0, math.floor((tonumber(row.expiresAt) or now) - now)))
    end
    log(string.format(
        "ai spawn blacklist active=%d ttl=%ds grid=%duu entries=%s",
        activeBlacklist,
        math.max(300, math.min(600, math.floor(tonumber(AI_HERD.blacklistTtlSec) or 600))),
        math.max(250, math.floor(tonumber(AI_HERD.blacklistGridUU) or 1000)),
        (#chunks > 0) and table.concat(chunks, ",") or "none"
    ))
    -- Keep vitals as a 5-minute rolling window that resets after each telemetry dump.
    local function resetVitalsWindow(bucket)
        bucket.health_sum = 0
        bucket.food_sum = 0
        bucket.thirst_sum = 0
        bucket.health_samples = 0
        bucket.food_samples = 0
        bucket.thirst_samples = 0
        bucket.avg_health = 0
        bucket.avg_food = 0
        bucket.avg_thirst = 0
    end
    resetVitalsWindow(t)
    for _, byKind in pairs(t.by_kind or {}) do
        if type(byKind) == "table" then
            resetVitalsWindow(byKind)
        end
    end
end

function aiWriteHerdConfig()
    AI_HERD.biasRegions = {}
    AI_HERD.requirePreyProximity = true

    writeAll(AI_HERD_PATH, string.format(
        '{"enabled":%s,"callsMode":"%s","callsEnabled":%s,"callGap":%d,"callHearUU":%d,"callGapPop":%d,"targetTeno":0,"targetDibble":12,"targetGalli":12,"stabilityCeiling":40,"fillGap":240,"deathGap":300,"spawnMinGap":60,"pollGap":30,"cullWhenDisabled":%s,"requirePreyProximity":true,"preyArmPaddingUU":20000,"proxCacheSec":20,"proxDisarmCullSec":300,"herbClear":20000,"blacklistGridUU":1000,"blacklistTtlSec":600,"idleMoveMinUU":150,"idleCullSec":600,"wipeGap":1800,"biasRegions":[]}\n',
        AI_HERD.enabled and "true" or "false",
        tostring(AI_HERD.callsMode or "off"),
        AI_HERD.callsEnabled and "true" or "false",
        math.floor(tonumber(AI_HERD.callGap) or 240),
        math.floor(tonumber(AI_HERD.callHearUU) or 25000),
        math.floor(tonumber(AI_HERD.callGapPop) or 15),
        (AI_HERD.cullWhenDisabled ~= false) and "true" or "false"
    ))
end

-- Maiasaura ("dibble") has no native AI controller class in the base game,
-- so it intentionally shares the Tenontosaurus controller
-- (/Script/TheIsle.TIAITenontosaurusController). This is a deliberate
-- compatibility path, NOT a bug/typo — do not "fix" it by pointing dibble.ctrl
-- at a Maiasaura-specific controller (no such class exists) and do not remove
-- sharedController/sharedControllerFrom, which drive the extra post-Possess()
-- re-verification pass for shared-controller species (see aiSpawnAiHerbNow).
local EXPECTED_DIBBLE_CTRL = "/Script/TheIsle.TIAITenontosaurusController"
local EXPECTED_DIBBLE_SHARED_FROM = "teno"

AI_SPECIES = {
    teno = {
        key = "teno",
        label = "Tenontosaurus",
        pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Tenontosaurus/BP_Tenontosaurus.BP_Tenontosaurus_C",
        ctrl = "/Script/TheIsle.TIAITenontosaurusController",
    },
    dibble = {
        key = "dibble",
        label = "Maiasaura",
        pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C",
        -- Intentional shared-controller mapping. See note above this table.
        ctrl = EXPECTED_DIBBLE_CTRL,
        sharedController = true,
        sharedControllerFrom = EXPECTED_DIBBLE_SHARED_FROM,
    },
    galli = {
        key = "galli",
        label = "Gallimimus",
        pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Gallimimus/BP_Gallimimus.BP_Gallimimus_C",
        ctrl = "/Script/TheIsle.TIAIGallimimusController",
    },
}

-- Shared critical-warning helper: unconditionally tries both the host
-- `log` function (if present) AND `print` (always present in stock Lua),
-- each independently wrapped in `pcall` so a broken/missing `log` can't
-- prevent `print` from running. Neither call's return value is a reliable
-- signal that the message was actually recorded (a `log` no-op still
-- "succeeds"), so we don't gate one on the other.
function aiLogWarning(msg)
    if type(log) == "function" then
        pcall(log, msg)
    end
    pcall(print, msg)
end

-- Safeguard: detect AND self-heal if the intentional Maiasaura ->
-- Tenontosaurus shared-controller mapping is ever accidentally changed
-- (e.g. by a future edit pointing dibble at a nonexistent Maiasaura
-- controller, or dropping the sharedController flag). Restores the
-- required values (after logging) so the runtime never silently uses an
-- incorrect/nonexistent controller class — "cannot be accidentally
-- changed" is enforced, not just observed at load time. This is called
-- both immediately below (covers a bad literal at load time) and from
-- aiCachedClass() right before the dibble controller class is resolved
-- for actual use (covers any later runtime mutation of AI_SPECIES.dibble).
-- Operates on the module-level AI_SPECIES/AI_HERD globals, matching every
-- other helper in this file (aiClampTargets, aiWriteHerdConfig, etc.), all
-- of which read/write those same globals directly rather than taking them
-- as parameters. AI_HERD.ctrlCls is always initialized as a table in the
-- AI_HERD literal above, so the type(...) == "table" guard below is
-- defensive, not load-bearing.
function aiEnsureDibbleControllerMapping()
    local dibbleSpec = AI_SPECIES.dibble
    if type(dibbleSpec) == "table"
        and dibbleSpec.ctrl == EXPECTED_DIBBLE_CTRL
        and dibbleSpec.sharedController == true
        and dibbleSpec.sharedControllerFrom == EXPECTED_DIBBLE_SHARED_FROM then
        return dibbleSpec
    end

    aiLogWarning("[AI HERD WARNING] Maiasaura (dibble) controller mapping did not match the required "
        .. "shared Tenontosaurus controller (" .. EXPECTED_DIBBLE_CTRL .. "). "
        .. "Maiasaura has no native AI controller; restoring the required mapping.")

    -- Restore the mandatory mapping rather than leaving AI_SPECIES.dibble
    -- pointed at an invalid/nonexistent controller.
    if type(dibbleSpec) ~= "table" then
        dibbleSpec = {
            key = "dibble",
            label = "Maiasaura",
            pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C",
        }
        AI_SPECIES.dibble = dibbleSpec
    end
    dibbleSpec.ctrl = EXPECTED_DIBBLE_CTRL
    dibbleSpec.sharedController = true
    dibbleSpec.sharedControllerFrom = EXPECTED_DIBBLE_SHARED_FROM
    -- A cached controller class from before the fix would be stale/wrong;
    -- drop it so aiCachedClass() re-resolves against the corrected path.
    if type(AI_HERD.ctrlCls) == "table" then
        AI_HERD.ctrlCls.dibble = nil
    end
    return dibbleSpec
end

aiEnsureDibbleControllerMapping()

function aiClampTargets(teno, dibble, galli, ceiling)
    teno = 0
    local onlinePlayers = 0

    if player_manager ~= nil and type(player_manager.GetPlayerCount) == "function" then
        local okCount, count = pcall(player_manager.GetPlayerCount, player_manager)
        if not okCount then
            okCount, count = pcall(player_manager.GetPlayerCount)
        end
        if okCount then
            onlinePlayers = tonumber(count) or 0
        end
    elseif aiObjOk(AI_HERD.world) and type(AI_HERD.world.GetPlayers) == "function" then
        local okPlayers, players = pcall(function()
            return AI_HERD.world:GetPlayers()
        end)

        if okPlayers and type(players) == "table" then
            onlinePlayers = #players
        end
    end

    onlinePlayers = math.max(0, math.floor(tonumber(onlinePlayers) or 0))
    local baseHerdAICap = 12
    local minHerdAICap = 2
    local inverseScaleFactor = 0.5

    local scaledDibble = baseHerdAICap - math.floor(onlinePlayers * inverseScaleFactor)
    if scaledDibble < minHerdAICap then scaledDibble = minHerdAICap end

    local scaledGalli = baseHerdAICap - math.floor(onlinePlayers * inverseScaleFactor)
    if scaledGalli < minHerdAICap then scaledGalli = minHerdAICap end

    dibble = math.max(2, math.floor(tonumber(dibble) or scaledDibble))
    galli = math.max(2, math.floor(tonumber(galli) or scaledGalli))
    ceiling = math.max(0, math.floor(tonumber(ceiling) or 40))
    
    if ceiling > 0 and dibble > ceiling then dibble = ceiling end 
    if ceiling > 0 and galli > ceiling then galli = ceiling end

    AI_HERD.targetTeno = 0
    AI_HERD.targetGalli = galli
    AI_HERD.targetDibble = dibble
    AI_HERD.stabilityCeiling = ceiling
end
function loadAiHerdConfig(createIfMissing)
    AI_HERD.enabled = true
    AI_HERD.requirePreyProximity = true
    AI_HERD.biasRegions = {}

    local body = readAll(AI_HERD_PATH)
    if body == nil or body == "" then
        if createIfMissing then
            aiWriteHerdConfig()
        end
        return
    end

    local enabled = jsonReadBool(body, "enabled")
    if enabled ~= nil then
        AI_HERD.enabled = enabled == true
    end
    
    local callsOn = jsonReadBool(body, "callsEnabled")
    if callsOn ~= nil then
        AI_HERD.callsEnabled = callsOn == true
    end
    
    local mode = jsonReadString(body, "callsMode")
    if mode ~= nil and mode ~= "" then
        mode = string.lower(tostring(mode))
        if mode == "off" or mode == "spawn" or mode == "ambient" or mode == "full" then
            AI_HERD.callsMode = mode
        end
    elseif callsOn == true and (AI_HERD.callsMode == nil or AI_HERD.callsMode == "") then
        AI_HERD.callsMode = "full"
    end
    
    local callGap = tonumber(jsonReadNumber(body, "callGap"))
    if callGap ~= nil then
        AI_HERD.callGap = math.max(30, math.min(900, math.floor(callGap)))
    end
    
    local callHear = tonumber(jsonReadNumber(body, "callHearUU"))
    if callHear ~= nil then
        AI_HERD.callHearUU = math.max(5000, math.min(80000, math.floor(callHear)))
    end
    
    local callPop = tonumber(jsonReadNumber(body, "callGapPop"))
    if callPop ~= nil then
        AI_HERD.callGapPop = math.max(0, math.min(60, math.floor(callPop)))
    end

    local ceiling = tonumber(jsonReadNumber(body, "stabilityCeiling")) or 40
    local fillG = tonumber(jsonReadNumber(body, "fillGap"))
    local deathG = tonumber(jsonReadNumber(body, "deathGap"))
    local herbC = tonumber(jsonReadNumber(body, "herbClear"))

    if ceiling ~= nil then AI_HERD.stabilityCeiling = math.max(0, math.min(80, math.floor(ceiling))) end
    if fillG ~= nil then AI_HERD.fillGap = math.max(120, math.min(600, math.floor(fillG))) end
    if deathG ~= nil then AI_HERD.deathGap = math.max(60, math.min(900, math.floor(deathG))) end
    if herbC ~= nil then AI_HERD.herbClear = math.max(8000, math.min(60000, math.floor(herbC))) end

    local spawnGap = tonumber(jsonReadNumber(body, "spawnMinGap"))
    if spawnGap ~= nil then AI_HERD.spawnMinGap = math.max(30, math.min(600, math.floor(spawnGap))) end
    
    local pollG = tonumber(jsonReadNumber(body, "pollGap"))
    if pollG ~= nil then AI_HERD.pollGap = math.max(15, math.min(300, math.floor(pollG))) end
    
    local cullFlag = jsonReadBool(body, "cullWhenDisabled")
    if cullFlag ~= nil then AI_HERD.cullWhenDisabled = cullFlag == true end
    
    local gMin = tonumber(jsonReadNumber(body, "growthMin"))
    local gMax = tonumber(jsonReadNumber(body, "growthMax"))
    if gMin ~= nil then AI_HERD.growthMin = math.max(0.2, math.min(0.5, gMin)) end
    if gMax ~= nil then AI_HERD.growthMax = math.max(AI_HERD.growthMin or 0.30, math.min(0.65, gMax)) end
    
    local pad = tonumber(jsonReadNumber(body, "preyArmPaddingUU"))
    if pad ~= nil then AI_HERD.preyArmPaddingUU = math.max(0, math.min(20000, math.floor(pad))) end
    
    local proxSec = tonumber(jsonReadNumber(body, "proxCacheSec"))
    if proxSec ~= nil then AI_HERD.proxCacheSec = math.max(15, math.min(120, math.floor(proxSec))) end
    
    local disarmCull = tonumber(jsonReadNumber(body, "proxDisarmCullSec"))
    if disarmCull ~= nil then AI_HERD.proxDisarmCullSec = math.max(120, math.min(300, math.floor(disarmCull))) end
    local blacklistGrid = tonumber(jsonReadNumber(body, "blacklistGridUU"))
    if blacklistGrid ~= nil then AI_HERD.blacklistGridUU = math.max(250, math.min(5000, math.floor(blacklistGrid))) end
    local blacklistTtl = tonumber(jsonReadNumber(body, "blacklistTtlSec"))
    if blacklistTtl ~= nil then AI_HERD.blacklistTtlSec = math.max(300, math.min(600, math.floor(blacklistTtl))) end
    local idleMove = tonumber(jsonReadNumber(body, "idleMoveMinUU"))
    if idleMove ~= nil then AI_HERD.idleMoveMinUU = math.max(25, math.min(1000, math.floor(idleMove))) end
    local idleCull = tonumber(jsonReadNumber(body, "idleCullSec"))
    if idleCull ~= nil then AI_HERD.idleCullSec = math.max(300, math.min(1800, math.floor(idleCull))) end
    local wipeGap = tonumber(jsonReadNumber(body, "wipeGap"))
    if wipeGap ~= nil then AI_HERD.wipeGap = math.max(600, math.min(7200, math.floor(wipeGap))) end

    -- NOTE: AI_HERD.enabled is intentionally NOT reset here. The saved
    -- "enabled" flag was already applied above (see the jsonReadBool call
    -- near the top of this function); re-forcing it to true here would
    -- silently discard an operator's persisted "disabled" setting on every
    -- config reload.
    AI_HERD.requirePreyProximity = true
    AI_HERD.biasRegions = {}
    
    local online = 0
    local everyone = aiPlayerAnchors(false)
    if everyone ~= nil then online = #everyone end
    
    local baseCap = 12
    local drop = math.floor(online * 0.5)
    local finalTarget = math.max(2, baseCap - drop)

    if finalTarget < 2 then finalTarget = 12 end

    AI_HERD.targetTeno = 0
    AI_HERD.targetDibble = finalTarget
    AI_HERD.targetGalli = finalTarget
    AI_HERD.capTeno = 0
    AI_HERD.capDibble = 0
    AI_HERD.perCarniTeno = 0
    AI_HERD.perCarniDibble = 2
    AI_HERD.perCarniGalli = 2
    AI_HERD.allowDibble = true
end
function aiRemoveTrackedActor(row)
    if type(row) ~= "table" or not aiTrackedRowAlive(row) then
        return false
    end

    local pawn = row.pawn
    local removed = false

    local setHealthOk = false
    pcall(function()
        if aiObjectUsable(pawn) then
            pawn:SetHealth(0)
            setHealthOk = true
        end
    end)

    if setHealthOk then
        local deadAfterHealth = false
        local okDeadCheck, deadResult = pcall(aiPawnDead, pawn)
        if okDeadCheck then
            deadAfterHealth = deadResult == true
        end

        if deadAfterHealth then
            removed = true
        end
    end

    if not removed and aiObjectUsable(pawn) then
        local destroyOk = false

        pcall(function()
            pawn:DestroyActor()
            destroyOk = true
        end)

        if destroyOk then
            removed = not aiObjectUsable(pawn)
        end
    end

    if removed then
        aiCleanupTrackedRow(row, false)
    end

    return removed
end
function aiMaybeCullOverCap(dibble, galli)
    if AI_HERD.cullWhenDisabled == false then return 0 end
    if AI_HERD.sweepBusy == true or AI_HERD.cullBusy == true then
        AI_HERD.sweepPending = true
        return 0
    end
    AI_HERD.cullBusy = true

    -- Entire body runs inside pcall so a Lua exception anywhere in the loop/
    -- bookkeeping logic below cannot leave AI_HERD.cullBusy stuck at true
    -- (mirrors the exception-safe pattern used by aiSweepTracked).
    local okCull, cullResult = pcall(function()
        local targetT = 0
        local targetD = math.max(0, tonumber(AI_HERD.targetDibble) or 12)
        local targetG = math.max(0, tonumber(AI_HERD.targetGalli) or 12)

        local countT, countD, countG = 0, 0, 0

        for _, row in ipairs(aiTrackedRowsReady()) do
            if aiTrackedRowAlive(row) then
                if row.species == "teno" then countT = countT + 1
                elseif row.species == "dibble" then countD = countD + 1
                elseif row.species == "galli" then countG = countG + 1 end
            end
        end

        local killList = {}
        local keepList = {}

        for _, row in ipairs(aiTrackedRowsReady()) do
            if aiTrackedRowAlive(row) then
                if row.species == "teno" then
                    killList[#killList + 1] = row
                elseif row.species == "dibble" then
                    if countD > targetD then
                        killList[#killList + 1] = row
                        countD = countD - 1
                    else
                        keepList[#keepList + 1] = row
                    end
                elseif row.species == "galli" then
                    if countG > targetG then
                        killList[#killList + 1] = row
                        countG = countG - 1
                    else
                        keepList[#keepList + 1] = row
                    end
                else
                    keepList[#keepList + 1] = row
                end
            end
        end

local killedCount = 0

for _, row in ipairs(killList) do
    if aiRemoveTrackedActor(row) then
        killedCount = killedCount + 1
    elseif type(row) == "table" and aiTrackedRowAlive(row) then
        keepList[#keepList + 1] = row
    end
end

        aiFlushPendingTrackedAdds(keepList)
        AI_HERD.tracked = keepList
        return killedCount
    end)

    AI_HERD.cullBusy = false
    if not okCull then
        pcall(function()
            log("ai over-cap cull exception (recovered): " .. tostring(cullResult))
        end)
        return 0
    end
    local killed = cullResult
    if killed > 0 then log(string.format("ai over-cap cull wiped %d excess herd entities", killed)) end
    return killed
end
function aiCullTrackedHerd(reason)
    if AI_HERD.sweepBusy == true or AI_HERD.cullBusy == true then
        AI_HERD.sweepPending = true
        return 0
    end
    AI_HERD.cullBusy = true

    -- Entire body runs inside pcall so a Lua exception anywhere in the loop/
    -- bookkeeping logic below cannot leave AI_HERD.cullBusy stuck at true
    -- (mirrors the exception-safe pattern used by aiSweepTracked).
    local okCull, cullResult = pcall(function()
local killedCount = 0
local keep = {}

for _, row in ipairs(aiTrackedRowsReady()) do
    if type(row) == "table" then
        if aiTrackedRowAlive(row) then
            if aiRemoveTrackedActor(row) then
                killedCount = killedCount + 1
            else
                keep[#keep + 1] = row
            end
        else
            -- The pawn is already dead or invalid. Clean up any remaining
            -- controller references before dropping the row.
            aiCleanupTrackedRow(row, false)
            killedCount = killedCount + 1
        end
    end
end

aiFlushPendingTrackedAdds(keep)
AI_HERD.tracked = keep
        return killedCount
    end)

    AI_HERD.cullBusy = false

    if not okCull then
        pcall(function()
            log("ai herd cull exception (recovered): " .. tostring(cullResult))
        end)
        return 0
    end

    local killed = cullResult
    if killed > 0 then
        log(string.format(
            "ai herd cull removed %d entities (%s)",
            killed,
            tostring(reason or "unspecified")
        ))
    end

    return killed
end
function aiObjOk(obj)
    if obj == nil then return false end
    local addr
    pcall(function() addr = obj:GetAddress() end)
    return addr ~= nil and addr ~= 0
end

function aiObjectUsable(obj)
    if not aiObjOk(obj) then return false end
    local isValidMethod
    pcall(function() isValidMethod = obj.IsValid end)
    if type(isValidMethod) == "function" then
        local ok, valid = pcall(function() return obj:IsValid() end)
        if not ok or valid == false then return false end
    end
    return true
end

function aiCleanupTrackedRow(row, destroyPawn)
    if type(row) ~= "table" then return end
    row.lifecycle = "dead"
    local ctrl, pawn = row.ctrl, row.pawn
    if aiObjectUsable(ctrl) then
        pcall(function() ctrl:UnPossess() end)
        if aiObjectUsable(ctrl) then pcall(function() ctrl:DestroyActor() end) end
    end
    if destroyPawn and aiObjectUsable(pawn) then
        pcall(function() pawn:DestroyActor() end)
    end
    row.pawn = nil
    row.ctrl = nil
    row.lifecycle = "cleaned"
end

function aiPawnMovementReady(pawn)
    if not aiObjectUsable(pawn) then return false end
    for _, methodName in ipairs({ "GetCharacterMovement", "GetMovementComponent" }) do
        local method
        pcall(function() method = pawn[methodName] end)
        if type(method) == "function" then
            local ok, movement = pcall(function() return pawn[methodName](pawn) end)
            return ok and aiObjectUsable(movement)
        end
    end
    local velocityMethod
    pcall(function() velocityMethod = pawn.GetVelocity end)
    if type(velocityMethod) == "function" then
        local ok, velocity = pcall(function() return pawn:GetVelocity() end)
        return ok and velocity ~= nil
    end
    return false
end

-- Shared possession-link verifier: confirms ctrl:GetPawn() currently returns
-- the exact pawn we expect (by address) and that the pawn is movement-ready.
-- Used both for the initial post-Possess() check and for the extra
-- independent re-check performed for shared/foreign-controller species, so
-- the two verification passes can't drift out of sync.
function aiVerifyPossession(ctrl, pawn)
    if not aiObjectUsable(ctrl) or not aiPawnMovementReady(pawn) then return false end
    local getPawnMethod
    pcall(function() getPawnMethod = ctrl.GetPawn end)
    if type(getPawnMethod) ~= "function" then return false end

    local possessedPawn = nil
    local okGetPawn = pcall(function() possessedPawn = ctrl:GetPawn() end)
    local expectedAddr = nil
    local okExpectedAddr = pcall(function() expectedAddr = pawn:GetAddress() end)
    local possessedAddr = nil
    local okPossessedAddr = false
    if okGetPawn and aiObjectUsable(possessedPawn) then
        okPossessedAddr = pcall(function() possessedAddr = possessedPawn:GetAddress() end)
    end
    local haveExpectedAddr = okExpectedAddr and expectedAddr ~= nil and expectedAddr ~= 0
    local havePossessedAddr = okPossessedAddr and possessedAddr ~= nil and possessedAddr ~= 0
    return haveExpectedAddr and havePossessedAddr and possessedAddr == expectedAddr
        and aiPawnMovementReady(possessedPawn)
end

function aiTrackedTable()
    if type(AI_HERD.tracked) ~= "table" then
        AI_HERD.tracked = {}
    end
    local rows = {}
    for i, row in ipairs(AI_HERD.tracked) do
        if type(row) == "table" then rows[#rows + 1] = row end
    end
    return rows
end

function aiTrackedRowsReady()
    return aiTrackedTable()
end

function aiPendingTrackedTable()
    if type(AI_HERD.pendingTrackedAdds) ~= "table" then
        AI_HERD.pendingTrackedAdds = {}
    end
    return AI_HERD.pendingTrackedAdds
end

function aiFlushPendingTrackedAdds(target, teno, dibble, galli)
    local commitTarget = target == nil
    target = target or aiTrackedTable()
    teno = math.max(0, math.floor(tonumber(teno) or 0))
    dibble = math.max(0, math.floor(tonumber(dibble) or 0))
    galli = math.max(0, math.floor(tonumber(galli) or 0))
    local pending = aiPendingTrackedTable()
    AI_HERD.pendingTrackedAdds = {}
    local seenKeys = {}
    for _, row in ipairs(target) do
        local key = type(row) == "table" and aiTrackedRowKey(row) or nil
        if key ~= nil then
            seenKeys[key] = true
        end
    end
    for _, row in ipairs(pending) do
        if type(row) == "table" and aiTrackedRowAlive(row) then
            local key = aiTrackedRowKey(row)
            if key == nil or seenKeys[key] ~= true then
                target[#target + 1] = row
                if key ~= nil then
                    seenKeys[key] = true
                end
                if row.species == "teno" then teno = teno + 1
                elseif row.species == "dibble" then dibble = dibble + 1
                elseif row.species == "galli" then galli = galli + 1 end
            end
        end
    end
    if commitTarget then
        AI_HERD.tracked = target
    end
    return teno, dibble, galli
end

function aiAppendTrackedRow(row)
    if type(row) ~= "table" or not aiTrackedRowAlive(row) then return false end
    if AI_HERD.sweepBusy == true or AI_HERD.cullBusy == true then
        local pending = aiPendingTrackedTable()
        pending[#pending + 1] = row
        AI_HERD.sweepPending = true
    else
        local tracked = aiTrackedRowsReady()
        tracked[#tracked + 1] = row
        AI_HERD.tracked = tracked
    end
    return true
end

function aiTrackedRowKey(row)
    if type(row) ~= "table" then
        return nil
    end
    if aiObjOk(row.pawn) then
        local addr = nil
        pcall(function() addr = row.pawn:GetAddress() end)
        if addr ~= nil and addr ~= 0 then
            return "pawn:" .. tostring(addr)
        end
    end
    return nil
end

AI_TRACKED_ROW_MUTABLE_TABLE_FIELDS = AI_TRACKED_ROW_MUTABLE_TABLE_FIELDS or {
    lastLoc = true,
    lastVitals = true,
}

function aiDeepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local clone = {}
    seen[value] = clone
    for key, nestedValue in pairs(value) do
        clone[aiDeepCopy(key, seen)] = aiDeepCopy(nestedValue, seen)
    end
    return clone
end

function aiCloneTrackedRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local clone = {}
    for key, value in pairs(row) do
        if AI_TRACKED_ROW_MUTABLE_TABLE_FIELDS[key] == true and type(value) == "table" then
            clone[key] = aiDeepCopy(value)
        elseif key == "pawn" or key == "ctrl" then
            clone[key] = aiObjOk(value) and value or nil
        else
            clone[key] = value
        end
    end
    if clone.pawn == nil then clone.lifecycle = "cleaned" end
    return clone
end

function aiCloneTrackedRows(rows)
    local copy = {}
    for i, row in ipairs(rows or {}) do
        if type(row) == "table" and aiObjOk(row.pawn) then
            copy[#copy + 1] = aiCloneTrackedRow(row)
        end
    end
    return copy
end

function aiResolveClass(path)
    local cls
    pcall(function() cls = StaticFindObject(path) end)
    if aiObjOk(cls) then return cls end
    return nil
end

function aiCachedWorld()
    if type(findGameMode) == "function" then
        local okGameMode, gm = pcall(findGameMode)
        local world
        if okGameMode and aiObjectUsable(gm) then
            pcall(function() world = gm:GetWorld() end)
        end
        if aiObjectUsable(world) then
            AI_HERD.world = world
            return world
        end
        AI_HERD.world = nil
        return nil
    end
    if aiObjOk(AI_HERD.world) then return AI_HERD.world end
    AI_HERD.world = nil
    return nil
end

function aiCachedClass(kind, which)
    if kind == "dibble" and which == "ctrl" then
        local ok, err = pcall(aiEnsureDibbleControllerMapping)
        if not ok then
            aiLogWarning(
                "[AI HERD WARNING] aiEnsureDibbleControllerMapping failed: "
                .. tostring(err)
            )
        end
    end

    local bucket = which == "ctrl"
        and AI_HERD.ctrlCls
        or AI_HERD.pawnCls

    if aiObjOk(bucket[kind]) then
        return bucket[kind]
    end

    local spec = AI_SPECIES[kind]
    if spec == nil then
        return nil
    end

    local path = which == "ctrl"
        and spec.ctrl
        or spec.pawn

    local cls = aiResolveClass(path)
    if cls ~= nil then
        bucket[kind] = cls
    end

    return cls
end
function aiKismetSystem()
    if aiObjOk(AI_HERD.kismet) then return AI_HERD.kismet end
    local k
    pcall(function() k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if aiObjOk(k) then AI_HERD.kismet = k; return k end
    return nil
end
function aiHitResultZ(hit)
    if hit == nil then return nil end
    local z
    pcall(function()
        if hit.ImpactPoint ~= nil and hit.ImpactPoint.Z ~= nil then z = hit.ImpactPoint.Z; return end
        if hit.Location ~= nil and hit.Location.Z ~= nil then z = hit.Location.Z end
    end)
    if z == nil then
        pcall(function()
            if hit.ImpactPoint ~= nil and hit.ImpactPoint.z ~= nil then z = hit.ImpactPoint.z; return end
            if hit.Location ~= nil and hit.Location.z ~= nil then z = hit.Location.z end
        end)
    end
    return tonumber(z)
end

function aiGroundSnap(worldContext, x, y, hintZ)
    local kismet = aiKismetSystem()

    if not aiObjectUsable(worldContext) then
        worldContext = aiCachedWorld()
    end

    if not aiObjectUsable(kismet)
        or not aiObjectUsable(worldContext) then
        return nil
    end

    hintZ = tonumber(hintZ) or 0
    x = tonumber(x) or 0
    y = tonumber(y) or 0

    local startZ = hintZ + 60000
    local endZ = hintZ - 100000

    local hit = {}
    local wasHit = false

    local ok = pcall(function()
        wasHit = kismet:LineTraceSingle(
            worldContext,
            { x = x, y = y, z = startZ, X = x, Y = y, Z = startZ },
            { x = x, y = y, z = endZ, X = x, Y = y, Z = endZ },
            0,
            false,
            {},
            0,
            hit,
            true,
            { R = 0, G = 0, B = 0, A = 0, r = 0, g = 0, b = 0, a = 0 },
            { R = 0, G = 0, B = 0, A = 0, r = 0, g = 0, b = 0, a = 0 },
            0.0
        )
    end)

    if not ok or wasHit ~= true then
        return nil
    end

    local groundZ = aiHitResultZ(hit)
    if groundZ == nil then
        return nil
    end

    return groundZ + 120
end
function aiPawnDiet(pawn)
    if pawn == nil then return "carni" end
    local classPath = type(classPathOf) == "function" and classPathOf(pawn) or ""
    local key = type(speciesKey) == "function" and speciesKey(classPath) or "unknown"
    if type(dietOf) == "function" then return dietOf(key) end
    return "carni"
end

function aiPlayerAnchors(carniOnly)
    local found = {}
    if type(forEachPlayerCtrl) ~= "function" then return found end

    forEachPlayerCtrl(function(ctrl, _)
        if ctrl == nil then return end
        local pawn = type(livePawnFromCtrl) == "function" and livePawnFromCtrl(ctrl) or nil
        if pawn == nil or (type(isLiveDinoPawn) == "function" and not isLiveDinoPawn(pawn)) then return end
        local loc = type(readLocation) == "function" and readLocation(pawn) or nil
        if loc == nil or (loc.x == nil and loc.X == nil) then return end

        local x = tonumber(loc.x or loc.X)
        local y = tonumber(loc.y or loc.Y)
        local z = tonumber(loc.z or loc.Z) or 0
        if x == nil or y == nil then return end

        local finalLoc = { x = x, y = y, z = z }
        local diet = aiPawnDiet(pawn)
        if carniOnly and diet ~= "carni" then return end
        found[#found + 1] = { pawn = pawn, loc = finalLoc, diet = diet }
    end)
    return found
end

function aiInBiasRegion(x, y) return false end
function aiNearBiasRegion(x, y, paddingUU) return false end

function aiRefreshProxCache(force)
    local now = os.time()

    if not force and (AI_HERD.nextProxAt or 0) > now then
        return AI_HERD.proxArmed == true,
               AI_HERD.proxArmedCount or 0
    end

    AI_HERD.nextProxAt =
        now + math.max(
            15,
            math.floor(tonumber(AI_HERD.proxCacheSec) or 20)
        )

    -- Only carnivore players activate AI spawning.
    local carni = aiPlayerAnchors(true)

    AI_HERD.proxArmedAnchors = carni
    AI_HERD.proxArmedCount = #carni
    AI_HERD.proxArmed = #carni > 0

    if AI_HERD.proxArmed then
        AI_HERD.proxDisarmedSince = 0
    elseif (AI_HERD.proxDisarmedSince or 0) == 0 then
        AI_HERD.proxDisarmedSince = now
    end

    return AI_HERD.proxArmed,
           AI_HERD.proxArmedCount
end    
function aiEffectiveTargets()
    local targetD = math.max(0, math.floor(tonumber(AI_HERD.targetDibble) or 12))
    local targetG = math.max(0, math.floor(tonumber(AI_HERD.targetGalli) or 12))

    if AI_HERD.requirePreyProximity == false then
        return targetD, targetG
    end

    local carnivoreCount = math.max(
        0,
        math.floor(tonumber(AI_HERD.proxArmedCount) or 0)
    )

    if carnivoreCount <= 0 then
        return 0, 0
    end

    local perDibble = math.max(
        0,
        math.floor(tonumber(AI_HERD.perCarniDibble) or 1)
    )

    local perGalli = math.max(
        0,
        math.floor(tonumber(AI_HERD.perCarniGalli) or 1)
    )

    local ceiling = math.max(
        0,
        math.floor(tonumber(AI_HERD.stabilityCeiling) or 40)
    )

    local wantDibble = math.min(targetD, carnivoreCount * perDibble)
    local wantGalli = math.min(targetG, carnivoreCount * perGalli)

    local combined = wantDibble + wantGalli

    if ceiling > 0 and combined > ceiling then
        local scale = ceiling / combined
        wantDibble = math.floor(wantDibble * scale)
        wantGalli = math.floor(wantGalli * scale)
    end

    return wantDibble, wantGalli
end
function aiPawnDead(pawn)
    if pawn == nil then return true end
    local dead = false
    if type(tryBool) == "function" then
        dead = tryBool(pawn, { "IsDead", "GetIsDead", "bIsDead", "IsDying", "GetIsDying", "bDying" })
    end
    if dead == true then return true end
    
    local health = 100
    if type(tryNumber) == "function" then
        health = tryNumber(pawn, { "GetHealth", "Health", "GetCurrentHealth", "CurrentHealth" })
    else
        pcall(function() health = pawn.Health or pawn:GetHealth() end)
    end
    return health ~= nil and health <= 0.01
end

function aiTrackedCounts(includePending)
    local function countRows(rows, teno, dibble, galli)
        teno = teno or 0
        dibble = dibble or 0
        galli = galli or 0
        for _, row in ipairs(rows or {}) do
            if aiTrackedRowAlive(row) then
                if row.species == "teno" then teno = teno + 1
                elseif row.species == "dibble" then dibble = dibble + 1
                elseif row.species == "galli" then galli = galli + 1 end
            end
        end
        return teno, dibble, galli
    end

    local teno, dibble, galli = 0, 0, 0
    teno, dibble, galli = countRows(aiTrackedRowsReady(), teno, dibble, galli)
    if includePending == true then
        teno, dibble, galli = countRows(aiPendingTrackedTable(), teno, dibble, galli)
    end
    return teno, dibble, galli
end

function aiTrackedRowAlive(row)
    if type(row) ~= "table" or not aiObjectUsable(row.pawn) then
        return false
    end
    local okDead, dead = pcall(aiPawnDead, row.pawn)
    return okDead and dead ~= true
end

function aiSweepTracked(retrying, depth)
    depth = (tonumber(depth) or 0) + 1
    if depth > 3 then
        AI_HERD.sweepPending = false
        log("ai sweep aborted after repeated recovery attempts")
        return aiTrackedCounts()
    end
    if AI_HERD.sweepBusy == true or AI_HERD.cullBusy == true then
        AI_HERD.sweepPending = true
        local last = AI_HERD.lastSweepCounts or {}
        return tonumber(last.teno) or 0,
               tonumber(last.dibble) or 0,
               tonumber(last.galli) or 0
    end
    local hadPending = AI_HERD.sweepPending == true
    local rows = aiTrackedRowsReady()
    AI_HERD.sweepBusy = true
    AI_HERD.sweepPending = hadPending
    local okSweep, keep, respawnKinds, teno, dibble, galli = pcall(function()
        local keep = {}
        local respawnKinds = {}
        local teno, dibble, galli = 0, 0, 0
        local now = os.time()
        local idleMoveMin = math.max(25, math.floor(tonumber(AI_HERD.idleMoveMinUU) or 150))
        local idleCullSec = math.max(300, math.floor(tonumber(AI_HERD.idleCullSec) or 600))
        local idleMoveMinSq = idleMoveMin * idleMoveMin
        for _, row in ipairs(rows) do
            if type(row) == "table" and aiObjOk(row.pawn) then
                local okDead, dead = pcall(aiPawnDead, row.pawn)
                if not okDead then dead = true end
                local stale = false
                local nextRow = row
                if not dead then
                    nextRow = aiCloneTrackedRow(row)
                    local loc
                    if type(readLocation) == "function" then
                        local ok, value = pcall(readLocation, row.pawn)
                        if ok then loc = value end
                    end
                    if loc ~= nil then
                        local lx = tonumber(loc.x or loc.X) or 0
                        local ly = tonumber(loc.y or loc.Y) or 0
                        local lz = tonumber(loc.z or loc.Z) or 0
                        local prev = nextRow.lastLoc
                        if prev == nil then
                            nextRow.lastLoc = { x = lx, y = ly, z = lz }
                            nextRow.lastMoveAt = now
                        else
                            local dx = lx - (tonumber(prev.x) or lx)
                            local dy = ly - (tonumber(prev.y) or ly)
                            local dz = lz - (tonumber(prev.z) or lz)
                            if ((dx * dx) + (dy * dy) + (dz * dz)) >= idleMoveMinSq then
                                nextRow.lastMoveAt = now
                                nextRow.lastLoc = { x = lx, y = ly, z = lz }
                            end
                        end
                    end
                    nextRow.lastSeenAt = now
                    local lastMoveAt = math.floor(tonumber(nextRow.lastMoveAt or nextRow.spawnedAt or now) or now)
                    if lastMoveAt > now then lastMoveAt = now; nextRow.lastMoveAt = now end
                    local stuckFor = math.max(0, now - lastMoveAt)
                    local vh, vf, vt = aiReadVitals(row.pawn)
                    aiRecordVitals(nextRow.species, vh, vf, vt)
                    nextRow.lastVitals = nextRow.lastVitals or {}
                    nextRow.lastVitalChangeAt = math.floor(tonumber(nextRow.lastVitalChangeAt or now) or now)
                    local haveVitalSample = (vh ~= nil) or (vf ~= nil) or (vt ~= nil)
                    if vh ~= nil and (nextRow.lastVitals.health == nil or math.abs(vh - nextRow.lastVitals.health) >= 0.1) then
                        nextRow.lastVitalChangeAt = now
                    end
                    if vf ~= nil and (nextRow.lastVitals.food == nil or math.abs(vf - nextRow.lastVitals.food) >= 0.1) then
                        nextRow.lastVitalChangeAt = now
                    end
                    if vt ~= nil and (nextRow.lastVitals.thirst == nil or math.abs(vt - nextRow.lastVitals.thirst) >= 0.1) then
                        nextRow.lastVitalChangeAt = now
                    end
                    nextRow.lastVitals.health = vh
                    nextRow.lastVitals.food = vf
                    nextRow.lastVitals.thirst = vt
                    local vitalStillFor = math.max(0, now - math.floor(tonumber(nextRow.lastVitalChangeAt or now) or now))
                    -- Timestamp/TTL guard: if a pawn has not moved past idleMoveMinUU for idleCullSec,
                    -- and has also had no vital-state change, it is considered stale.
                    if haveVitalSample and stuckFor >= idleCullSec and vitalStillFor >= idleCullSec then
                        local culled = false
                        local setHealthOk = false
                        pcall(function() row.pawn:SetHealth(0); setHealthOk = true end)
                        if setHealthOk and not aiTrackedRowAlive(row) then culled = true end
                        if not culled and aiTrackedRowAlive(row) then
                            local destroyOk = false
                            pcall(function() row.pawn:DestroyActor(); destroyOk = true end)
                            if destroyOk then
                                local stillValid = aiObjOk(row.pawn)
                                local okDeadAfter, deadAfter = false, true
                                if stillValid then
                                    okDeadAfter, deadAfter = pcall(aiPawnDead, row.pawn)
                                end
                                if not stillValid or not okDeadAfter or deadAfter then culled = true end
                            end
                        end
                        if culled then
                            stale = true
                            aiCleanupTrackedRow(row, false)
                            AI_SPAWN_TELEMETRY.culled_idle = (AI_SPAWN_TELEMETRY.culled_idle or 0) + 1
                            local byKind = aiEnsureKindTelemetry(row.species)
                            byKind.culled_idle = (byKind.culled_idle or 0) + 1
                            log(string.format(
                                "ai herd cull species=%s reason=idle_stuck stuck_for=%ds at=(%.0f,%.0f,%.0f)",
                                tostring(row.species or "unknown"),
                                stuckFor,
                                tonumber((nextRow.lastLoc or {}).x) or 0,
                                tonumber((nextRow.lastLoc or {}).y) or 0,
                                tonumber((nextRow.lastLoc or {}).z) or 0
                            ))
                        end
                    end
                end

                if dead then
                    row.lifecycle = "dead"
                    aiCleanupTrackedRow(row, false)
                    respawnKinds[#respawnKinds + 1] = row.species
                elseif stale then
                    respawnKinds[#respawnKinds + 1] = row.species
                else
                    keep[#keep + 1] = nextRow
                    if nextRow.species == "teno" then teno = teno + 1
                    elseif nextRow.species == "dibble" then dibble = dibble + 1
                    elseif nextRow.species == "galli" then galli = galli + 1 end
                end
            elseif type(row) == "table" then
                row.lifecycle = "dead"
                aiCleanupTrackedRow(row, false)
                respawnKinds[#respawnKinds + 1] = row.species
            end
        end
        return keep, respawnKinds, teno, dibble, galli
    end)
    if not okSweep then
        local rerun = AI_HERD.sweepPending == true
        local currentTracked = type(AI_HERD.tracked) == "table" and AI_HERD.tracked or {}
        local pending = type(AI_HERD.pendingTrackedAdds) == "table" and AI_HERD.pendingTrackedAdds or {}
        local pendingCount = #pending
        AI_HERD.pendingTrackedAdds = {}
        local rebuilt = aiCloneTrackedRows(currentTracked)
        local seenKeys = {}
        for _, row in ipairs(rebuilt) do
            local key = aiTrackedRowKey(row)
            if key ~= nil then
                seenKeys[key] = true
            end
        end
        for _, row in ipairs(pending) do
            if type(row) == "table" and aiTrackedRowAlive(row) then
                local key = aiTrackedRowKey(row)
                if key == nil or seenKeys[key] ~= true then
                    rebuilt[#rebuilt + 1] = row
                    if key ~= nil then
                        seenKeys[key] = true
                    end
                end
            end
        end
        rerun = rerun or AI_HERD.sweepPending == true or #aiPendingTrackedTable() > 0
        AI_HERD.sweepPending = rerun
        AI_HERD.sweepBusy = false
        if not retrying and (rerun or pendingCount > 0) then
            AI_HERD.tracked = rebuilt
            return aiSweepTracked(true, depth)
        end
        AI_HERD.tracked = rebuilt
        local failTeno, failDibble, failGalli = aiTrackedCounts()
        AI_HERD.lastSweepCounts = {
            teno = failTeno,
            dibble = failDibble,
            galli = failGalli
        }
        return failTeno, failDibble, failGalli
    end
    teno, dibble, galli = aiFlushPendingTrackedAdds(keep, teno, dibble, galli)
    AI_HERD.tracked = keep
    for _, species in ipairs(respawnKinds or {}) do
        pcall(aiQueueDeathForRespawn, species)
    end
    aiRecomputePendingRespawns()
    AI_HERD.lastSweepCounts = {
        teno = teno,
        dibble = dibble,
        galli = galli
    }
    local rerun = AI_HERD.sweepPending == true
    AI_HERD.sweepPending = false
    AI_HERD.sweepBusy = false
    if rerun then return aiSweepTracked(nil, depth) end
    return teno, dibble, galli
end

function aiSoftFillGap(have, target)
    local base = AI_HERD.fillGap or 120
    target = math.max(2, tonumber(target) or 2)
    have = math.max(0, tonumber(have) or 0)
    local ratio = math.min(1.0, have / target)
    return math.floor(base * (1.0 + ratio * 2.0))
end
function aiNextAtField(kind)
    if kind == "teno" then return "nextTenoAt" end
    if kind == "dibble" then return "nextDibbleAt" end
    if kind == "galli" then return "nextGalliAt" end
    return nil
end

function aiArmKind(kind, now, why, gap)
    gap = tonumber(gap) or (AI_HERD.fillGap or 120)
    local field = aiNextAtField(kind)
    if field ~= nil then AI_HERD[field] = now + gap end
    log(string.format("ai %s %s — next in %ds", kind, why or "timer", gap))
end

function aiHandleDeathTimers(now, dibble, galli, targetD, targetG)
    local lastD = AI_HERD.lastDibble or 0
    local lastG = AI_HERD.lastGalli or 0
    local deathGap = AI_HERD.deathGap or 300
    
    if dibble < lastD and lastD >= targetD and targetD > 0 then aiArmKind("dibble", now, "died at demand", deathGap) end
    if galli < lastG and lastG >= targetG and targetG > 0 then aiArmKind("galli", now, "died at demand", deathGap) end
    
    AI_HERD.lastTeno = 0
    AI_HERD.lastDibble = dibble
    AI_HERD.lastGalli = galli
end

function aiEnsureFillTimer(kind, have, target, dueAt, now)
    if target <= 0 or have >= target then return 0 end
    if dueAt == nil or dueAt == 0 then
        aiArmKind(kind, now, "fill", aiSoftFillGap(have, target))
        local field = aiNextAtField(kind)
        if field ~= nil then return AI_HERD[field] end
        return now + (AI_HERD.fillGap or 120)
    end
    return dueAt
end

function aiNeedKind()
    local teno, dibble, galli = aiSweepTracked()
    teno = math.max(0, math.floor(tonumber(teno) or 0))
    dibble = math.max(0, math.floor(tonumber(dibble) or 0))
    galli = math.max(0, math.floor(tonumber(galli) or 0))
    local targetT = AI_HERD.targetTeno or 0
    local targetD = AI_HERD.targetDibble or 12
    local targetG = AI_HERD.targetGalli or 12
    if teno < targetT then return "teno", teno, dibble, galli end
    if dibble < targetD then return "dibble", teno, dibble, galli end
    if galli < targetG then return "galli", teno, dibble, galli end
    return nil, teno, dibble, galli
end

function aiClearanceOk(x, y, anchors)
    local playerClearSq = (AI_HERD.playerClear or 12000) ^ 2
    local herbClearSq = (AI_HERD.herbClear or 20000) ^ 2
    local herdClearSq = (AI_HERD.herdClear or 8000) ^ 2
    
    for _, anchor in ipairs(anchors) do
        local ax = anchor.loc.x or anchor.loc.X or 0
        local ay = anchor.loc.y or anchor.loc.Y or 0
        local dx = x - ax
        local dy = y - ay
        local distSq = (dx * dx) + (dy * dy)
        local need = playerClearSq
        if anchor.diet == "herb" or anchor.diet == "omni" then need = herbClearSq end
        if distSq < need then return false end
    end
    
    for _, row in ipairs(aiTrackedRowsReady()) do
        local loc
        if aiTrackedRowAlive(row) and type(readLocation) == "function" then
            local ok, value = pcall(readLocation, row.pawn)
            if ok then loc = value end
        end
        if loc ~= nil then
            local lx = loc.x or loc.X or 0
            local ly = loc.y or loc.Y or 0
            local dx = x - lx
            local dy = y - ly
            if (dx * dx) + (dy * dy) < herdClearSq then return false end
        end
    end
    return true
end
function aiPickSpot()
    local carni = AI_HERD.proxArmedAnchors

    if carni == nil or #carni == 0 then
        aiRefreshProxCache(true)
        carni = AI_HERD.proxArmedAnchors or {}
    end

    if #carni == 0 then
        return nil, "no carnivore near prey"
    end

    local everyone = aiPlayerAnchors(false)
    local pool = carni
    -- pool is always carni here (non-empty, per the early return above), so
    -- there is no reachable "no player anchors" fallback path in this build.

    local spawnMin = AI_HERD.spawnMin or 10000
    local spawnMax = math.max(
        spawnMin,
        AI_HERD.spawnMax or 25000
    )

    local worldCtx = aiCachedWorld()
    if not aiObjectUsable(worldCtx) then
        return nil, "world context unavailable"
    end
    local now = os.time()
    aiPruneSpawnBlacklist(now)

    for _ = 1, 6 do
        local pick = pool[math.random(#pool)]
        local ang = math.random() * math.pi * 2
        local dist = spawnMin + math.random() * (spawnMax - spawnMin)

        local px = pick.loc.x or pick.loc.X or 0
        local py = pick.loc.y or pick.loc.Y or 0
        local pz = pick.loc.z or pick.loc.Z or 0

        local x = px + math.cos(ang) * dist
        local y = py + math.sin(ang) * dist

        if not aiIsSpawnBlacklisted(x, y, now)
            and not aiIsCrashSiteDisabled(x, y, now)
            and aiClearanceOk(x, y, everyone) then
            local groundZ = aiGroundSnap(worldCtx, x, y, pz)

            if groundZ ~= nil then
                return {
                    x = x,
                    y = y,
                    z = groundZ,
                    yaw = math.random() * 360,
                    world = worldCtx,
                    distance = dist
                }
            end
        end
    end

    return nil, "no separated spawn spot"
end
function aiFinishPawn(pawn, growth)
    if not aiObjectUsable(pawn) then return end
    pcall(function() if aiObjectUsable(pawn) then pawn:SetGrowth(growth) end end)
    pcall(function()
        if not aiObjectUsable(pawn) then return end
        local mx
        pcall(function() if aiObjectUsable(pawn) then mx = pawn:GetMaxHealth() end end)
        if mx ~= nil and aiObjectUsable(pawn) then pawn:SetHealth(mx) end
    end)
    pcall(function()
        if not aiObjectUsable(pawn) then return end
        local mx
        pcall(function() if aiObjectUsable(pawn) then mx = pawn:GetMaxFoodValue() end end)
        if mx ~= nil and aiObjectUsable(pawn) then pawn:SetFood(mx) end
    end)
    pcall(function()
        if not aiObjectUsable(pawn) then return end
        local mx
        pcall(function() if aiObjectUsable(pawn) then mx = pawn:GetMaxThirst() end end)
        if mx ~= nil and aiObjectUsable(pawn) then pawn:SetThirst(mx) end
    end)
    pcall(function() if aiObjectUsable(pawn) then pawn:SetReplicates(true) end end)
end

function aiCallsMode()
    local mode = string.lower(tostring(AI_HERD.callsMode or "off"))
    if mode == "off" or mode == "spawn" or mode == "ambient" or mode == "full" then
        if mode == "ambient" or mode == "full" then return "spawn" end
        return mode
    end
    if AI_HERD.callsEnabled == true then return "spawn" end
    return "off"
end

function aiAmbientCallGap(now)
    local gap = tonumber(AI_HERD.callGap) or 240
    local online = 0
    local everyone = aiPlayerAnchors(false)
    if everyone ~= nil then online = #everyone end
    gap = gap + (online * (tonumber(AI_HERD.callGapPop) or 15))
    return math.max(120, math.min(900, math.floor(gap)))
end

function aiTryBroadcastCall(pawn, why)
    if tostring(why or "") ~= "spawn" then return false end
    if aiCallsMode() == "off" then return false end
    if not aiObjOk(pawn) or aiPawnDead(pawn) then return false end
    local vocal = nil
    if makeFName ~= nil then vocal = makeFName("Broadcast") end
    if vocal == nil and FName ~= nil then pcall(function() vocal = FName("Broadcast") end) end
    if vocal == nil then return false end
    local mag = tonumber(AI_HERD.callMagnitude) or 1.0
    local ok = false
    local gm = nil
    if type(findGameMode) == "function" then pcall(function() gm = findGameMode() end) end
    if gm ~= nil then pcall(function() gm:ServerCallVocalSpawn(pawn, mag, vocal); ok = true end) end
    if not ok then pcall(function() pawn:SpawnVocals(mag, vocal); ok = true end) end
    if ok then log(string.format("ai call Broadcast (spawn mode=%s)", aiCallsMode())) end
    return ok
end

function aiPollCalls(now)
    AI_HERD.nextCallAt = now + 600
    if (AI_HERD.nextWaterLatchAt or 0) > now then return end
    AI_HERD.nextWaterLatchAt = now + 120
    for _, row in ipairs(aiTrackedRowsReady()) do
        if aiTrackedRowAlive(row) then
            local ctrl = row.ctrl
            if not aiObjOk(ctrl) then pcall(function() ctrl = row.pawn:GetController() end); if aiObjOk(ctrl) then row.ctrl = ctrl end end
            if aiObjOk(ctrl) then pcall(function() ctrl.bAvoidWaterWhenPossible = true end) end
        end
    end
end
function aiSpawnAiHerbNow(kind)
    aiSpawnLog(kind, "begin")
    aiTrackedRowsReady()
    local spec = AI_SPECIES[kind]
    if spec == nil then
        return false, "unknown kind"
    end

    local spot, spotError = aiPickSpot()
    if spot == nil then
        aiSpawnLog(kind, "spot", spotError or "unavailable")
        aiRecordSpawnTelemetry(kind, "other", spotError or "no separated spawn spot", 0, 0, 0)
        return false, spotError or "no separated spawn spot"
    end
    AI_HERD.currentSpawnLocation = { x = spot.x, y = spot.y, z = spot.z }
    aiSpawnLog(kind, "spot", string.format("(%.0f,%.0f,%.0f)", spot.x, spot.y, spot.z))

    local world = aiCachedWorld()

    if not aiObjectUsable(world) then
        aiSpawnLog(kind, "world", "unavailable")
        aiRecordSpawnTelemetry(kind, "other", "no world", spot.x, spot.y, spot.z)
        return false, "no world"
    end
    aiSpawnLog(kind, "world", "validated")

    local pawnCls = aiCachedClass(kind, "pawn")
    local ctrlCls = aiCachedClass(kind, "ctrl")

    if pawnCls == nil or ctrlCls == nil then
        aiSpawnLog(kind, "classes", "unavailable")
        aiRecordSpawnTelemetry(kind, "other", "class not loaded " .. spec.label, spot.x, spot.y, spot.z)
        return false, "class not loaded " .. spec.label
    end
    aiSpawnLog(kind, "classes", "resolved")

    local loc = {
        x = spot.x,
        y = spot.y,
        z = spot.z,
        X = spot.x,
        Y = spot.y,
        Z = spot.z
    }

    local rot = {
        pitch = 0,
        yaw = spot.yaw or 0,
        roll = 0,
        Pitch = 0,
        Yaw = spot.yaw or 0,
        Roll = 0
    }

    -- Spawn pawn.
    local okPawn, pawn = pcall(function()
        if not aiObjectUsable(world) then error("world became invalid before pawn spawn") end
        return world:SpawnActor(pawnCls, loc, rot)
    end)
    aiSpawnLog(kind, "pawn_spawn", okPawn and (aiObjOk(pawn) and "actor returned" or "invalid actor") or "exception")

    if not okPawn then
        aiRecordSpawnTelemetry(kind, "other", "pawn spawn exception", spot.x, spot.y, spot.z)
        return false, "pawn spawn exception"
    end

    if pawn == nil or not aiObjOk(pawn) then
        aiRecordSpawnTelemetry(kind, "collision", "pawn spawn collision (bad ground)", spot.x, spot.y, spot.z)
        return false, "pawn spawn collision (bad ground)"
    end

    -- Verify pawn address before using it.
    local pawnAddr
    local okPawnAddr = pcall(function()
        pawnAddr = pawn:GetAddress()
    end)

    if not okPawnAddr or pawnAddr == nil or pawnAddr == 0 then
        aiCleanupTrackedRow({ pawn = pawn }, true)
        aiRecordSpawnTelemetry(kind, "bad_address", "pawn spawn nullptr (bad address)", spot.x, spot.y, spot.z)
        return false, "pawn spawn nullptr (bad address)"
    end
    aiSpawnLog(kind, "pawn_address", tostring(pawnAddr))

    -- Spawn controller.
    local okCtrl, ctrl = pcall(function()
        if not aiObjectUsable(world) then error("world became invalid before controller spawn") end
        return world:SpawnActor(ctrlCls, loc, rot)
    end)
    aiSpawnLog(kind, "controller_spawn", okCtrl and (aiObjOk(ctrl) and "actor returned" or "invalid actor") or "exception")

    if not okCtrl or ctrl == nil or not aiObjOk(ctrl) then
        aiCleanupTrackedRow({ pawn = pawn }, true)
        aiRecordSpawnTelemetry(kind, "other", "controller spawn failed", spot.x, spot.y, spot.z)
        return false, "controller spawn failed"
    end

    -- Verify controller address.
    local ctrlAddr
    local okCtrlAddr = pcall(function()
        ctrlAddr = ctrl:GetAddress()
    end)

    if not okCtrlAddr or ctrlAddr == nil or ctrlAddr == 0 then
        aiCleanupTrackedRow({ pawn = pawn, ctrl = ctrl }, true)
        aiRecordSpawnTelemetry(kind, "bad_address", "controller spawn nullptr", spot.x, spot.y, spot.z)
        return false, "controller spawn nullptr"
    end
    aiSpawnLog(kind, "controller_address", tostring(ctrlAddr))

    -- Possess pawn.
    local possessCallOk = pcall(function()
        if not aiObjectUsable(ctrl) or not aiPawnMovementReady(pawn) then
            error("actor invalid before possession")
        end
        ctrl:Possess(pawn)
    end)
    local possessed = false
    aiSpawnLog(kind, "possess_call", possessCallOk and "returned" or "exception")

    if possessCallOk then
        local okVerify, verifyResult = pcall(aiVerifyPossession, ctrl, pawn)
        possessed = okVerify and verifyResult == true
    end
    aiSpawnLog(kind, "possess_verify", possessed and "address, validity, movement verified" or "failed")

    -- Extra re-verification pass for species that share a foreign controller
    -- class (currently only Maiasaura/dibble, whose controller was authored
    -- for Tenontosaurus). A controller possessing a pawn type it wasn't
    -- built for is the highest-risk case for a native (non-Lua) crash during
    -- or shortly after Possess(), so re-verify the possession link a second,
    -- independent time before treating the spawn as final using the same
    -- aiVerifyPossession check. Note: this is a synchronous re-check, not an
    -- actual engine tick/frame delay (no such yield API is exposed to this
    -- script), so it cannot catch a native crash inside Possess() itself
    -- (pcall only catches Lua-level errors) — but it does catch a
    -- possession that already silently unraveled by the time this second
    -- check runs.
    if possessed and spec.sharedController == true then
        local okResettle, resettled = pcall(aiVerifyPossession, ctrl, pawn)
        possessed = okResettle and resettled == true
        aiSpawnLog(kind, "possess_resettle", possessed and "shared controller settled" or "shared controller unstable")
    end

    if not possessCallOk or not possessed then
        aiCleanupTrackedRow({ pawn = pawn, ctrl = ctrl }, true)
        pawn, ctrl = nil, nil

        local reason = spec.sharedController == true
            and ("possess failed (shared controller from " .. tostring(spec.sharedControllerFrom) .. ")")
            or "possess failed"
        aiRecordSpawnTelemetry(kind, "other", reason, spot.x, spot.y, spot.z)
        return false, reason
    end

    -- Apply safe AI behavior settings.
    pcall(function()
        if aiObjectUsable(ctrl) then ctrl.bAvoidWaterWhenPossible = true end
    end)

    pcall(function()
        if not aiObjectUsable(ctrl) then return end
        local spacing = tonumber(ctrl.WaterAvoidanceSampleSpacing) or 0

        if spacing <= 0 or spacing > 400 then
            ctrl.WaterAvoidanceSampleSpacing = 350
        end
    end)

    pcall(function()
        if not aiObjectUsable(ctrl) then return end
        local maxS = tonumber(ctrl.MaxWaterSamplesPerSegment) or 0

        if maxS <= 0 or maxS > 4 then
            ctrl.MaxWaterSamplesPerSegment = 4
        end
    end)

    local lo = tonumber(AI_HERD.growthMin) or 0.30
    local hi = tonumber(AI_HERD.growthMax) or 0.50

    if hi < lo then
        hi = lo
    end

    aiFinishPawn(
        pawn,
        lo + math.random() * (hi - lo)
    )
    if not aiPawnMovementReady(pawn) or not aiObjectUsable(ctrl) then
        aiSpawnLog(kind, "post_initialize", "actor validation failed")
        aiCleanupTrackedRow({ pawn = pawn, ctrl = ctrl }, true)
        pawn, ctrl = nil, nil
        aiRecordSpawnTelemetry(kind, "bad_address", "actor invalid after possession", spot.x, spot.y, spot.z)
        return false, "actor invalid after possession"
    end

    local vh, vf, vt = aiReadVitals(pawn)
    local spawnedNow = os.time()
    local trackedRow = {
        species = kind,
        pawn = pawn,
        ctrl = ctrl,
        sharedController = spec.sharedController == true,
        lifecycle = "spawning",
        spawnedAt = spawnedNow,
        lastSeenAt = spawnedNow,
        lastMoveAt = spawnedNow,
        lastLoc = { x = spot.x, y = spot.y, z = spot.z },
        lastVitalChangeAt = spawnedNow,
        lastVitals = { health = vh, food = vf, thirst = vt }
    }
    trackedRow.lifecycle = "alive"
    if not aiAppendTrackedRow(trackedRow) then
        aiCleanupTrackedRow(trackedRow, true)
        aiRecordSpawnTelemetry(kind, "other", "tracked row append failed", spot.x, spot.y, spot.z)
        return false, "tracked row append failed"
    end
    aiSpawnLog(kind, "tracked", "alive")
    AI_SPAWN_TELEMETRY.last_spawn_vitals = { kind = kind, health = vh, food = vf, thirst = vt, at = spawnedNow }
    local byKind = aiEnsureKindTelemetry(kind)
    byKind.last_spawn_vitals = { health = vh, food = vf, thirst = vt, at = spawnedNow }

    if not AI_HERD.announced then
        AI_HERD.announced = true
        log("ai herd live — Player proximity tracking engaged.")
    end

    aiRecordSpawnTelemetry(kind, "success", "spawn ok", spot.x, spot.y, spot.z)

    log(string.format(
        "ai spawn %s distance=%.0fm groundZ=%.0f target=T:0/D(Maia):%d/G:%d",
        spec.label,
        (spot.distance or 0) / 100,
        (spot.z or 0) / 100,
        AI_HERD.targetDibble or 12,
        AI_HERD.targetGalli or 12
    ))

    if aiTryBroadcastCall(pawn, "spawn") then
        AI_HERD.nextCallAt =
            os.time() + math.max(
                120,
                math.floor(aiAmbientCallGap(os.time()) * 0.5)
            )
    else
        AI_HERD.nextCallAt = os.time() + 60
    end

    return true, spec.label
end

function spawnAiHerb(kind)
    local clock = os.clock()
    if (AI_HERD.emergencyDisabledUntil or 0) > os.time() then
        aiSpawnLog(kind, "disabled", "emergency backoff active")
        return false, "spawning emergency-disabled"
    end
    if clock < (AI_HERD.nextSpawnAllowedClock or 0) then
        return false, "spawn rate limited"
    end
    AI_HERD.lastSpawnAttemptClock = clock
    AI_HERD.nextSpawnAllowedClock = clock + 0.5
    local ok, spawned, message = pcall(aiSpawnAiHerbNow, kind)
    AI_HERD.nextSpawnAllowedClock = os.clock() + 0.5
    if not ok then
        aiSpawnLog(kind, "exception", tostring(spawned))
        local spot = AI_HERD.currentSpawnLocation or {}
        pcall(aiRecordSpawnTelemetry, kind, "other", tostring(spawned), spot.x or 0, spot.y or 0, spot.z or 0)
        AI_HERD.currentSpawnLocation = nil
        return false, tostring(spawned)
    end
    AI_HERD.currentSpawnLocation = nil
    return spawned, message
end

function aiPollHerdUnsafe()
    local now = os.time()
    if (AI_HERD.emergencyDisabledUntil or 0) > now then return end
    AI_HERD.nextPollAt =
        now + math.max(15, math.floor(tonumber(AI_HERD.pollGap) or 15))

    if (AI_HERD.nextTelemetryAt or 0) <= now then
        AI_HERD.nextTelemetryAt = now + 300
        aiDumpSpawnTelemetry()
    end

    local onlinePlayers = 0
    local everyone = aiPlayerAnchors(false)
    if everyone ~= nil then onlinePlayers = #everyone end

    local baseMaiaCap, baseGalliCap, minCapFloor, dropFactor = 12, 12, 2, 0.5 
    local currentMaiaTarget = baseMaiaCap - math.floor(onlinePlayers * dropFactor)
    local currentGalliTarget = baseGalliCap - math.floor(onlinePlayers * dropFactor)
    
    if currentMaiaTarget < minCapFloor then currentMaiaTarget = minCapFloor end
    if currentGalliTarget < minCapFloor then currentGalliTarget = minCapFloor end
    
    AI_HERD.targetTeno = 0
    AI_HERD.targetDibble = currentMaiaTarget
    AI_HERD.targetGalli = currentGalliTarget

    if (AI_HERD.nextCfgAt or 0) <= now then
        AI_HERD.nextCfgAt = now + 60
        pcall(function() 
            loadAiHerdConfig(false) 
            AI_HERD.targetTeno = 0
            AI_HERD.targetDibble = currentMaiaTarget
            AI_HERD.targetGalli = currentGalliTarget
        end)
    end
    
    local teno, dibble, galli = aiSweepTracked()
    aiHandleDeathTimers(now, dibble, galli, currentMaiaTarget, currentGalliTarget)
    
    if AI_HERD.enabled ~= true then
        if (AI_HERD.nextCullAt or 0) <= now then
            AI_HERD.nextCullAt = now + 30
            pcall(function() aiCullTrackedHerd("disabled") end)
        end
        AI_HERD.nextTenoAt, AI_HERD.nextDibbleAt, AI_HERD.nextGalliAt = 0, 0, 0
        return
    end

    if AI_HERD.enabled == true and (AI_HERD.nextWipeAt or 0) <= 0 then
        AI_HERD.nextWipeAt = now + math.max(600, math.floor(tonumber(AI_HERD.wipeGap) or 1800))
    end
    if AI_HERD.enabled == true and (AI_HERD.nextWipeAt or 0) <= now then
        local wipeInvokeOk, wipeResult = pcall(aiCullTrackedHerd, "scheduled wipe")
        if wipeInvokeOk and wipeResult ~= false then
            AI_HERD.nextWipeAt = now + math.max(600, math.floor(tonumber(AI_HERD.wipeGap) or 1800))
            teno, dibble, galli = aiSweepTracked()
        else
            AI_HERD.nextWipeAt = now + 60
        end
    end
    
    if (AI_HERD.nextCullAt or 0) <= now then
        AI_HERD.nextCullAt = now + 45
        pcall(function() aiMaybeCullOverCap(dibble, galli) end)
        teno, dibble, galli = aiSweepTracked()
    end

    if dibble > 0 or galli > 0 then pcall(function() aiPollCalls(now) end) end
    if now < (AI_HERD.loadedAt or 0) + (AI_HERD.bootWait or 90) then return end
    
    local demandD = AI_HERD.targetDibble or 12 
    local demandG = AI_HERD.targetGalli or 12   
    if demandD <= 0 and demandG <= 0 then AI_HERD.nextDibbleAt, AI_HERD.nextGalliAt = 0, 0; return end

    local spawnDueSoon = now >= (AI_HERD.nextSpawnAt or 0)
        and (
            (dibble < demandD and now >= (AI_HERD.nextDibbleAt or 0) and (AI_HERD.nextDibbleAt or 0) > 0)
            or (galli < demandG and now >= (AI_HERD.nextGalliAt or 0) and (AI_HERD.nextGalliAt or 0) > 0)
            or ((AI_HERD.nextDibbleAt or 0) == 0 and dibble < demandD)
            or ((AI_HERD.nextGalliAt or 0) == 0 and galli < demandG)
        )
        
    local armed, _ = aiRefreshProxCache(spawnDueSoon and (AI_HERD.nextProxAt or 0) <= now)
    if AI_HERD.requirePreyProximity ~= false and not armed then
        AI_HERD.nextDibbleAt, AI_HERD.nextGalliAt = 0, 0
        local since = tonumber(AI_HERD.proxDisarmedSince) or now
        local cullAfter = math.max(120, math.floor(tonumber(AI_HERD.proxDisarmCullSec) or 300))
        if (dibble > 0 or galli > 0) and (now - since) >= cullAfter then
            if (AI_HERD.nextCullAt or 0) <= now then
                AI_HERD.nextCullAt = now + 60
                pcall(function() aiCullTrackedHerd("prey proximity idle") end)
            end
        end
        return
    end

    local targetT = AI_HERD.targetTeno or 0
    local targetD, targetG = aiEffectiveTargets()
    if targetT <= 0 and targetD <= 0 and targetG <= 0 then return end
    local function clearRespawnDebt(kind)
        AI_HERD.respawnQueue[kind] = 0
        local byKind = aiEnsureKindTelemetry(kind)
        byKind.pending_respawns = 0
    end
    if targetT > 0 and teno >= targetT then clearRespawnDebt("teno") end
    if targetD > 0 and dibble >= targetD then clearRespawnDebt("dibble") end
    if targetG > 0 and galli >= targetG then clearRespawnDebt("galli") end
    aiRecomputePendingRespawns()
    if now < (AI_HERD.nextSpawnAt or 0) then return end
    
    AI_HERD.nextTenoAt = 0
    AI_HERD.nextDibbleAt = aiEnsureFillTimer("dibble", dibble, targetD, AI_HERD.nextDibbleAt, now)
    AI_HERD.nextGalliAt = aiEnsureFillTimer("galli", galli, targetG, AI_HERD.nextGalliAt, now)
    
    local kind = nil
    if dibble < targetD and now >= (AI_HERD.nextDibbleAt or 0) and (AI_HERD.nextDibbleAt or 0) > 0 then kind = "dibble"
    elseif galli < targetG and now >= (AI_HERD.nextGalliAt or 0) and (AI_HERD.nextGalliAt or 0) > 0 then kind = "galli" end
    if kind == nil then return end
    
    aiRefreshProxCache(true)
    if AI_HERD.requirePreyProximity ~= false and AI_HERD.proxArmed ~= true then return end
    
    local kindTelemetry = aiEnsureKindTelemetry(kind)
    local pendingQueueForKind = math.max(0, math.floor(tonumber(AI_HERD.respawnQueue[kind]) or 0))
    local spawnIntent = pendingQueueForKind > 0 and "respawn" or "fill"
    local invokeOk, spawnOk, spawnMsg = pcall(spawnAiHerb, kind)
    local ok = false
    local msg = "spawn function exception"
    if invokeOk then
        ok = spawnOk
        msg = spawnMsg
    else
        msg = tostring(spawnOk or "spawn function exception")
    end

    if not ok then
        print(string.format(
            "[CRITICAL AI DEBUG] Spawn failed for %s. Reason: %s",
            tostring(kind or "unknown"),
            tostring(msg or "unknown")
        ))

        local field = aiNextAtField(kind)
        AI_HERD.consecutiveSpawnFailures = (AI_HERD.consecutiveSpawnFailures or 0) + 1
        local isCollision = msg ~= nil and (msg:find("collision", 1, true) ~= nil or msg:find("ground", 1, true) ~= nil)
        local isBadAddress = msg ~= nil and (msg:find("nullptr", 1, true) ~= nil or msg:find("bad address", 1, true) ~= nil)
        -- Possess failures (including the Maiasaura shared-controller path)
        -- are the highest-risk category for native crashes, so treat them
        -- with the same escalated backoff as collisions/bad-address instead
        -- of the weaker default backoff.
        local isPossessFailure = aiIsPossessFailureMsg(msg)
        local isEscalated = isCollision or isBadAddress or isPossessFailure
        local backoff = math.min(300, (isEscalated and 30 or 5)
            * (2 ^ math.min(AI_HERD.consecutiveSpawnFailures - 1, 6)))
        local lastFailure = AI_SPAWN_TELEMETRY.last
        if isEscalated and type(lastFailure) == "table"
            and lastFailure.x ~= nil and lastFailure.y ~= nil then
            local siteKey = aiBlacklistGridKey(lastFailure.x, lastFailure.y)
            local siteFailure = AI_SPAWN_SITE_FAILURES[siteKey]
            if type(siteFailure) == "table" then
                backoff = math.max(backoff, tonumber(siteFailure.backoffSeconds) or 0)
            end
        end
        if isEscalated then
            if field ~= nil then AI_HERD[field] = now + backoff end
            AI_HERD.nextSpawnAt = now + backoff
            print(string.format(
                "[CRITICAL AI DEBUG] Unsafe spawn location detected. Retrying %s in %d seconds.",
                tostring(kind or "unknown"), backoff
            ))
        else
            if field ~= nil then AI_HERD[field] = now + backoff end
            AI_HERD.nextSpawnAt = now + backoff
        end
        if AI_HERD.consecutiveSpawnFailures >= 5 then
            AI_HERD.emergencyDisabledUntil = now + 300
            print("[CRITICAL AI DEBUG] Spawning emergency-disabled for 300 seconds after repeated failures.")
        end
        return
    end
    AI_HERD.consecutiveSpawnFailures = 0
    AI_HERD.emergencyDisabledUntil = 0
    if spawnIntent == "respawn" and (AI_HERD.respawnQueue[kind] or 0) > 0 and (kindTelemetry.pending_respawns or 0) > 0 then
        AI_HERD.respawnQueue[kind] = AI_HERD.respawnQueue[kind] - 1
        kindTelemetry.pending_respawns = kindTelemetry.pending_respawns - 1
        kindTelemetry.respawns = (kindTelemetry.respawns or 0) + 1
        AI_SPAWN_TELEMETRY.respawns = (AI_SPAWN_TELEMETRY.respawns or 0) + 1
        aiRecomputePendingRespawns()
    end

    AI_HERD.nextSpawnAt = now + math.max(30, math.floor(tonumber(AI_HERD.spawnMinGap) or 45))
    local _, haveD, haveG = aiSweepTracked()
    AI_HERD.lastTeno, AI_HERD.lastDibble, AI_HERD.lastGalli = 0, haveD, haveG
    
    if kind == "dibble" then
        if haveD < targetD then aiArmKind("dibble", now, "spawned", aiSoftFillGap(haveD, targetD)) else AI_HERD.nextDibbleAt = 0 end
    elseif kind == "galli" then
        if haveG < targetG then aiArmKind("galli", now, "spawned", aiSoftFillGap(haveG, targetG)) else AI_HERD.nextGalliAt = 0 end
    end
end

function pollAiHerd()
    local ok, err = pcall(aiPollHerdUnsafe)
    if not ok then
        local now = os.time()
        AI_HERD.emergencyDisabledUntil = now + 300
        AI_HERD.nextSpawnAt = now + 300
        AI_HERD.sweepBusy = false
        AI_HERD.cullBusy = false
        AI_HERD.sweepPending = false
        pcall(function()
            log("ai poll exception; spawning disabled for 300 seconds: " .. tostring(err))
        end)
    end
end

pcall(function()
    math.randomseed(os.time())
end)

pcall(function()
    loadAiHerdConfig(true)
end)

-- Do not force AI_HERD.enabled = true here: loadAiHerdConfig() already
-- applied the persisted "enabled" value from ai_herd.json (defaulting to
-- true only when the file is missing/unreadable). Overwriting it
-- unconditionally would ignore an operator's saved "disabled" setting on
-- every script (re)load.

do
    local first = os.time()
        + (AI_HERD.bootWait or 90)
        + (AI_HERD.fillGap or 120)

    AI_HERD.nextTenoAt = 0

    if AI_HERD.enabled == true then
        AI_HERD.nextDibbleAt = first
        AI_HERD.nextGalliAt = first
    else
        AI_HERD.nextDibbleAt = 0
        AI_HERD.nextGalliAt = 0
    end
    AI_HERD.nextWipeAt = os.time() + math.max(600, math.floor(tonumber(AI_HERD.wipeGap) or 1800))
end


log(string.format(
    "ai herd ready AUTOMATICALLY enabled=%s target teno=0 dibble(Maia)=%d galli=%d ceiling=%d bootWait=%ds fill=%ds spawnGap=%ds",
    tostring(AI_HERD.enabled),
    AI_HERD.targetDibble or 12,
    AI_HERD.targetGalli or 12,
    AI_HERD.stabilityCeiling or 40,
    AI_HERD.bootWait or 90,
    AI_HERD.fillGap or 120,
    AI_HERD.spawnMinGap or 45
))