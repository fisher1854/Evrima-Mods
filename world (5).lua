--[[ PrimevalRedeem world helpers: JSON, pawns, snapshot/apply, teleport. ]]

function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(msg)))
end

madeDirs = madeDirs or {}

function ensureDir(path)
    if path == nil or path == "" or madeDirs[path] then return end
    -- Boot only. Never call this from the 1s game-thread loop — os.execute
    -- blocks the dedicated server and rubberbands everyone.
    pcall(function()
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    end)
    madeDirs[path] = true
end

function jsonEscape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    return s
end

function jsonReadString(body, fieldName)
    return string.match(body or "", '"' .. fieldName .. '"%s*:%s*"([^"]*)"')
end

function jsonReadNumber(body, fieldName)
    -- FIXED: Broadened the match pattern to capture both floating decimals and flat integers safely
    local pattern = '"' .. fieldName .. '"%s*:%s*(-?%d+%.?%d*)'
    local match = string.match(body or "", pattern)
    if match == nil then
        -- Fallback check for flat integers without decimals (like 0, 12, 45)
        match = string.match(body or "", '"' .. fieldName .. '"%s*:%s*(-?%d+)')
    end
    return tonumber(match)
end

function jsonReadBool(body, fieldName)
    local quoted = jsonReadString(body, fieldName)
    if quoted == "true" then return true end
    if quoted == "false" then return false end
    -- Lua patterns have no | alternation; match the word after the colon.
    local raw = string.match(body or "", '"' .. fieldName .. '"%s*:%s*(%a+)')
    if raw == "true" then return true end
    if raw == "false" then return false end
    return nil
end

-- Parse [{ "x":.., "y":.., "z":.., "radius":.. }, ...] (flat objects only).
function jsonReadWorldRegions(body, fieldName)
    local out = {}
    if body == nil or fieldName == nil or fieldName == "" then
        return out
    end
    
    -- FIXED: Broadened pattern to isolate regions safely without breaking memory arrays on empty [] brackets
    local arr = string.match(body or "", '"' .. fieldName .. '"%s*:%s*%[(.-)%]')
    if arr == nil or arr == "" or arr:gsub("%s+", "") == "" then
        -- Return a clean, isolated fresh table so it cannot bleed back into your active herd targets
        return {}
    end
    
    for obj in string.gmatch(arr, "%b{}") do
        -- FIXED: Ensured region coordinates support both flat integers and explicit float decimals safely
        local x = tonumber(string.match(obj, '"x"%s*:%s*(-?%d+%.?%d*)') or string.match(obj, '"x"%s*:%s*(-?%d+)'))
        local y = tonumber(string.match(obj, '"y"%s*:%s*(-?%d+%.?%d*)') or string.match(obj, '"y"%s*:%s*(-?%d+)'))
        local z = tonumber(string.match(obj, '"z"%s*:%s*(-?%d+%.?%d*)') or string.match(obj, '"z"%s*:%s*(-?%d+)')) or 0
        local radius = tonumber(string.match(obj, '"radius"%s*:%s*(-?%d+%.?%d*)') or string.match(obj, '"radius"%s*:%s*(-?%d+)'))
        
        if x ~= nil and y ~= nil and radius ~= nil and radius > 0 then
            out[#out + 1] = { x = x, y = y, z = z, radius = radius }
        end
    end
    return out
end

function appendLine(path, line)
    local f = io.open(path, "ab")
    if f == nil then return false end
    local writeOk, wrote = pcall(function()
        local first = f:write(line)
        local second = f:write("\n")
        return first ~= nil and second ~= nil
    end)
    local closeOk, closed = pcall(function() return f:close() end)
    return writeOk and wrote == true and closeOk and closed ~= nil
end

function readAll(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

function writeAll(path, body)
    local f = io.open(path, "wb")
    if f == nil then return false end
    local writeOk, wrote = pcall(function()
        return f:write(body or "") ~= nil
    end)
    local closeOk, closed = pcall(function() return f:close() end)
    return writeOk and wrote == true and closeOk and closed ~= nil
end

function deleteFile(path)
    if path == nil or path == "" then return end
    pcall(function() os.remove(path) end)
end

function findGameMode()
    local candidates = { "BP_SurvivalGameMode_C", "TISurvivalGameMode", "TIGameModeBase", "GameModeBase" }
    for _, name in ipairs(candidates) do
        local gm
        pcall(function() gm = FindFirstOf(name) end)
        if gm ~= nil then return gm end
    end
    return nil
end

function livePawnFromCtrl(ctrl)
    if ctrl == nil then return nil end
    local pawn
    pcall(function() pawn = ctrl:K2_GetPawn() end)
    if pawn == nil then return nil end
    local addr
    pcall(function() addr = pawn:GetAddress() end)
    if addr == nil or addr == 0 then return nil end
    return pawn
end

function looksLikeDump(s)
    if type(s) ~= "string" or s == "" then return true end
    if s:find("^UObject") or s:find("^FString") or s:find("^FText") or s:find("^FName") then return true end
    if s:find("^TrivialObject") or s:find("^userdata") or s:find("^table:") or s:find("^function:") then return true end
    if s:find("00000000") and s:find(":") then return true end
    return false
end

function safeString(value)
    if value == nil then return "" end
    local inner = value
    pcall(function() inner = value:get() end)
    if inner == nil then inner = value end
    local names = { "ToString", "GetDisplayName", "GetName", "GetNameString" }
    for _, fn in ipairs(names) do
        local t
        pcall(function() t = inner[fn](inner) end)
        if type(t) == "string" and not looksLikeDump(t) then return t end
        pcall(function() t = value[fn](value) end)
        if type(t) == "string" and not looksLikeDump(t) then return t end
    end
    local s
    pcall(function() s = tostring(inner) end)
    if type(s) == "string" and not looksLikeDump(s) then return s end
    return ""
end

function numericValue(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    if type(value) == "boolean" then
        if value then return 1 else return 0 end
    end
    local n = tonumber(value)
    if n ~= nil then return n end
    local inner = value
    pcall(function() inner = value:get() end)
    if inner == nil then inner = value end
    local cand
    pcall(function() cand = inner.Value end)
    n = tonumber(cand)
    if n ~= nil then return n end
    pcall(function() cand = inner:GetValue() end)
    n = tonumber(cand)
    if n ~= nil then return n end
    pcall(function() cand = inner:GetUnderlyingValue() end)
    n = tonumber(cand)
    if n ~= nil then return n end
    local s = safeString(inner)
    n = tonumber(s)
    if n ~= nil then return n end
    return nil
end

function normalizeSteam(s)
    if s == nil then return "" end
    s = tostring(s)
    local id = string.match(s, "(7656%d+)")
    if id ~= nil then return id end
    if s:find("^%d%d%d%d%d%d%d%d%d+$") then return s end
    return ""
end

function getControllerSteamId(ctrl)
    if ctrl == nil then return "" end
    local sId
    pcall(function() sId = ctrl:GetSteamId() end)
    local s = normalizeSteam(safeString(sId))
    if s ~= "" then
        knownSteams[s] = true
        return s
    end
    local field
    pcall(function() field = ctrl.SteamId end)
    s = normalizeSteam(safeString(field))
    if s ~= "" then
        knownSteams[s] = true
        return s
    end
    return ""
end

function controllerForSteam(steam)
    if steam == nil or steam == "" then return nil end
    local gm = findGameMode()
    if gm == nil then return nil end
    local ctrl
    pcall(function() ctrl = gm:GetControllerBySteamId(steam) end)
    return ctrl
end

-- Admin-window pipeline. ServerGrow / ServerSetHunger only take effect when
-- the *calling* controller is admin. Call from every online controller so a
-- staff alt or the buyer (if they are admin) can grow any target.
function eachLiveController(fn)
    if fn == nil then return 0 end
    local n = 0
    forEachPlayerCtrl(function(ctrl, steam)
        if ctrl == nil then return end
        n = n + 1
        fn(ctrl, steam)
    end)
    return n
end

function invokeAdminGrow(targetSteam, percent)
    targetSteam = tostring(targetSteam or "")
    percent = tonumber(percent) or 70
    if targetSteam == "" then return false end
    local gm = findGameMode()
    local callers = 0
    eachLiveController(function(ctrl)
        callers = callers + 1
        pcall(function() ctrl:ServerGrow(targetSteam, "", percent) end)
        if gm ~= nil then
            pcall(function() gm:Grow(ctrl, targetSteam, "", percent) end)
        end
    end)
    log(string.format("admin grow ServerGrow pct=%s callers=%s", tostring(percent), tostring(callers)))
    return callers > 0
end

function invokeAdminVitals(targetSteam)
    targetSteam = tostring(targetSteam or "")
    if targetSteam == "" then return false end
    local gm = findGameMode()
    local callers = 0
    eachLiveController(function(ctrl)
        callers = callers + 1
        pcall(function() ctrl:ServerSetHunger(targetSteam, "", 75.0) end)
        pcall(function() ctrl:ServerSetNutrientSlotValue(targetSteam, "", true, false, false, 50.0) end)
        pcall(function() ctrl:ServerSetNutrientSlotValue(targetSteam, "", false, true, false, 50.0) end)
        pcall(function() ctrl:ServerSetNutrientSlotValue(targetSteam, "", false, false, true, 50.0) end)
        if gm ~= nil then
            pcall(function() gm:SetHunger(ctrl, targetSteam, "", 75.0) end)
            pcall(function() gm:SetNutrientSlotValue(ctrl, targetSteam, "", true, false, false, 50.0) end)
            pcall(function() gm:SetNutrientSlotValue(ctrl, targetSteam, "", false, true, false, 50.0) end)
            pcall(function() gm:SetNutrientSlotValue(ctrl, targetSteam, "", false, false, true, 50.0) end)
        end
    end)
    log("admin vitals callers=" .. tostring(callers))
    return callers > 0
end

function pawnMaxHunger(pawn)
    return tryNumber(pawn, {
        "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
        "GetMaximumHunger", "MaximumHunger",
    })
end

function ensureAdultMaxHunger(pawn, snap, oldMax)
    if pawn == nil then return false end
    local live = pawnMaxHunger(pawn)
    local want = snap and tonumber(snap.maxHunger)
    if want == nil or want <= 1.5 then
        local species = speciesKey(classPathOf(pawn))
        if snap ~= nil then
            local fromSnap = snap.classPath ~= nil and snap.classPath ~= "" and snap.classPath or snap.species
            if fromSnap ~= nil and fromSnap ~= "" then
                species = speciesKey(fromSnap)
            end
        end
        local cap = capForSpecies(species, (snap and snap.growth) or 0.70)
        if cap ~= nil then
            want = tonumber(cap.maxHunger)
            if snap ~= nil and snap.maxFood == nil then
                snap.maxFood = cap.maxFood
            end
        end
    end
    if want ~= nil and want > 1.5 then
        pcall(function() pawn:SetMaxHunger(want) end)
        pcall(function() pawn.MaxHunger = want end)
        live = pawnMaxHunger(pawn)
        log(string.format("SetMaxHunger fallback want=%s live=%s", tostring(want), tostring(live)))
        if live ~= nil and math.abs(live - want) <= math.max(1, want * 0.12) then
            return true
        end
    end
    if live ~= nil and oldMax ~= nil and oldMax > 1.5 and live > (oldMax * 1.05) then
        return true
    end
    return live ~= nil and want ~= nil and live > 1.5
end

function speciesCapKey(species, pct)
    return string.lower(tostring(species or "")) .. "_" .. tostring(math.floor(tonumber(pct) or 70))
end

function loadSpeciesCaps()
    SPECIES_CAPS = SPECIES_CAPS or {}
    local body = readAll(SPECIES_CAPS_PATH or (SAVED_DIR .. "/species_caps.ndjson")) or ""
    for line in body:gmatch("[^\r\n]+") do
        local species = jsonReadString(line, "species")
        local pct = jsonReadNumber(line, "pct") or 70
        local maxHunger = jsonReadNumber(line, "maxHunger")
        if species ~= nil and species ~= "" and maxHunger ~= nil and maxHunger > 1.5 then
            SPECIES_CAPS[speciesCapKey(species, pct)] = {
                species = string.lower(species),
                pct = pct,
                maxHunger = maxHunger,
                maxFood = jsonReadNumber(line, "maxFood"),
                at = jsonReadNumber(line, "at"),
            }
        end
    end
    if PRIMEVAL_GROWTH_CAPS ~= nil then
        for species, row in pairs(PRIMEVAL_GROWTH_CAPS) do
            local key = speciesCapKey(species, 70)
            if SPECIES_CAPS[key] == nil and row ~= nil and tonumber(row.maxHunger) ~= nil then
                SPECIES_CAPS[key] = {
                    species = string.lower(species),
                    pct = 70,
                    maxHunger = tonumber(row.maxHunger),
                    maxFood = tonumber(row.maxFood),
                    at = 0,
                }
            end
        end
    end
end

function saveSpeciesCaps()
    local path = SPECIES_CAPS_PATH or (SAVED_DIR .. "/species_caps.ndjson")
    local lines = {}
    for _, row in pairs(SPECIES_CAPS or {}) do
        if row ~= nil and row.species ~= nil and tonumber(row.maxHunger) ~= nil then
            lines[#lines + 1] = string.format(
                '{"species":"%s","pct":%s,"maxHunger":%s,"maxFood":%s,"at":%d}',
                jsonEscape(row.species),
                tostring(math.floor(tonumber(row.pct) or 70)),
                tostring(row.maxHunger),
                row.maxFood ~= nil and tostring(row.maxFood) or "null",
                tonumber(row.at) or 0
            )
        end
    end
    table.sort(lines)
    writeAll(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

function lookupSpeciesCap(species, pct)
    pct = math.floor(tonumber(pct) or 70)
    local names = { string.lower(tostring(species or "")) }
    if PRIMEVAL_ALIASES ~= nil then
        local key = names[1]
        local canon = PRIMEVAL_ALIASES[key]
        if canon ~= nil then
            names[#names + 1] = string.lower(canon)
        end
        for alias, name in pairs(PRIMEVAL_ALIASES) do
            if string.lower(tostring(name)) == key or string.lower(tostring(alias)) == key then
                names[#names + 1] = string.lower(alias)
                names[#names + 1] = string.lower(name)
            end
        end
    end
    for _, name in ipairs(names) do
        if name ~= "" then
            local direct = (SPECIES_CAPS or {})[speciesCapKey(name, pct)]
            if direct ~= nil then return direct end
            if pct == 70 and PRIMEVAL_GROWTH_CAPS ~= nil and PRIMEVAL_GROWTH_CAPS[name] ~= nil then
                local row = PRIMEVAL_GROWTH_CAPS[name]
                if tonumber(row.maxHunger) ~= nil then
                    return {
                        species = name,
                        pct = 70,
                        maxHunger = tonumber(row.maxHunger),
                        maxFood = tonumber(row.maxFood),
                    }
                end
            end
        end
    end
    return nil
end

function capForSpecies(species, growth)
    local pct = math.floor(((tonumber(growth) or 0.70) * 100) + 0.5)
    if pct < 1 then pct = 70 end
    local row = lookupSpeciesCap(species, 70)
    if row == nil then return nil end
    local scale = 1
    if pct ~= 70 then
        scale = pct / 70
    end
    return {
        species = row.species or species,
        pct = pct,
        maxHunger = (tonumber(row.maxHunger) or 0) * scale,
        maxFood = row.maxFood ~= nil and ((tonumber(row.maxFood) or 0) * scale) or nil,
    }
end

function applyCapMaxes(pawn, species, growth)
    if pawn == nil then return false, "no pawn" end
    local cap = capForSpecies(species, growth)
    if cap == nil or (tonumber(cap.maxHunger) or 0) <= 1.5 then
        return false, "no 70% cap for " .. tostring(species)
    end
    local g = tonumber(growth) or 0.70
    if g > 1 then g = g / 100 end
    if g < 0.01 then g = 0.70 end
    pcall(function() pawn:SetGrowth(g) end)
    pcall(function() pawn:SetMaxHunger(cap.maxHunger) end)
    pcall(function() pawn.MaxHunger = cap.maxHunger end)
    if cap.maxFood ~= nil and cap.maxFood > 1.5 then
        pcall(function() pawn:SetMaxFoodValue(cap.maxFood) end)
        pcall(function() pawn.MaxFoodValue = cap.maxFood end)
        pcall(function() pawn:SetMaxFood(cap.maxFood) end)
    end
    log(string.format(
        "cap apply %s g=%.2f Hmax=%s Fmax=%s liveH=%s",
        tostring(species), g, tostring(cap.maxHunger), tostring(cap.maxFood),
        tostring(pawnMaxHunger(pawn))
    ))
    return true, cap
end

function applyDirectBuyStats(pawn, snap, growth)
    if pawn == nil then return false end
    local species = speciesKey(classPathOf(pawn))
    if snap ~= nil then
        local fromSnap = snap.classPath ~= nil and snap.classPath ~= "" and snap.classPath or snap.species
        if fromSnap ~= nil and fromSnap ~= "" then
            species = speciesKey(fromSnap)
        end
    end
    local g = tonumber(growth)
    if g == nil and snap ~= nil then g = tonumber(snap.growth) end
    if g == nil or g < 0.01 then g = 0.70 end
    if g > 1 then g = g / 100 end
    local ok = applyCapMaxes(pawn, species, g)
    if snap ~= nil then
        if tonumber(snap.maxHunger) == nil then
            local cap = capForSpecies(species, g)
            if cap ~= nil then
                snap.maxHunger = cap.maxHunger
                snap.maxFood = cap.maxFood
            end
        end
        refillBuyVitals(pawn, snap)
    else
        refillBuyVitals(pawn, { hunger = 0.75 })
    end
    return ok == true
end

function recordSpeciesCap(pawn, source)
    if pawn == nil then return nil, "no pawn" end
    local species = speciesKey(classPathOf(pawn))
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" })
    local maxHunger = pawnMaxHunger(pawn)
    local maxFood = tryNumber(pawn, {
        "GetMaxFoodValue", "MaxFoodValue", "GetMaxFood", "MaxFood",
    })
    if species == nil or species == "" then
        return nil, "unknown species"
    end
    if growth == nil or growth < 0.60 or growth > 0.80 then
        return nil, string.format("growth is %s — admin-grow to 70%% first", tostring(growth))
    end
    if maxHunger == nil or maxHunger <= 1.5 then
        return nil, "MaxHunger not ready"
    end
    -- SetGrowth-only leaves MaxHunger juvenile while MaxFood jumps.
    -- Skip that stale pair so we do not record a junk cap.
    if maxFood ~= nil and maxFood > 80 and maxHunger < (maxFood * 0.20) then
        return nil, string.format("MaxHunger still juvenile Hmax=%s Fmax=%s", tostring(maxHunger), tostring(maxFood))
    end
    local pct = math.floor((growth * 100) + 0.5)
    if pct >= 66 and pct <= 74 then pct = 70 end
    local row = {
        species = species,
        pct = pct,
        maxHunger = maxHunger,
        maxFood = maxFood,
        at = os.time(),
        source = tostring(source or "sample"),
    }
    SPECIES_CAPS[speciesCapKey(species, pct)] = row
    saveSpeciesCaps()
    log(string.format(
        "species cap %s pct=%s Hmax=%s Fmax=%s src=%s",
        species, tostring(pct), tostring(maxHunger), tostring(maxFood), row.source
    ))
    return row, nil
end

function queueSpeciesCapSample(steam, delay)
    steam = tostring(steam or "")
    if steam == "" then return end
    pendingSpeciesCaps = pendingSpeciesCaps or {}
    pendingSpeciesCaps[#pendingSpeciesCaps + 1] = {
        steam = steam,
        at = os.time() + (tonumber(delay) or 2),
        tries = 0,
    }
end

function pollSpeciesCapSamples()
    if pendingSpeciesCaps == nil or #pendingSpeciesCaps == 0 then return end
    local now = os.time()
    local keep = {}
    for _, job in ipairs(pendingSpeciesCaps) do
        if now < (job.at or 0) then
            keep[#keep + 1] = job
        else
            local pawn = livePawnFromCtrl(controllerForSteam(job.steam))
            local row, err = recordSpeciesCap(pawn, "grow-sample")
            if row == nil then
                job.tries = (job.tries or 0) + 1
                if job.tries < 8 then
                    job.at = now + 1
                    keep[#keep + 1] = job
                else
                    log("species cap sample failed " .. tostring(job.steam) .. " " .. tostring(err))
                end
            end
        end
    end
    pendingSpeciesCaps = keep
end

function missingSpeciesCaps(pct)
    pct = math.floor(tonumber(pct) or 70)
    local missing = {}
    for _, name in ipairs(PRIMEVAL_PLAYABLE or {}) do
        if lookupSpeciesCap(name, pct) == nil then
            missing[#missing + 1] = name
        end
    end
    return missing
end

function makeText(message)
    if FText == nil then return message end
    local ok, ft = pcall(function() return FText(message) end)
    if ok and ft ~= nil then return ft end
    return message
end

function queueNotify(steamId, message)
    if steamId == nil or steamId == "" or message == nil or message == "" then return end
    pendingNotifies[#pendingNotifies + 1] = { steam = steamId, msg = message }
end

function quietPrimeNotify(steam, secs)
    if steam == nil or steam == "" then return end
    primeQuietUntil[steam] = os.time() + (secs or 20)
    lastPrimeState[steam] = nil
end

function drainNotifies()
    if #pendingNotifies == 0 then return end
    local drain = pendingNotifies
    pendingNotifies = {}
    for _, n in ipairs(drain) do
        local ctrl = controllerForSteam(n.steam)
        if ctrl ~= nil then
            pcall(function()
                ctrl:ClientShowNotification(makeText(n.msg))
            end)
        end
    end
end

function stripClassPrefix(s)
    if s == nil then return nil end
    s = tostring(s)
    return string.match(s, "^%S+%s+(.+)$") or s
end

function classPathOf(pawn)
    if pawn == nil then return nil end
    local full
    pcall(function()
        full = pawn:GetClass():GetFullName()
    end)
    if full == nil then return nil end
    return stripClassPrefix(tostring(full))
end


local HERB_KEYS = PRIMEVAL_HERB_KEYS or {
    hypsilophodon = true, dryosaurus = true, pachycephalosaurus = true,
    stegosaurus = true, triceratops = true, diabloceratops = true,
    tenontosaurus = true, maiasaura = true, kentrosaurus = true,
}
local OMNI_KEYS = PRIMEVAL_OMNI_KEYS or {
    omniraptor = true, gallimimus = true, galli = true,
    beipiaosaurus = true, pteranodon = true,
}

function prettySpecies(key)
    if key == nil or key == "" then return "unknown" end
    return (tostring(key):gsub("^%l", string.upper))
end

function dietOf(key)
    local k = string.lower(tostring(key or ""))
    if k == "" then return "carni" end
    if HERB_KEYS[k] then return "herb" end
    if OMNI_KEYS[k] then return "omni" end
    for name, _ in pairs(HERB_KEYS) do
        if k:find(name, 1, true) then return "herb" end
    end
    for name, _ in pairs(OMNI_KEYS) do
        if k:find(name, 1, true) then return "omni" end
    end
    return "carni"
end

function tpDietOk(fromKey, toKey)
    local fd = dietOf(fromKey)
    local td = dietOf(toKey)
    if fd == "carni" then
        if td ~= "carni" then
            return false, "Carni cannot teleport to Herb/Omni"
        end
        if not speciesMatch(fromKey, toKey) then
            return false, "Carni can only teleport to the same carnivore species"
        end
        return true, ""
    end
    if td == "carni" then
        return false, "Herb/Omni cannot teleport to carnivores"
    end
    return true, ""
end

function storedPath(steam)
    return STORED_DIR .. "/" .. tostring(steam) .. ".json"
end

function vaultPath(steam)
    return VAULT_DIR .. "/" .. tostring(steam) .. ".json"
end

function vecXYZ(vec)
    if vec == nil then return nil, nil, nil end
    local x, y, z
    pcall(function() x = tonumber(vec.X) or tonumber(vec.x) end)
    pcall(function() y = tonumber(vec.Y) or tonumber(vec.y) end)
    pcall(function() z = tonumber(vec.Z) or tonumber(vec.z) end)
    if x == nil and y == nil and z == nil then return nil, nil, nil end
    return x, y, z
end

function readLocation(pawn)
    if pawn == nil then return nil end
    local loc, rot
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if loc == nil then
        pcall(function()
            loc = pawn.RootComponent:K2_GetComponentLocation()
        end)
    end
    pcall(function() rot = pawn:K2_GetActorRotation() end)
    if rot == nil then
        pcall(function()
            rot = pawn.RootComponent:K2_GetComponentRotation()
        end)
    end
    local x, y, z = vecXYZ(loc)
    local pitch, yaw, roll = vecXYZ(rot)
    if pitch == nil then
        pcall(function() pitch = tonumber(rot.Pitch) end)
        pcall(function() yaw = tonumber(rot.Yaw) end)
        pcall(function() roll = tonumber(rot.Roll) end)
    end
    if x == nil then return nil end
    return { x = x, y = y, z = z, pitch = pitch, yaw = yaw, roll = roll }
end

function distSq(a, b)
    if a == nil or b == nil or a.x == nil or b.x == nil then return 0 end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

function tryCall(obj, names)
    if obj == nil then return nil end
    for _, name in ipairs(names) do
        local v
        pcall(function() v = obj[name](obj) end)
        if v ~= nil then return v end
        pcall(function() v = obj[name] end)
        if v ~= nil and type(v) ~= "function" then return v end
    end
    return nil
end

function tryNumber(obj, names)
    return numericValue(tryCall(obj, names))
end

function tryBool(obj, names)
    local v = tryCall(obj, names)
    if v == true or v == false then return v end
    local n = numericValue(v)
    if n == 1 then return true end
    if n == 0 then return false end
    if v == "true" or v == "True" then return true end
    if v == "false" or v == "False" then return false end
    return nil
end

function tryText(obj, names)
    local v = tryCall(obj, names)
    local n = numericValue(v)
    local s = safeString(v)
    if s == "" then return nil, n end
    return s, n
end

function customizerOf(pawn)
    if pawn == nil then return nil end
    local cd
    pcall(function() cd = pawn.CustomizerData end)
    return cd
end

CUSTOMIZER_COLOR_FIELDS = {
    "BodyColor", "MarkingsColor", "FlankColor", "UnderbellyColor",
    "Detail1Color", "EyesColor", "MaleDisplayColor",
    "TeethColor", "MouthColor", "ClawsColor",
}

function packLinearColor(c)
    if c == nil then return nil end
    local r, g, b, a
    pcall(function()
        r = tonumber(c.R)
        g = tonumber(c.G)
        b = tonumber(c.B)
        a = tonumber(c.A)
    end)
    if r == nil or g == nil or b == nil then return nil end
    return string.format("%.5f,%.5f,%.5f,%.5f", r, g, b, a or 1)
end

function writeLinearColor(cd, field, packed)
    if cd == nil or field == nil or packed == nil then return false end
    local r, g, b, a = packed:match("([^,]+),([^,]+),([^,]+),([^,]*)")
    r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
    if r == nil or g == nil or b == nil then return false end
    local ok = pcall(function()
        cd[field].R = r
        cd[field].G = g
        cd[field].B = b
        cd[field].A = a or 1
    end)
    return ok == true
end

function collectCustomizer(pawn)
    local cd = customizerOf(pawn)
    if cd == nil then return "" end
    local parts = {}
    local sv = tryNumber(cd, { "SkinVariation" })
    local pi = tryNumber(cd, { "PatternIndex" })
    local ti = tryNumber(cd, { "ThemeIndex" })
    if sv ~= nil then parts[#parts + 1] = "sv=" .. tostring(sv) end
    if pi ~= nil then parts[#parts + 1] = "pi=" .. tostring(math.floor(pi)) end
    if ti ~= nil then parts[#parts + 1] = "ti=" .. tostring(math.floor(ti)) end
    for _, field in ipairs(CUSTOMIZER_COLOR_FIELDS) do
        local c
        pcall(function() c = cd[field] end)
        local packed = packLinearColor(c)
        if packed ~= nil then
            parts[#parts + 1] = field .. "=" .. packed
        end
    end
    return table.concat(parts, "|")
end

function applyCustomizer(pawn, packed)
    if pawn == nil or packed == nil or packed == "" then return false end
    if packed:find("=", 1, true) == nil then return false end
    local cd = customizerOf(pawn)
    if cd == nil then return false end
    local wrote = 0
    for key, val in packed:gmatch("([^|=]+)=([^|]+)") do
        if key == "sv" then
            local n = tonumber(val)
            if n ~= nil then
                pcall(function() cd.SkinVariation = math.floor(n) end)
                wrote = wrote + 1
            end
        elseif key == "pi" then
            local n = tonumber(val)
            if n ~= nil then
                n = math.floor(n)
                if n >= 0 and n <= 32 then
                    pcall(function() cd.PatternIndex = n end)
                    wrote = wrote + 1
                end
            end
        elseif key == "ti" then
            local n = tonumber(val)
            if n ~= nil then
                pcall(function() cd.ThemeIndex = math.floor(n) end)
                wrote = wrote + 1
            end
        elseif writeLinearColor(cd, key, val) then
            wrote = wrote + 1
        end
    end
    pcall(function() pawn:ForceNetUpdate() end)
    return wrote > 0
end

function kickReplication(pawn)
    if pawn == nil then return end
    pcall(function() pawn:ForceNetUpdate() end)
    pcall(function() pawn:FlushNetDormancy() end)
end

function genderFrom(pawn)
    local female = nil
    local cd = customizerOf(pawn)
    if cd ~= nil then
        female = tryBool(cd, { "bIsFemale" })
    end
    if female == nil then
        female = tryBool(pawn, { "IsFemale", "GetIsFemale", "bIsFemale", "GetbIsFemale", "GetbGender", "bGender", "bFemale" })
    end
    local text, num = tryText(pawn, { "GetGender", "Gender", "CharacterGender", "DinosaurGender" })
    if num == nil then
        num = tryNumber(pawn, { "GetGender", "Gender", "GenderIndex" })
    end
    if text ~= nil then
        local low = string.lower(text)
        if low:find("female") then female = true end
        if low:find("male") and not low:find("female") and female == nil then female = false end
    end
    if female == true then
        text = "Female"
        if num == nil then num = 1 end
    elseif female == false then
        text = "Male"
        if num == nil then num = 0 end
    elseif num == 1 then
        text = "Female"
        female = true
    elseif num == 0 then
        text = "Male"
        female = false
    else
        text = nil
    end
    return text, female, num
end

function packArray(val)
    if val == nil then return "" end
    local parts = {}
    local n
    pcall(function() n = val:GetArrayNum() end)
    if n == nil then pcall(function() n = val:Num() end) end
    if type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local elem
            pcall(function() elem = val:Get(i) end)
            if elem == nil then pcall(function() elem = val[i] end) end
            local s = safeString(elem)
            local num = numericValue(elem)
            local piece = s
            if piece == "" and num ~= nil then piece = tostring(num) end
            if piece ~= "" then
                parts[#parts + 1] = tostring(i) .. "=" .. piece:gsub("[|;=]", "")
            end
        end
        if #parts > 0 then return table.concat(parts, "|") end
    end
    pcall(function()
        val:ForEach(function(index, elem)
            local s = safeString(elem)
            local num = numericValue(elem)
            local piece = s
            if piece == "" and num ~= nil then piece = tostring(num) end
            if piece ~= "" then
                parts[#parts + 1] = tostring(index) .. "=" .. piece:gsub("[|;=]", "")
            end
        end)
    end)
    if #parts == 0 then return "" end
    return table.concat(parts, "|")
end

function fnameStr(v)
    if v == nil then return "" end
    local s
    pcall(function() s = v:ToString() end)
    if type(s) == "string" and s ~= "" and s ~= "None" and not looksLikeDump(s) then
        return s
    end
    return ""
end

function collectFNameArray(arr)
    local parts = {}
    if arr == nil then return "" end
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    if n == 0 then pcall(function() n = arr:Num() end) end
    if n == 0 then pcall(function() n = #arr end) end
    for i = 1, math.min(tonumber(n) or 0, 32) do
        local v
        pcall(function() v = arr[i] end)
        if v == nil then pcall(function() v = arr:Get(i) end) end
        local s = fnameStr(v)
        if s == "" then s = safeString(v) end
        if s ~= "" and s ~= "None" and not looksLikeDump(s) then
            parts[#parts + 1] = s:gsub("[|;=]", "")
        end
    end
    return table.concat(parts, "|")
end

function collectUnlocks(pawn)
    local mr
    pcall(function() mr = pawn.MutationsRequirementsData end)
    if mr == nil then return "" end
    local names = {
        "UnlockRequiredMutations", "RequiredMutations", "UnlockedMutations",
        "QuestMutations", "EligibleMutations",
    }
    for _, field in ipairs(names) do
        local arr
        pcall(function() arr = mr[field] end)
        local packed = collectFNameArray(arr)
        if packed ~= "" then return packed end
    end
    return ""
end

function collectElderStacks(pawn)
    local n
    pcall(function() n = pawn:GetElderReplicationStacks() end)
    if n == nil then pcall(function() n = pawn.ElderReplicationStacks end) end
    return tonumber(n) or 0
end

function collectMutations(pawn)
    local parts = {}
    local data
    pcall(function() data = pawn.ReplicatedMutationsData end)
    if data ~= nil then
        for _, field in ipairs(MUTATION_FIELDS) do
            local v
            pcall(function() v = data[field] end)
            local s = fnameStr(v)
            if s ~= "" then
                parts[#parts + 1] = field .. "=" .. s:gsub("[|;=]", "")
            end
        end
        if #parts > 0 then return table.concat(parts, "|") end
    end
    local getters = {
        "GetMutationSlot", "GetMutation", "GetEquippedMutation",
        "GetMutationId", "GetActiveMutation",
    }
    for i = 0, 8 do
        local val
        for _, name in ipairs(getters) do
            pcall(function() val = pawn[name](pawn, i) end)
            if val ~= nil then break end
        end
        local s = safeString(val)
        local num = numericValue(val)
        local piece = s
        if piece == "" and num ~= nil then piece = tostring(math.floor(num)) end
        if piece ~= "" and not piece:find("^[Nn]one$") then
            parts[#parts + 1] = tostring(i) .. "=" .. piece:gsub("[|;=]", "")
        end
    end
    if #parts > 0 then return table.concat(parts, "|") end
    local arrays = {
        "Mutations", "MutationSlots", "EquippedMutations", "ActiveMutations",
        "MutationIds", "CharacterMutations",
    }
    for _, name in ipairs(arrays) do
        local packed = packArray(tryCall(pawn, { name }))
        if packed ~= "" then return packed end
    end
    return ""
end

function snapshotPawn(pawn)
    local classPath = classPathOf(pawn)
    local loc = readLocation(pawn)
    local gender, female, genderNum = genderFrom(pawn)
    local skinText, skinNum = tryText(pawn, {
        "GetSkinName", "GetActiveSkin", "GetSkin", "SkinName", "Skin",
        "GetSkinId", "SkinId", "SkinIndex", "CurrentSkin",
    })
    local snap = {
        classPath = classPath,
        species = speciesKey(classPath),
        growth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 0,
        health = tryNumber(pawn, { "GetHealth", "Health" }),
        maxHealth = tryNumber(pawn, { "GetMaxHealth", "MaxHealth" }),
        hunger = tryNumber(pawn, { "GetHunger", "Hunger" }),
        maxHunger = tryNumber(pawn, { "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax" }),
        maxFood = tryNumber(pawn, { "GetMaxFoodValue", "MaxFoodValue", "GetMaxFood", "MaxFood" }),
        thirst = tryNumber(pawn, { "GetThirst", "Thirst" }),
        stamina = tryNumber(pawn, { "GetStamina", "Stamina" }),
        oxygen = tryNumber(pawn, { "GetOxygen", "Oxygen" }),
        gender = gender,
        female = female,
        genderNum = genderNum,
        skin = skinText,
        skinId = skinNum or tryNumber(pawn, { "GetSkinId", "SkinId", "SkinIndex" }),
        skinData = collectCustomizer(pawn),
        primeElder = false,
        primeFlags = "",
        primeHave = 0,
        mutations = collectMutations(pawn),
        unlocks = collectUnlocks(pawn),
        elderStacks = collectElderStacks(pawn),
        x = loc and loc.x or nil,
        y = loc and loc.y or nil,
        z = loc and loc.z or nil,
        pitch = loc and loc.pitch or nil,
        yaw = loc and loc.yaw or nil,
        roll = loc and loc.roll or nil,
    }
    local nutrients = readNutrients(pawn)
    if nutrients ~= nil then
        snap.carbValue = nutrients.carb
        snap.proteinValue = nutrients.protein
        snap.lipidValue = nutrients.lipid
    end
    local pe
    pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if pe == nil then
        pcall(function() pe = pawn.EligiblePrimeElderData end)
    end
    local flags = {}
    local have = 0
    for i = 1, 10 do
        local ok = pe ~= nil and tryBool(pe, { "bPrimeCondition" .. tostring(i) }) == true
        flags[i] = ok and "1" or "0"
        if ok then have = have + 1 end
    end
    local eligible = pe ~= nil and tryBool(pe, { "bIsEligiblePrime", "GetbIsEligiblePrime" }) == true
    if not eligible then
        eligible = tryBool(pawn, { "GetIsEligiblePrimeElder", "IsPrimeElder", "GetPrimeElder", "bPrimeElder", "PrimeElder" }) == true
    end
    snap.primeFlags = table.concat(flags, "")
    snap.primeHave = have
    snap.primeElder = eligible
    return snap
end

function applyNumber(pawn, value, setters)
    if value == nil or pawn == nil then return false end
    local n = tonumber(value)
    if n == nil then return false end
    for _, name in ipairs(setters) do
        local ok = pcall(function() pawn[name](pawn, n) end)
        if ok then return true end
    end
    return false
end

function pawnAddr(pawn)
    local addr
    pcall(function() addr = pawn:GetAddress() end)
    return tostring(addr or "")
end

function setPawnCollision(pawn, enabled)
    if pawn == nil then return end
    local on = enabled == true
    pcall(function() pawn:SetActorEnableCollision(on) end)
    pcall(function() pawn.bActorEnableCollision = on end)
end

-- Vault snapshots store absolute GetHunger; shop contracts use 0–1 fractions.
-- Never clamp absolute values with `if h > 1 then h = 1` — that fills the bar.
function hungerFracFromSnap(snap, pawn)
    local h = snap ~= nil and tonumber(snap.hunger) or nil
    if h == nil then return nil end
    if h < 0 then return 0 end
    if h <= 1.0 then return h end
    local maxH = snap ~= nil and tonumber(snap.maxHunger) or nil
    if maxH == nil or maxH <= 1.5 then
        maxH = pawn ~= nil and pawnMaxHunger(pawn) or nil
    end
    if maxH ~= nil and maxH > 1.5 then
        local frac = h / maxH
        if frac < 0 then frac = 0 end
        if frac > 1 then frac = 1 end
        return frac
    end
    return nil
end

function restoreVaultHunger(pawn, snap)
    if pawn == nil then return false end
    local frac = hungerFracFromSnap(snap, pawn)
    if frac == nil then return false end
    -- Hunger only — SetFood/SetFoodValue recalculates ABY and stomps diet.
    local ok = quietSetHunger(pawn, frac, { skipFood = true })
    restoreVaultDiet(pawn, snap)
    return ok
end

function readNutrients(pawn)
    if pawn == nil then return nil end
    local live
    pcall(function() live = pawn.NutrientsStruct end)
    if live == nil then
        pcall(function() live = pawn:GetNutrientsStruct() end)
    end
    if live == nil then return nil end
    return {
        carb = tryNumber(live, { "CarbValue", "carbValue", "AlphaValue" }),
        protein = tryNumber(live, { "ProteinValue", "proteinValue", "BetaValue" }),
        lipid = tryNumber(live, { "LipidValue", "lipidValue", "GammaValue" }),
    }
end

function writeNutrients(pawn, carb, protein, lipid)
    if pawn == nil then return false end
    carb = tonumber(carb)
    protein = tonumber(protein)
    lipid = tonumber(lipid)
    if carb == nil and protein == nil and lipid == nil then
        return false
    end
    local live
    pcall(function() live = pawn.NutrientsStruct end)
    if live == nil then
        pcall(function() live = pawn:GetNutrientsStruct() end)
    end
    if live == nil then
        log("diet restore skip, no NutrientsStruct")
        return false
    end
    if carb ~= nil then live.CarbValue = carb end
    if protein ~= nil then live.ProteinValue = protein end
    if lipid ~= nil then live.LipidValue = lipid end
    pcall(function() live.bMalnutrition = false end)
    local ok = pcall(function() pawn:SetNutrientsStruct(live, true) end)
    if not ok then
        ok = pcall(function() pawn:SetNutrientsStruct(live) end)
    end
    log(string.format(
        "diet restore A=%s B=%s Y=%s ok=%s",
        tostring(carb), tostring(protein), tostring(lipid), tostring(ok)
    ))
    return ok == true
end

function restoreVaultDiet(pawn, snap)
    if pawn == nil or snap == nil then return false end
    local carb = tonumber(snap.carbValue)
    local protein = tonumber(snap.proteinValue)
    local lipid = tonumber(snap.lipidValue)
    if carb == nil and protein == nil and lipid == nil then
        return false
    end
    return writeNutrients(pawn, carb, protein, lipid)
end

function quietSetHunger(pawn, frac, opts)
    frac = tonumber(frac) or 0.75
    opts = opts or {}
    if pawn == nil then return false end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    local function scaled(getters)
        local maxV = tryNumber(pawn, getters)
        if maxV ~= nil and maxV > 1.5 then
            return maxV * frac
        end
        return frac
    end
    local hungerVal = scaled({
        "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
        "GetMaximumHunger", "MaximumHunger",
    })
    local ok = pcall(function() pawn:SetHunger(hungerVal) end)
    pcall(function() pawn.Hunger = hungerVal end)
    pcall(function() pawn:SetCurrentHunger(hungerVal) end)
    pcall(function() pawn.CurrentHunger = hungerVal end)
    -- SetFood recalculates NutrientsStruct (ABY). Shop vitals still need it;
    -- vault restore must skip and re-apply snap diet afterward.
    if opts.skipFood ~= true then
        local foodVal = scaled({
            "GetMaxFood", "MaxFood", "GetMaxFoodValue", "MaxFoodValue",
            "GetMaximumFood", "MaximumFood", "GetFoodMax", "FoodMax",
        })
        pcall(function() pawn:SetFood(foodVal) end)
        pcall(function() pawn.Food = foodVal end)
        pcall(function() pawn:SetFoodValue(foodVal) end)
        pcall(function() pawn.FoodValue = foodVal end)
        pcall(function() pawn:SetCurrentFood(foodVal) end)
    end
    return ok
end

function fillHunger(pawn, frac)
    return quietSetHunger(pawn, frac)
end

-- Alpha=carbs, Beta=protein, Gamma=lipids. GetMaxFoodValue is the
-- per-pawn capacity that scales with species and growth.
function applyPerfectDiet(pawn, frac, nutrientMax)
    frac = tonumber(frac) or 0.5
    if pawn == nil then return false end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    local maxV = tonumber(nutrientMax)
    if maxV == nil or maxV <= 1.5 then
        maxV = tryNumber(pawn, {
            "GetMaxFoodValue", "MaxFoodValue",
            "GetMaxFood", "MaxFood", "GetFoodMax", "FoodMax",
        })
    end
    if maxV == nil or maxV <= 1.5 then
        log("diet skip, max food unavailable after growth")
        return false
    end
    local amount = maxV * frac
    local live
    pcall(function() live = pawn.NutrientsStruct end)
    if live == nil then
        pcall(function() live = pawn:GetNutrientsStruct() end)
    end
    if live == nil then
        log("diet skip, no NutrientsStruct")
        return false
    end
    live.CarbValue = amount
    live.ProteinValue = amount
    live.LipidValue = amount
    pcall(function() live.bMalnutrition = false end)
    local ok = pcall(function() pawn:SetNutrientsStruct(live, true) end)
    if not ok then
        ok = pcall(function() pawn:SetNutrientsStruct(live) end)
    end
    log(string.format(
        "diet write max=%s amount=%s ok=%s",
        tostring(maxV), tostring(amount), tostring(ok)
    ))
    return ok
end

function refillBuyVitals(pawn, snap)
    if pawn == nil then return false end
    local hunger = 0.75
    local fromSnap = hungerFracFromSnap(snap, pawn)
    if fromSnap ~= nil then
        hunger = fromSnap
    end

    -- Cache maxima before SetNutrientsStruct. ABY is written first and only
    -- hunger is written afterward. SetFood/SetFoodValue recalculates diet and
    -- was clearing the ABY values immediately after they appeared.
    -- Prefer measured 70% caps when the live pawn still has juvenile MaxHunger.
    local capHunger = snap and tonumber(snap.maxHunger)
    local capFood = snap and tonumber(snap.maxFood)
    if capHunger == nil or capHunger <= 1.5 then
        local species = speciesKey(classPathOf(pawn))
        if snap ~= nil then
            local fromSnap = snap.classPath ~= nil and snap.classPath ~= "" and snap.classPath or snap.species
            if fromSnap ~= nil and fromSnap ~= "" then
                species = speciesKey(fromSnap)
            end
        end
        local cap = capForSpecies(species, (snap and snap.growth) or 0.70)
        if cap ~= nil then
            capHunger = tonumber(cap.maxHunger)
            capFood = tonumber(cap.maxFood)
        end
    end
    if capHunger ~= nil and capHunger > 1.5 then
        pcall(function() pawn:SetMaxHunger(capHunger) end)
        pcall(function() pawn.MaxHunger = capHunger end)
    end
    local maxHunger = pawnMaxHunger(pawn)
    if maxHunger == nil or (capHunger ~= nil and maxHunger < (capHunger * 0.85)) then
        maxHunger = capHunger
    end
    local maxFood = tryNumber(pawn, {
        "GetMaxFoodValue", "MaxFoodValue",
        "GetMaxFood", "MaxFood", "GetFoodMax", "FoodMax",
    })
    if maxFood == nil or (capFood ~= nil and maxFood < (capFood * 0.85)) then
        maxFood = capFood
    end
    local dietOk = applyPerfectDiet(pawn, 0.5, maxFood)
    local hungerOk = false
    local hungerValue = nil
    if maxHunger ~= nil and maxHunger > 1.5 then
        hungerValue = maxHunger * hunger
        hungerOk = pcall(function() pawn:SetHunger(hungerValue) end)
    end
    local primeN = 0
    if snap ~= nil then
        primeN = applyPrime(pawn, snap)
        if primeN == 0 and (snap.primeElder == true or snap.source == "buy") then
            primeN = forceAllPrime(pawn)
        end
    else
        primeN = forceAllPrime(pawn)
    end
    log(string.format(
        "buy vitals ABY-then-hunger Hmax=%s Fmax=%s H=%s diet=%s hunger=%s",
        tostring(maxHunger), tostring(maxFood), tostring(hungerValue),
        tostring(dietOk), tostring(hungerOk)
    ))
    local ready = dietOk == true
        and hungerOk == true
        and maxHunger ~= nil and maxHunger > 1.5
        and maxFood ~= nil and maxFood > 1.5
    return ready, primeN
end

function applyStoredRestore(pawn, snap)
    local applied = {}
    if pawn == nil or snap == nil then return applied end
    if applyGender(pawn, snap) then applied[#applied + 1] = "gender" end
    if applyCustomizer(pawn, snap.skinData) then applied[#applied + 1] = "skin" end
    local unlockN = applyUnlocks(pawn, snap.unlocks)
    if unlockN > 0 then applied[#applied + 1] = "unlocks:" .. tostring(unlockN) end
    local mutN = applyMutations(pawn, snap.mutations)
    if mutN > 0 then applied[#applied + 1] = "mutations:" .. tostring(mutN) end
    if applyElderStacks(pawn, snap.elderStacks) then applied[#applied + 1] = "elderStacks" end
    local primeN = applyPrime(pawn, snap)
    if primeN > 0 then applied[#applied + 1] = "prime:" .. tostring(primeN) end
    kickReplication(pawn)
    return applied
end

function applyBuyInject(pawn, snap)
    local applied = {}
    if applyGender(pawn, snap) then applied[#applied + 1] = "gender" end
    local mutN = applyMutations(pawn, snap.mutations)
    if mutN > 0 then applied[#applied + 1] = "mutations:" .. tostring(mutN) end
    local primeN = applyPrime(pawn, snap)
    if primeN == 0 then
        primeN = forceAllPrime(pawn)
    end
    if primeN > 0 then applied[#applied + 1] = "prime:" .. tostring(primeN) end
    log("buy inject tick0 gender+mut+prime n=" .. tostring(mutN) .. " prime=" .. tostring(primeN))
    return applied
end

function applyText(pawn, value, setters)
    if value == nil or value == "" or pawn == nil then return false end
    for _, name in ipairs(setters) do
        local ok = pcall(function() pawn[name](pawn, value) end)
        if ok then return true end
        if FText ~= nil then
            local ft
            pcall(function() ft = FText(value) end)
            ok = pcall(function() pawn[name](pawn, ft or value) end)
            if ok then return true end
        end
        local asNum = tonumber(value)
        if asNum ~= nil then
            ok = pcall(function() pawn[name](pawn, asNum) end)
            if ok then return true end
        end
    end
    return false
end

function makeFName(name)
    if name == nil or name == "" or FName == nil then return nil end
    local fn
    pcall(function() fn = FName(name) end)
    if fn == nil then
        pcall(function() fn = FName(tostring(name), 1) end)
    end
    return fn
end

function parseMutationMap(packed)
    local map = {}
    if packed == nil or packed == "" then return map end
    for key, val in packed:gmatch("([^|=]+)=([^|]+)") do
        if val ~= nil and val ~= "" and val ~= "None" then
            if key:match("^%d+$") then
                local i = tonumber(key)
                if i ~= nil and i >= 1 and i <= 4 then
                    map["MutationSlot" .. i] = val
                elseif i ~= nil and i >= 0 and i <= 3 then
                    map["MutationSlot" .. (i + 1)] = val
                end
            else
                map[key] = val
            end
        end
    end
    return map
end

function applyUnlocks(pawn, packed)
    if packed == nil or packed == "" or pawn == nil then return 0 end
    local n = 0
    local mr
    pcall(function() mr = pawn.MutationsRequirementsData end)
    for name in packed:gmatch("([^|]+)") do
        local fn = makeFName(name)
        local arg = fn or name
        pcall(function() pawn:UnlockRequiredMutations(arg) end)
        pcall(function() pawn:UnlockMutation(arg) end)
        if mr ~= nil then
            pcall(function() mr:UnlockRequiredMutations(arg) end)
            pcall(function() mr.UnlockRequiredMutations:Add(arg) end)
        end
        n = n + 1
    end
    if mr ~= nil then
        pcall(function() pawn:SetMutationRequirementsData(mr) end)
        pcall(function() pawn:SetMutationsRequirementsData(mr, true) end)
        pcall(function() pawn:SetMutationsRequirementsData(mr) end)
    end
    return n
end

function applyElderStacks(pawn, stacks)
    local n = tonumber(stacks)
    if n == nil or n <= 0 or pawn == nil then return false end
    local ok = pcall(function() pawn:SetElderReplicationStacks(n) end)
    if not ok then
        ok = pcall(function() pawn.ElderReplicationStacks = n end)
    end
    return ok
end

function wantedFemale(snap)
    if snap == nil then return nil end
    if snap.female == true then return true end
    if snap.female == false then return false end
    if snap.gender ~= nil then
        local low = string.lower(tostring(snap.gender))
        if low:find("female") then return true end
        if low:find("male") then return false end
    end
    if snap.genderNum ~= nil then
        if tonumber(snap.genderNum) == 1 then return true end
        if tonumber(snap.genderNum) == 0 then return false end
    end
    return nil
end

function applyGender(pawn, snap)
    local female = wantedFemale(snap)
    if pawn == nil or female == nil then return false end
    local _, liveFemale = genderFrom(pawn)
    if liveFemale == female then return true end
    local ok = false
    local cd = customizerOf(pawn)
    if cd ~= nil then
        local wrote = pcall(function() cd.bIsFemale = female end)
        if wrote then ok = true end
    end
    pcall(function() pawn.bIsFemale = female end)
    pcall(function() pawn.bFemale = female end)
    pcall(function() pawn.bGender = female end)
    local _, liveFemale = genderFrom(pawn)
    return ok or liveFemale == female
end

function parsePrimeFlags(packed)
    local conds = {}
    if packed == nil then return conds end
    local bits = tostring(packed):gsub("[^01]", "")
    for i = 1, 10 do
        conds[i] = bits:sub(i, i) == "1"
    end
    return conds
end

function applyPrime(pawn, snap)
    if pawn == nil or snap == nil then return 0 end
    local pe
    pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    if pe == nil then
        pcall(function() pe = pawn.EligiblePrimeElderData end)
    end
    if pe == nil then return 0 end
    local flags = tostring(snap.primeFlags or "")
    local conds = parsePrimeFlags(flags)
    local wrote = 0
    local have = 0
    if flags ~= "" and flags:find("[01]") then
        for i = 1, 10 do
            local v = conds[i] == true
            local ok = pcall(function() pe["bPrimeCondition" .. tostring(i)] = v end)
            if ok then wrote = wrote + 1 end
            if v then have = have + 1 end
        end
    elseif snap.primeElder == true then
        for i = 1, 10 do
            pcall(function() pe["bPrimeCondition" .. tostring(i)] = true end)
            wrote = wrote + 1
            have = have + 1
        end
    else
        return 0
    end
    local eligible = snap.primeElder == true or have >= 5
    pcall(function() pe.bIsEligiblePrime = eligible end)
    pcall(function() pawn:SetEligiblePrimeElderData(pe) end)
    pcall(function() pawn:ServerSetPrimeEligible(eligible) end)
    return wrote
end

function applyMutations(pawn, packed)
    if packed == nil or packed == "" or pawn == nil then return 0 end
    local map = parseMutationMap(packed)
    local written = 0
    local liveMut
    pcall(function() liveMut = pawn.ReplicatedMutationsData end)
    if liveMut ~= nil then
        for field, name in pairs(map) do
            local fn = makeFName(name)
            if fn ~= nil then
                local ok = pcall(function() liveMut[field] = fn end)
                if ok then written = written + 1 end
            end
        end
        if written > 0 then
            local okPush = pcall(function() pawn:SetReplicatedMutationsData(liveMut, true) end)
            if not okPush then
                pcall(function() pawn:SetReplicatedMutationsData(liveMut) end)
            end
        end
    end
    if written == 0 then
        for slot, name in packed:gmatch("(%d+)=([^|]+)") do
            local i = tonumber(slot)
            local asNum = tonumber(name)
            local ok = pcall(function() pawn:SetMutationSlot(i, name) end)
                or pcall(function() pawn:SetMutation(i, name) end)
                or pcall(function() pawn:ApplyMutation(name) end)
            if not ok and asNum ~= nil then
                ok = pcall(function() pawn:SetMutationSlot(i, asNum) end)
                    or pcall(function() pawn:SetMutation(i, asNum) end)
            end
            if ok then written = written + 1 end
        end
    end
    return written
end

function makeVec(x, y, z, pawn)
    local v
    if FVector ~= nil then
        pcall(function() v = FVector(x, y, z) end)
    end
    if v == nil and pawn ~= nil then
        pcall(function() v = pawn:K2_GetActorLocation() end)
        if v ~= nil then
            pcall(function()
                v.X = x
                v.Y = y
                v.Z = z
            end)
        end
    end
    return v
end

function makeRot(snap, pawn)
    local r
    if FRotator ~= nil then
        pcall(function() r = FRotator(snap.pitch or 0, snap.yaw or 0, snap.roll or 0) end)
    end
    if r == nil and pawn ~= nil then
        pcall(function() r = pawn:K2_GetActorRotation() end)
        if r ~= nil then
            pcall(function()
                r.Pitch = snap.pitch or 0
                r.Yaw = snap.yaw or 0
                r.Roll = snap.roll or 0
            end)
        end
    end
    return r
end

function locClose(nowLoc, x, y, z)
    if nowLoc == nil or nowLoc.x == nil then return false end
    return distSq(nowLoc, { x = x, y = y, z = z }) < (4000 * 4000)
end

function teleportPawn(pawn, snap, ctrl)
    if pawn == nil or snap == nil or snap.x == nil then return false end
    local x = tonumber(snap.x)
    local y = tonumber(snap.y) or 0
    local z = (tonumber(snap.z) or 0) + 80
    if x == nil then return false end
    pcall(function() pawn.CharacterMovement:StopMovementImmediately() end)
    pcall(function() pawn:StopMovementImmediately() end)
    local dest = makeVec(x, y, z, pawn)
    local rot = makeRot(snap, pawn)
    local hit = {}
    if dest ~= nil then
        pcall(function() pawn.RootComponent:K2_SetWorldLocation(dest, false, hit, true) end)
        pcall(function() pawn.RootComponent:K2_SetWorldLocationAndRotation(dest, rot, false, hit, true) end)
        pcall(function() pawn:K2_SetActorLocationAndRotation(dest, rot, false, hit, true) end)
        pcall(function() pawn:K2_SetActorLocation(dest, false, hit, true) end)
        pcall(function() pawn:K2_TeleportTo(dest, rot) end)
        pcall(function() pawn:SetActorLocation(dest, false) end)
        pcall(function() pawn:TeleportTo(dest, rot, false, true) end)
    end
    if rot ~= nil then
        pcall(function() pawn:K2_SetActorRotation(rot, false) end)
    end
    if ctrl ~= nil then
        if dest ~= nil then
            pcall(function() ctrl:ClientSetLocation(dest, rot) end)
            pcall(function() ctrl:ClientSetLocation(dest) end)
        end
        if rot ~= nil then
            pcall(function() ctrl:SetControlRotation(rot) end)
            pcall(function() ctrl:ClientSetRotation(rot) end)
        end
    end
    local nowLoc = readLocation(pawn)
    local ok = locClose(nowLoc, x, y, z)
    log(string.format(
        "tp dest=%.0f,%.0f,%.0f now=%.0f,%.0f,%.0f ok=%s",
        x, y, z,
        nowLoc and nowLoc.x or 0,
        nowLoc and nowLoc.y or 0,
        nowLoc and nowLoc.z or 0,
        tostring(ok)
    ))
    return ok
end

function queueTeleport(steam, snap)
    if snap == nil or snap.x == nil then return end
    pendingTeleports[#pendingTeleports + 1] = {
        steam = steam,
        snap = snap,
        at = os.time(),
        tries = 0,
        hits = 0,
    }
end

function queueMutationRestore(steam, snap)
    if snap == nil then return end
    quietPrimeNotify(steam, 20)
    pendingMutationRestores[#pendingMutationRestores + 1] = {
        steam = steam,
        snap = snap,
        at = os.time() + 1,
        tries = 0,
    }
end

function mutationSlotFilled(pawn, field)
    if pawn == nil or field == nil or field == "" then return false end
    local packed = collectMutations(pawn)
    if packed == nil or packed == "" then return false end
    local val = packed:match(field .. "=([^|]+)")
    if val == nil then
        local idx = tostring(field):match("MutationSlot(%d+)")
        if idx ~= nil then
            val = packed:match("[^%d]" .. idx .. "=([^|]+)") or packed:match("^" .. idx .. "=([^|]+)")
        end
    end
    if val == nil then return false end
    val = tostring(val)
    return val ~= "" and val ~= "None" and val ~= "none"
end

function mutationFilledCount(pawn)
    local packed = collectMutations(pawn) or ""
    local n = 0
    for key, val in packed:gmatch("([^|=]+)=([^|]+)") do
        val = tostring(val)
        if val ~= "" and val ~= "None" and val ~= "none" then
            if key:match("^MutationSlot%d+$") or key:match("^%d+$") then
                n = n + 1
            end
        end
    end
    return n
end

function applySnapshot(pawn, snap, opts)
    opts = opts or {}
    local applied = {}
    if applyNumber(pawn, snap.thirst, { "SetThirst" }) then applied[#applied + 1] = "thirst" end
    if applyNumber(pawn, snap.stamina, { "SetStamina" }) then applied[#applied + 1] = "stamina" end
    if applyNumber(pawn, snap.oxygen, { "SetOxygen" }) then applied[#applied + 1] = "oxygen" end
    if applyNumber(pawn, snap.health, { "SetHealth" }) then applied[#applied + 1] = "health" end
    if applyGender(pawn, snap) then applied[#applied + 1] = "gender" end
    if applyCustomizer(pawn, snap.skinData) then
        applied[#applied + 1] = "skin"
    elseif applyText(pawn, snap.skin, { "SetSkinName", "SetActiveSkin", "SetSkin", "ApplySkin" }) then
        applied[#applied + 1] = "skin"
    end
    if applyNumber(pawn, snap.skinId, { "SetSkinId", "SetSkin", "SetSkinIndex" }) then
        applied[#applied + 1] = "skinId"
    end
    if snap.primeElder == true then
        pcall(function() pawn:SetPrimeElder(true) end)
        pcall(function() pawn.bPrimeElder = true end)
    end
    local primeN = applyPrime(pawn, snap)
    if primeN > 0 then applied[#applied + 1] = "prime:" .. tostring(primeN) end
    if opts.skipGrowth ~= true then
        if applyNumber(pawn, snap.growth, { "SetGrowth" }) then applied[#applied + 1] = "growth" end
    end
    if applyNumber(pawn, snap.maxHunger, { "SetMaxHunger" }) then applied[#applied + 1] = "maxHunger" end
    local unlockN = applyUnlocks(pawn, snap.unlocks)
    if unlockN > 0 then applied[#applied + 1] = "unlocks:" .. tostring(unlockN) end
    local mutN = applyMutations(pawn, snap.mutations)
    if mutN > 0 then applied[#applied + 1] = "mutations:" .. tostring(mutN) end
    if applyElderStacks(pawn, snap.elderStacks) then applied[#applied + 1] = "elderStacks" end
    if snap.stayPut ~= true and teleportPawn(pawn, snap) then applied[#applied + 1] = "location" end
    if opts.skipHunger ~= true then
        local hunger = hungerFracFromSnap(snap, pawn)
        if hunger == nil then hunger = 0.75 end
        if opts.vaultVitals == true then
            if quietSetHunger(pawn, hunger, { skipFood = true }) then
                applied[#applied + 1] = "hunger"
            end
            if restoreVaultDiet(pawn, snap) then
                applied[#applied + 1] = "diet"
            end
        else
            if fillHunger(pawn, hunger) then applied[#applied + 1] = "hunger" end
        end
    end
    return applied
end
