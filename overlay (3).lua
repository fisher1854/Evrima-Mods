--[[
  Primeval Overlay dedicated-server telemetry.

  This module is read-only with respect to game objects. All entry points are
  failure-isolated and are called from PrimevalRedeem's existing 1 Hz loop.
  AI is exported only as delayed, coarse cells meeting the configured minimum.
]]

local OVERLAY_SCHEMA = "primeval-overlay.telemetry"
local OVERLAY_SCHEMA_VERSION = 1
local OVERLAY_BUILD_AT = "2026-08-31T20:10:00Z"
local OVERLAY_CONFIG_PATH = SAVED_DIR .. "/overlay_config.json"
local OVERLAY_SNAPSHOT_PATH = SAVED_DIR .. "/overlay_snapshot.json"
local OVERLAY_DISCOVERY_PATH = SAVED_DIR .. "/overlay_discovery.json"

local OVERLAY = {
    -- Ship: on by default for Fallen Earth overlay telemetry.
    -- Disable via Saved/overlay_config.json if DS CPU needs relief.
    enabled = true,
    intervalSeconds = 8,
    maxPlayers = 128,
    aiCellSize = 100000,
    aiDelaySeconds = 20,
    aiMinCount = 1,
    maxAiObjects = 128,
    configIntervalSeconds = 15,
    discoveryEnabled = false,
    discoveryMaxProbes = 13, -- must equal #DISCOVERY_PROBES
    discoveryProbesPerTick = 1,
    discoveryCompleted = false,
    nextSnapshotAt = 0,
    nextConfigAt = 0,
    aiHistory = {},
    discovery = nil,
    consecutiveErrors = 0,
    circuitOpen = false,
    -- Live AI registry filled by NotifyOnNewObject / Possess hooks (never FindAllOf).
    aiHooked = false,
    aiPending = {},
    aiLive = {},
    aiLiveCount = 0,
    nextAiScanAt = 0,
    lastAiCells = nil,
}

local DISCOVERY_PROBES = {
    "BP_MigrationZone_C", "MigrationZone", "TIMigrationZone",
    "BP_PatrolZone_C", "PatrolZone", "TIPatrolZone",
    "BP_Gastrolith_C", "Gastrolith", "TIGastrolith",
    "BP_Salt_C", "Salt", "SaltDeposit", "TISalt",
}

local DISCOVERY_PROPERTIES = {
    "ZoneName", "DisplayName", "MigrationName", "PatrolName",
    "ResourceName", "ResourceType", "ZoneRadius", "Radius",
    "bIsActive", "IsActive", "bEnabled",
}

local function overlayClamp(n, lo, hi, fallback)
    n = tonumber(n)
    if n == nil then return fallback end
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function overlayJsonNumber(n, decimals)
    n = tonumber(n)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return "null" end
    return string.format("%." .. tostring(decimals or 2) .. "f", n)
end

local function overlayJsonValue(v)
    if v == nil then return "null" end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return overlayJsonNumber(v, 3) end
    return '"' .. jsonEscape(tostring(v)) .. '"'
end

local function overlayAtomicWrite(path, body)
    local tmp = path .. ".tmp"
    if not writeAll(tmp, body) then return false end
    local renamed = false
    pcall(function() renamed = os.rename(tmp, path) == true end)
    if not renamed then
        -- Windows CRT rename does not replace an existing destination.
        pcall(function() os.remove(path) end)
        pcall(function() renamed = os.rename(tmp, path) == true end)
    end
    if not renamed then pcall(function() os.remove(tmp) end) end
    return renamed
end

local function overlayLoadConfig()
    local body = readAll(OVERLAY_CONFIG_PATH)
    if body == nil or body == "" then
        writeAll(
            OVERLAY_CONFIG_PATH,
            '{"enabled":true,"intervalSeconds":8,"maxPlayers":128,"aiCellSize":100000,"aiDelaySeconds":20,"aiMinCount":1,"maxAiObjects":128,"discoveryEnabled":false,"discoveryMaxProbes":13,"aiPrivacyV2":true}\n'
        )
        return
    end
    local enabled = jsonReadBool(body, "enabled")
    if enabled ~= nil then OVERLAY.enabled = enabled == true end
    local discoveryEnabled = jsonReadBool(body, "discoveryEnabled")
    if discoveryEnabled == false then
        OVERLAY.discoveryEnabled = false
        OVERLAY.discoveryCompleted = false
        OVERLAY.discovery = nil
    elseif discoveryEnabled == true and not OVERLAY.discoveryCompleted then
        OVERLAY.discoveryEnabled = true
    end
    OVERLAY.intervalSeconds = math.floor(overlayClamp(
        jsonReadNumber(body, "intervalSeconds"), 3, 60, OVERLAY.intervalSeconds
    ))
    OVERLAY.maxPlayers = math.floor(overlayClamp(
        jsonReadNumber(body, "maxPlayers"), 1, 256, OVERLAY.maxPlayers
    ))
    OVERLAY.aiCellSize = math.floor(overlayClamp(
        jsonReadNumber(body, "aiCellSize"), 5000, 200000, OVERLAY.aiCellSize
    ))
    OVERLAY.aiDelaySeconds = math.floor(overlayClamp(
        jsonReadNumber(body, "aiDelaySeconds"), 20, 300, OVERLAY.aiDelaySeconds
    ))
    OVERLAY.aiMinCount = math.floor(overlayClamp(
        jsonReadNumber(body, "aiMinCount"), 1, 50, OVERLAY.aiMinCount
    ))
    OVERLAY.maxAiObjects = math.floor(overlayClamp(
        jsonReadNumber(body, "maxAiObjects"), 1, 256, OVERLAY.maxAiObjects
    ))
    OVERLAY.discoveryMaxProbes = math.floor(overlayClamp(
        jsonReadNumber(body, "discoveryMaxProbes"), 1, #DISCOVERY_PROBES, OVERLAY.discoveryMaxProbes
    ))
    -- Soften legacy AI privacy defaults so sparse herd cells still appear.
    local privacyV2 = jsonReadBool(body, "aiPrivacyV2")
    local rewrite = false
    if privacyV2 ~= true then
        OVERLAY.aiMinCount = 1
        if OVERLAY.aiDelaySeconds > 20 then OVERLAY.aiDelaySeconds = 20 end
        rewrite = true
    end
    -- Broad ~1km cells so the overlay shows fuzzy activity, not pinpoints.
    if OVERLAY.aiCellSize < 100000 then
        OVERLAY.aiCellSize = 100000
        rewrite = true
    end
    if OVERLAY.aiDelaySeconds < 20 then
        OVERLAY.aiDelaySeconds = 20
        rewrite = true
    end
    if OVERLAY.maxAiObjects < 128 then
        OVERLAY.maxAiObjects = 128
        rewrite = true
    end
    if rewrite then
        writeAll(
            OVERLAY_CONFIG_PATH,
            string.format(
                '{"enabled":%s,"intervalSeconds":%d,"maxPlayers":%d,"aiCellSize":%d,"aiDelaySeconds":%d,"aiMinCount":%d,"maxAiObjects":%d,"discoveryEnabled":%s,"discoveryMaxProbes":%d,"aiPrivacyV2":true}\n',
                OVERLAY.enabled and "true" or "false",
                OVERLAY.intervalSeconds,
                OVERLAY.maxPlayers,
                OVERLAY.aiCellSize,
                OVERLAY.aiDelaySeconds,
                OVERLAY.aiMinCount,
                OVERLAY.maxAiObjects,
                OVERLAY.discoveryEnabled and "true" or "false",
                OVERLAY.discoveryMaxProbes
            )
        )
    end
    OVERLAY.circuitOpen = false
    OVERLAY.consecutiveErrors = 0
end

local function overlayPrimeJson(steam)
    local state = (lastPrimeState or {})[steam]
    if state == nil then return "null" end
    local bits = state.bits or {}
    local progress = state.progress or {}
    local migration = tonumber(progress[2]) or (bits[2] and 2 or 0)
    local patrol = tonumber(progress[4]) or (bits[4] and 4 or 0)
    return string.format(
        '{"have":%d,"migration":{"current":%d,"required":2,"completed":%s},"patrol":{"current":%d,"required":4,"completed":%s}}',
        tonumber(state.have) or 0,
        migration,
        bits[2] and "true" or "false",
        patrol,
        bits[4] and "true" or "false"
    )
end

local function overlayPlayerJson(ctrl, steam)
    local pawn = livePawnFromCtrl(ctrl)
    if not isLiveDinoPawn(pawn) then return nil end
    local loc = readLocation(pawn)
    if loc == nil or loc.x == nil then return nil end
    local classPath = classPathOf(pawn)
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" })
    local health = tryNumber(pawn, { "GetHealth", "Health", "GetCurrentHealth", "CurrentHealth" })
    local maxHealth = tryNumber(pawn, { "GetMaxHealth", "MaxHealth" })
    return string.format(
        '{"steam":"%s","x":%s,"y":%s,"z":%s,"yaw":%s,"species":"%s","growth":%s,"health":%s,"maxHealth":%s,"prime":%s}',
        jsonEscape(steam),
        overlayJsonNumber(loc.x, 1),
        overlayJsonNumber(loc.y, 1),
        overlayJsonNumber(loc.z, 1),
        overlayJsonNumber(loc.yaw, 1),
        jsonEscape(speciesKey(classPath)),
        overlayJsonNumber(growth, 4),
        overlayJsonNumber(health, 2),
        overlayJsonNumber(maxHealth, 2),
        overlayPrimeJson(steam)
    )
end

local function overlayCollectPlayers()
    local rows = {}
    local seen = {}
    local knownProbes = 0
    local function consider(ctrl)
        if #rows >= OVERLAY.maxPlayers or ctrl == nil then return end
        local steam = getControllerSteamId(ctrl)
        if steam == "" or seen[steam] then return end
        seen[steam] = true
        local row = overlayPlayerJson(ctrl, steam)
        if row ~= nil then rows[#rows + 1] = row end
    end
    -- Known controllers are direct lookups; never use the helper's FindAllOf
    -- fallback from telemetry.
    for steam, _ in pairs(knownSteams or {}) do
        if #rows >= OVERLAY.maxPlayers or knownProbes >= OVERLAY.maxPlayers then break end
        knownProbes = knownProbes + 1
        consider(controllerForSteam(steam))
    end
    local gsNames = {
        "TISurvivalGameState", "BP_SurvivalGameState_C",
        "TIGameStateBase", "GameStateBase",
    }
    for _, name in ipairs(gsNames) do
        local gs
        pcall(function() gs = FindFirstOf(name) end)
        if gs ~= nil then
            local arr
            pcall(function() arr = gs.PlayerArray end)
            local n = 0
            if arr ~= nil then
                pcall(function() n = arr:GetArrayNum() end)
                if n == 0 then pcall(function() n = arr:Num() end) end
                if n == 0 then pcall(function() n = #arr end) end
            end
            n = math.min(tonumber(n) or 0, OVERLAY.maxPlayers)
            for i = 0, n - 1 do
                local ps
                pcall(function() ps = arr:Get(i) end)
                if ps == nil then pcall(function() ps = arr[i] end) end
                if ps == nil then pcall(function() ps = arr[i + 1] end) end
                consider(ctrlFromPlayerState(ps))
            end
            break
        end
    end
    table.sort(rows)
    return rows
end

local function overlayPawnHasSteam(pawn)
    if pawn == nil then return false end
    local ctrl
    pcall(function() ctrl = pawn:GetController() end)
    if ctrl == nil then pcall(function() ctrl = pawn.Controller end) end
    if ctrl == nil then return false end
    return getControllerSteamId(ctrl) ~= ""
end

local function overlayCtrlHasSteam(ctrl)
    if ctrl == nil then return false end
    return getControllerSteamId(ctrl) ~= ""
end

local function overlayUnwrap(param)
    if param == nil then return nil end
    local value = param
    pcall(function()
        if param.get ~= nil then value = param:get() end
    end)
    return value
end

local function overlayAiRemember(pawn)
    if pawn == nil then return end
    local addr
    pcall(function() addr = pawn:GetAddress() end)
    if addr == nil or addr == 0 then return end
    if OVERLAY.aiLive[addr] ~= nil then return end
    if OVERLAY.aiLiveCount >= (OVERLAY.maxAiObjects * 2) then return end
    OVERLAY.aiLive[addr] = pawn
    OVERLAY.aiLiveCount = (OVERLAY.aiLiveCount or 0) + 1
end

local function overlayAiQueue(obj)
    -- Hooks stay installed after telemetry is disabled; stop buffering then.
    if obj == nil or OVERLAY.enabled ~= true then return end
    local pending = OVERLAY.aiPending
    if #pending >= 512 then return end
    pending[#pending + 1] = obj
end

local function overlayAiDrainPending()
    local pending = OVERLAY.aiPending
    if pending == nil or #pending == 0 then return end
    OVERLAY.aiPending = {}
    for i = 1, #pending do
        overlayAiRemember(pending[i])
    end
end

local function overlayAiPruneLive()
    local live = OVERLAY.aiLive or {}
    local keep = {}
    local count = 0
    for addr, pawn in pairs(live) do
        if count >= OVERLAY.maxAiObjects then break end
        local ok = false
        if pawn ~= nil then
            if aiObjOk == nil or aiObjOk(pawn) then
                if aiPawnDead == nil or not aiPawnDead(pawn) then
                    if not overlayPawnHasSteam(pawn) then
                        ok = true
                    end
                end
            end
        end
        if ok then
            keep[addr] = pawn
            count = count + 1
        end
    end
    OVERLAY.aiLive = keep
    OVERLAY.aiLiveCount = count
end

local function overlayAiOnPossess(_context, inPawn)
    -- Keep this callback tiny: resolve params and queue. Validation happens on scan.
    local ok, err = pcall(function()
        local ctrl = overlayUnwrap(_context)
        local pawn = overlayUnwrap(inPawn)
        if pawn == nil then return end
        if overlayCtrlHasSteam(ctrl) then return end
        overlayAiQueue(pawn)
    end)
    if not ok then
        -- Never let hook errors escape into the game thread.
        pcall(function() log("overlay AI possess hook: " .. tostring(err)) end)
    end
end

local function overlayAiInstallHooks()
    -- Do not install NotifyOnNewObject / Possess hooks while telemetry is off.
    if OVERLAY.enabled ~= true then return end
    if OVERLAY.aiHooked then return end
    OVERLAY.aiHooked = true

    -- Construction notify: inheritance-aware, no GUObjectArray walk.
    -- Only queue the object — never touch controllers/location here.
    pcall(function()
        NotifyOnNewObject("/Script/TheIsle.TIDinosaurCharacter", function(obj)
            overlayAiQueue(obj)
        end)
    end)

    -- Possession is the reliable moment an AI actually controls a body (dinos + ambient).
    local possessPaths = {
        "/Script/Engine.Controller:Possess",
        "/Script/Engine.AIController:OnPossess",
        "/Script/Engine.Controller:OnPossess",
    }
    for _, path in ipairs(possessPaths) do
        pcall(function()
            -- Pre no-op, post registers the possessed pawn.
            RegisterHook(path, function() end, overlayAiOnPossess)
        end)
    end
    pcall(function()
        RegisterHook("/Script/Engine.Pawn:PossessedBy", function(_context, _controller)
            local ok, err = pcall(function()
                local pawn = overlayUnwrap(_context)
                local ctrl = overlayUnwrap(_controller)
                if pawn == nil then return end
                if overlayCtrlHasSteam(ctrl) then return end
                overlayAiQueue(pawn)
            end)
            if not ok then
                pcall(function() log("overlay AI possessedby hook: " .. tostring(err)) end)
            end
        end)
    end)
    log("overlay AI registry hooks installed (NotifyOnNewObject + Possess; no FindAllOf)")
end

local function overlayAddAiPawn(cells, seenAddr, pawn, seen)
    if seen >= OVERLAY.maxAiObjects or pawn == nil then return seen end
    local addr
    pcall(function() addr = pawn:GetAddress() end)
    if addr == nil or addr == 0 or seenAddr[addr] then return seen end
    if aiObjOk ~= nil and not aiObjOk(pawn) then return seen end
    if aiPawnDead ~= nil and aiPawnDead(pawn) then return seen end
    if overlayPawnHasSteam(pawn) then return seen end
    local loc = readLocation(pawn)
    if loc == nil or loc.x == nil or loc.y == nil then return seen end
    seenAddr[addr] = true
    local cx = math.floor(loc.x / OVERLAY.aiCellSize)
    local cy = math.floor(loc.y / OVERLAY.aiCellSize)
    local key = tostring(cx) .. ":" .. tostring(cy)
    local cell = cells[key]
    if cell == nil then
        cell = { x = cx, y = cy, count = 0 }
        cells[key] = cell
    end
    cell.count = cell.count + 1
    return seen + 1
end

local function overlayScanAllAiCells()
    local cells = {}
    local seenAddr = {}
    local seen = 0

    overlayAiDrainPending()
    overlayAiPruneLive()

    -- Dedicated herd tracker (always).
    local tracked = (AI_HERD and AI_HERD.tracked) or {}
    for _, row in ipairs(tracked) do
        seen = overlayAddAiPawn(cells, seenAddr, row and row.pawn or nil, seen)
        if seen >= OVERLAY.maxAiObjects then return cells end
    end

    -- Hook-fed world AI registry (wild + ambient + any AI possessed pawn).
    for _, pawn in pairs(OVERLAY.aiLive or {}) do
        seen = overlayAddAiPawn(cells, seenAddr, pawn, seen)
        if seen >= OVERLAY.maxAiObjects then break end
    end
    return cells
end

local function overlayCaptureAiCells(now)
    -- Refresh on a slower cadence than player snapshots.
    if (OVERLAY.nextAiScanAt or 0) <= now then
        OVERLAY.nextAiScanAt = now + math.max(12, math.floor(OVERLAY.aiDelaySeconds or 20))
        local ok, result = pcall(overlayScanAllAiCells)
        if ok and type(result) == "table" then
            OVERLAY.lastAiCells = result
        else
            OVERLAY.lastAiCells = OVERLAY.lastAiCells or {}
            if not ok then
                log("overlay AI scan failed: " .. tostring(result))
            end
        end
    end
    local cells = OVERLAY.lastAiCells or {}
    OVERLAY.aiHistory[#OVERLAY.aiHistory + 1] = { at = now, cells = cells }
    while #OVERLAY.aiHistory > 0
        and now - (OVERLAY.aiHistory[1].at or now) > (OVERLAY.aiDelaySeconds + 120) do
        table.remove(OVERLAY.aiHistory, 1)
    end
end

local function overlayDelayedAiJson(now)
    local chosen = nil
    local cutoff = now - OVERLAY.aiDelaySeconds
    for _, sample in ipairs(OVERLAY.aiHistory) do
        if sample.at <= cutoff and (chosen == nil or sample.at > chosen.at) then
            chosen = sample
        end
    end
    if chosen == nil then return {}, nil end
    local rows = {}
    for _, cell in pairs(chosen.cells or {}) do
        if (cell.count or 0) >= OVERLAY.aiMinCount then
            rows[#rows + 1] = string.format(
                '{"cellX":%d,"cellY":%d,"count":%d}',
                cell.x, cell.y, cell.count
            )
        end
    end
    table.sort(rows)
    return rows, chosen.at
end

local function overlayWriteSnapshot(now)
    local players = overlayCollectPlayers()
    overlayCaptureAiCells(now)
    local aiRows, aiObservedAt = overlayDelayedAiJson(now)
    local body = string.format(
        '{"schema":"%s","schemaVersion":%d,"buildAt":"%s","generatedAt":%d,"intervalSeconds":%d,"players":[%s],"ai":{"privacy":{"cellSize":%d,"delaySeconds":%d,"minCount":%d},"observedAt":%s,"cells":[%s]}}\n',
        OVERLAY_SCHEMA,
        OVERLAY_SCHEMA_VERSION,
        OVERLAY_BUILD_AT,
        now,
        OVERLAY.intervalSeconds,
        table.concat(players, ","),
        OVERLAY.aiCellSize,
        OVERLAY.aiDelaySeconds,
        OVERLAY.aiMinCount,
        aiObservedAt ~= nil and tostring(aiObservedAt) or "null",
        table.concat(aiRows, ",")
    )
    return overlayAtomicWrite(OVERLAY_SNAPSHOT_PATH, body)
end

local function overlayObjectName(obj)
    local name = ""
    pcall(function() name = tostring(obj:GetFullName()) end)
    if name == "" or looksLikeDump(name) then
        pcall(function() name = tostring(obj:GetName()) end)
    end
    return name
end

local function overlayDiscoveryRow(probe, obj)
    if obj == nil then return nil end
    local loc = readLocation(obj)
    local props = {}
    for _, field in ipairs(DISCOVERY_PROPERTIES) do
        local value
        pcall(function() value = obj[field] end)
        if value ~= nil then
            local n = numericValue(value)
            local b = nil
            if value == true or value == false then b = value end
            local s = safeString(value)
            local encoded = nil
            if b ~= nil then encoded = overlayJsonValue(b)
            elseif n ~= nil then encoded = overlayJsonValue(n)
            elseif s ~= "" and #s <= 160 then encoded = overlayJsonValue(s) end
            if encoded ~= nil then
                props[#props + 1] = '"' .. jsonEscape(field) .. '":' .. encoded
            end
        end
    end
    table.sort(props)
    return string.format(
        '{"probe":"%s","name":"%s","x":%s,"y":%s,"z":%s,"properties":{%s}}',
        jsonEscape(probe),
        jsonEscape(overlayObjectName(obj)),
        overlayJsonNumber(loc and loc.x, 1),
        overlayJsonNumber(loc and loc.y, 1),
        overlayJsonNumber(loc and loc.z, 1),
        table.concat(props, ",")
    )
end

local function overlayDiscoveryTick(now)
    if OVERLAY.discoveryEnabled ~= true then
        OVERLAY.discovery = nil
        return
    end
    if OVERLAY.discovery == nil then
        OVERLAY.discovery = { next = 1, rows = {}, startedAt = now }
    end
    local state = OVERLAY.discovery
    for _ = 1, OVERLAY.discoveryProbesPerTick do
        if state.next > OVERLAY.discoveryMaxProbes then break end
        local probe = DISCOVERY_PROBES[state.next]
        state.next = state.next + 1
        local obj
        pcall(function() obj = FindFirstOf(probe) end)
        local row = overlayDiscoveryRow(probe, obj)
        if row ~= nil then state.rows[#state.rows + 1] = row end
    end
    if state.next > OVERLAY.discoveryMaxProbes then
        local body = string.format(
            '{"schema":"primeval-overlay.discovery","schemaVersion":1,"buildAt":"%s","generatedAt":%d,"startedAt":%d,"bounded":{"probeCount":%d,"probesPerTick":%d,"firstMatchOnly":true},"matches":[%s]}\n',
            OVERLAY_BUILD_AT,
            now,
            state.startedAt,
            OVERLAY.discoveryMaxProbes,
            OVERLAY.discoveryProbesPerTick,
            table.concat(state.rows, ",")
        )
        if not overlayAtomicWrite(OVERLAY_DISCOVERY_PATH, body) then
            error("discovery write failed")
        end
        -- One export per false -> true config transition, never a continuous scan.
        OVERLAY.discoveryEnabled = false
        OVERLAY.discoveryCompleted = true
        OVERLAY.discovery = nil
    end
end

function pollOverlayTelemetry()
    local now = os.time()
    if now >= (OVERLAY.nextConfigAt or 0) then
        OVERLAY.nextConfigAt = now + OVERLAY.configIntervalSeconds
        pcall(overlayLoadConfig)
    end
    if OVERLAY.enabled ~= true then
        return
    end
    if OVERLAY.circuitOpen then return end
    local ok, err = pcall(function()
        overlayAiInstallHooks()
        overlayDiscoveryTick(now)
        if now < (OVERLAY.nextSnapshotAt or 0) then return end
        OVERLAY.nextSnapshotAt = now + OVERLAY.intervalSeconds
        if not overlayWriteSnapshot(now) then error("snapshot write failed") end
    end)
    if ok then
        OVERLAY.consecutiveErrors = 0
        return
    end
    OVERLAY.consecutiveErrors = (OVERLAY.consecutiveErrors or 0) + 1
    if OVERLAY.consecutiveErrors >= 3 then
        OVERLAY.circuitOpen = true
        log("overlay telemetry circuit opened after repeated failures: " .. tostring(err))
    end
end

-- Load config first; only install AI hooks if telemetry is enabled.
pcall(overlayLoadConfig)
if OVERLAY.enabled == true then
    pcall(overlayAiInstallHooks)
end
