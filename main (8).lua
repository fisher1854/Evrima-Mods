--[[
  PrimevalRedeem — UE4SS Lua mod for The Isle Evrima.

  Store uses the GAME's safelog as the trigger, then kills the dino
  so native persistence cannot keep that character:
    !store              arm a vault. Then start a safelog. The mod
                        snapshots the live pawn, writes the vault, and
                        slays you just before the safelog finishes.
                        Cancel the safelog before the kill to abort.
                        Then spawn that species as a juvenile and !redeem.
    !cancelstore        un-arm if you have not finished safelog yet
    !redeem             restore a vault onto a matching juvenile (once).
                        That slot is wiped. Die without storing again and
                        the dino is gone.
    !storeinfo          show what is vaulted
    !prime              read live Prime Elder flags from your spawned dino
                        (also pops up in-game when you meet a condition, ~15s)

  Discord / shop (bot appends one JSON line to Saved/inbox.ndjson):
    {"id":"...","verb":"store","steam":"7656..."}
    {"id":"...","verb":"redeem","steam":"7656...","slot":"..."}
    {"id":"...","verb":"tpinfo","steam":"7656..."}
    {"id":"...","verb":"tpstart","steam":"<from>","target":"<to>"}
    {"id":"...","verb":"tpcancel","steam":"<from>"}
]]

MOD_NAME = "PrimevalRedeem"
PRIMARY_SAVED = "ue4ss/Mods/PrimevalRedeem/Saved"
LEGACY_SAVED = "Mods/PrimevalRedeem/Saved"
SAVED_DIR = PRIMARY_SAVED
STORED_DIR = SAVED_DIR .. "/stored"
VAULT_DIR = SAVED_DIR .. "/vault"
PRIME_DIR = SAVED_DIR .. "/prime"
LEGACY_PRIME = LEGACY_SAVED .. "/prime"
LEGACY_STORED = LEGACY_SAVED .. "/stored"
LEGACY_VAULT = LEGACY_SAVED .. "/vault"
INBOX_PATH = SAVED_DIR .. "/inbox.ndjson"
INBOX_DIR = SAVED_DIR .. "/inbox"
RESULTS_PATH = SAVED_DIR .. "/results.ndjson"
PENDING_REDEEMS_PATH = SAVED_DIR .. "/pending_redeems.ndjson"
CONFIG_PATH = SAVED_DIR .. "/config.json"
CMD_FLAG = SAVED_DIR .. "/cmd.flag"
LEGACY_CMD_FLAG = LEGACY_SAVED .. "/cmd.flag"

pendingNotifies = {}
pendingRedeems = {}
armedStores = {}
pendingSnaps = {}
pendingSlays = {}
pendingTeleports = {}
pendingMutationRestores = {}
pendingBuyGrows = {}
pendingHungerFills = {}
pendingBuyInjects = {}
pendingNativeBuyRedeems = {}
pendingSpeciesCaps = {}
SPECIES_CAPS = {}
pendingFriendTps = {}
lastPrimeState = {}
primeQuietUntil = {}
knownSteams = {}
lastPrimePollLog = 0
lastPrimeWorkAt = 0
seenInboxIds = {}
LIVE_DIR = SAVED_DIR .. "/live"
TP_DIR = SAVED_DIR .. "/tp"
RECAP_DIR = SAVED_DIR .. "/recap"
RECAP_LOG = SAVED_DIR .. "/recap.ndjson"
ADMIN_AUDIT_LOG = SAVED_DIR .. "/admin_audit.ndjson"
SPECIES_CAPS_PATH = SAVED_DIR .. "/species_caps.ndjson"
REDEEM_AUDIT = nil
REDEEM_AUDIT_UNTIL = 0
TOKEN_EVENT_PATH = SAVED_DIR .. "/token_event.json"
TP_HOLD_SECONDS = 60
TP_MOVE_DIST = 450
SAFELOG_KILL_DELAY = 50
MUTATION_FIELDS = {
    "MutationSlot1", "MutationSlot2", "MutationSlot3", "MutationSlot4",
    "ParentMutationSlot1", "ParentMutationSlot2", "ParentMutationSlot3", "ParentMutationSlot4",
    "ElderMutationSlot1A", "ElderMutationSlot2A", "ElderMutationSlot3A", "ElderMutationSlot4A",
    "ElderMutationSlot1B", "ElderMutationSlot2B", "ElderMutationSlot3B", "ElderMutationSlot4B",
}


-- Minimal safe load without log() dependency
function loadFirstModScriptUnsafe(name)
    local primary = "ue4ss/Mods/PrimevalRedeem/Scripts/" .. name
    local legacy = "Mods/PrimevalRedeem/Scripts/" .. name

    local ok, err = pcall(dofile, primary)
    if ok then
        return true
    end

    local msg = tostring(err or "")
    if msg:find("cannot open", 1, true) or msg:find("No such file", 1, true) then
        -- Try legacy
        ok, err = pcall(dofile, legacy)
        return ok == true
    end

    return false
end

-- Load data and command infrastructure first (before log exists).
loadFirstModScriptUnsafe("species.lua")
loadFirstModScriptUnsafe("inbox.lua")

-- NOW log() exists, so we can use it in the safer wrapper.
function loadModScript(path)
    local ok, err = pcall(dofile, path)

    if ok then
        log("SCRIPT LOADED " .. path)
        return true
    end

    local msg = tostring(err or "")
    if msg:find("cannot open", 1, true) or msg:find("No such file", 1, true) then
        return false
    end

    log("SCRIPT ERROR " .. path .. " :: " .. msg)
    return false
end

function loadFirstModScript(name)
    local primary = "ue4ss/Mods/PrimevalRedeem/Scripts/" .. name
    local legacy = "Mods/PrimevalRedeem/Scripts/" .. name

    if loadModScript(primary) then
        return true
    end

    return loadModScript(legacy)
end

-- Load runtime modules once (now with safe logging).
loadFirstModScript("world.lua")
loadFirstModScript("prime.lua")
loadFirstModScript("tp.lua")
loadFirstModScript("ai.lua")
loadFirstModScript("overlay.lua")
loadFirstModScript("skin.lua")
-- ============================================================
-- Deduplication & abuse prevention
-- ============================================================

PLAYER_JOBS = PLAYER_JOBS or {}
PLAYER_COOLDOWNS = PLAYER_COOLDOWNS or {}

local JOB_LIMITS = {
    store = { max = 1, timeout = 600 },        -- One armed store per player, 10 min timeout
    redeem = { max = 2, timeout = 60 },        -- Two concurrent redeems max (multi-slot), 1 min retry
    teleport = { max = 1, timeout = 60 },      -- One active teleport per player, 1 min hold
    grow = { max = 1, timeout = 300 },         -- One grow per player, 5 min cooldown
    mutation = { max = 1, timeout = 120 },     -- One mutation restore per player, 2 min retry
}

 local COOLDOWN_TIMES = {
     store = 600,          -- 10 minutes between stores
     redeem = 30,          -- 30 seconds between redeem attempts
     teleport = 60,        -- 60 seconds between teleports
     selfkill = 300,       -- 5 minutes between self-kills
 }

function getPlayerJobs(steam, kind)
    steam = tostring(steam or "")
    if steam == "" then return {} end
    PLAYER_JOBS[steam] = PLAYER_JOBS[steam] or {}
    if kind == nil then
        return PLAYER_JOBS[steam]
    end
    return (PLAYER_JOBS[steam] or {})[kind] or {}
end

function countPlayerJobsByKind(steam, kind)
    local jobs = getPlayerJobs(steam, kind)
    return #jobs
end

function canQueueJob(steam, kind, slotId)
    steam = tostring(steam or "")
    if steam == "" then return false, "missing steam" end
    
    local limit = JOB_LIMITS[kind]
    if limit == nil then return true, "" end
    
    local jobs = getPlayerJobs(steam, kind)
    local count = countPlayerJobsByKind(steam, kind)
    
    if kind == "redeem" and slotId ~= nil and slotId ~= "" then
        -- Allow multiple redeems if they target different slots
        for _, job in pairs(jobs) do
            if job.slot == slotId and (os.time() - (job.at or 0)) < 30 then
                return false, "redeem already in progress for that slot"
            end
        end
    elseif count >= (limit.max or 1) then
        return false, string.format("already have %d active %s job(s)", count, kind)
    end
    
    local cooldown = COOLDOWN_TIMES[kind]
    if cooldown ~= nil then
        local lastCd = PLAYER_COOLDOWNS[steam .. "_" .. kind]
        if lastCd ~= nil and (os.time() - lastCd) < cooldown then
            return false, string.format("please wait %ds before %s again", cooldown - (os.time() - lastCd), kind)
        end
    end
    
    return true, ""
end

function recordJobCooldown(steam, kind)
    steam = tostring(steam or "")
    if steam ~= "" then
        PLAYER_COOLDOWNS[steam .. "_" .. kind] = os.time()
    end
end

function registerPlayerJob(steam, kind, job)
    steam = tostring(steam or "")
    if steam == "" then return end
    PLAYER_JOBS[steam] = PLAYER_JOBS[steam] or {}
    PLAYER_JOBS[steam][kind] = PLAYER_JOBS[steam][kind] or {}
    -- Array-like storage for queues; unregisterPlayerJob matches by job.steam/job.id.
    PLAYER_JOBS[steam][kind][#PLAYER_JOBS[steam][kind] + 1] = job
end

function unregisterPlayerJob(steam, kind, identifier)
    steam = tostring(steam or "")
    if steam == "" then return end
    local jobs = (PLAYER_JOBS[steam] or {})[kind]
    if jobs == nil then return end

    -- Array-like: delete by steam from job.steam, or by job.id
    local keep = {}
    for _, job in ipairs(jobs) do
        if job.steam ~= identifier and job.id ~= identifier then
            keep[#keep + 1] = job
        end
    end
    PLAYER_JOBS[steam][kind] = keep
end

function clearPlayerJobs(steam)
    steam = tostring(steam or "")
    if steam == "" then return end
    PLAYER_JOBS[steam] = {}
end
function sanitizeSlot(slot)
    local s = tostring(slot or ""):gsub("[^%w%-_]", "")
    if #s > 48 then s = s:sub(1, 48) end
    return s
end

function slotFile(steam, slotId)
    return VAULT_DIR .. "/" .. tostring(steam) .. "_" .. tostring(slotId) .. ".json"
end

function indexPath(steam)
    return VAULT_DIR .. "/" .. tostring(steam) .. ".index.ndjson"
end

function snapFromBody(body)
    if body == nil or body == "" then return nil end
    local female = jsonReadBool(body, "female")
    local stay = jsonReadBool(body, "stayPut")
    return {
        id = jsonReadString(body, "id") or "",
        source = jsonReadString(body, "source") or "",
        stayPut = stay == true,
        classPath = jsonReadString(body, "classPath"),
        species = jsonReadString(body, "species"),
        growth = jsonReadNumber(body, "growth") or 0,
        health = jsonReadNumber(body, "health"),
        maxHealth = jsonReadNumber(body, "maxHealth"),
        hunger = jsonReadNumber(body, "hunger"),
        maxHunger = jsonReadNumber(body, "maxHunger"),
        maxFood = jsonReadNumber(body, "maxFood"),
        carbValue = jsonReadNumber(body, "carbValue"),
        proteinValue = jsonReadNumber(body, "proteinValue"),
        lipidValue = jsonReadNumber(body, "lipidValue"),
        thirst = jsonReadNumber(body, "thirst"),
        stamina = jsonReadNumber(body, "stamina"),
        oxygen = jsonReadNumber(body, "oxygen"),
        gender = jsonReadString(body, "gender"),
        female = female,
        genderNum = jsonReadNumber(body, "genderNum"),
        skin = jsonReadString(body, "skin"),
        skinId = jsonReadNumber(body, "skinId"),
        skinData = jsonReadString(body, "skinData") or "",
        skinLocked = jsonReadBool(body, "skinLocked") == true,
        skinUnlocked = jsonReadBool(body, "skinUnlocked") == true,
        skinLockId = jsonReadString(body, "skinLockId") or "",
        skinLockGrowth = jsonReadNumber(body, "skinLockGrowth") or 0,
        primeElder = jsonReadBool(body, "primeElder") == true,
        primeFlags = jsonReadString(body, "primeFlags") or "",
        primeHave = jsonReadNumber(body, "primeHave") or 0,
        mutations = jsonReadString(body, "mutations") or "",
        unlocks = jsonReadString(body, "unlocks") or "",
        elderStacks = jsonReadNumber(body, "elderStacks") or 0,
        x = jsonReadNumber(body, "x"),
        y = jsonReadNumber(body, "y"),
        z = jsonReadNumber(body, "z"),
        pitch = jsonReadNumber(body, "pitch"),
        yaw = jsonReadNumber(body, "yaw"),
        roll = jsonReadNumber(body, "roll"),
        version = jsonReadNumber(body, "version") or 1,
    }
end

function loadStored(steam, slotId)
    slotId = sanitizeSlot(slotId)
    local body
    if slotId ~= "" then
        body = readAll(slotFile(steam, slotId))
            or readAll(STORED_DIR .. "/" .. tostring(steam) .. "_" .. slotId .. ".json")
        if body == nil or body == "" then return nil end
        return snapFromBody(body)
    end
    body = readAll(storedPath(steam))
        or readAll(vaultPath(steam))
        or readAll(LEGACY_STORED .. "/" .. tostring(steam) .. ".json")
        or readAll(LEGACY_VAULT .. "/" .. tostring(steam) .. ".json")
    return snapFromBody(body)
end

function numOrNull(v)
    if v == nil then return "null" end
    return string.format("%.6f", tonumber(v) or 0)
end

function boolOrNull(v)
    if v == true then return "true" end
    if v == false then return "false" end
    return "null"
end

function saveStored(steam, snap)
    ensureDir(STORED_DIR)
    ensureDir(VAULT_DIR)
    if snap.id == nil or snap.id == "" then
        snap.id = "store-" .. tostring(os.time())
    end
    if snap.source == nil or snap.source == "" then
        snap.source = "store"
    end
    local json = string.format(
        '{"version":9,"kind":"vault","id":"%s","source":"%s","stayPut":%s,"steam":"%s","classPath":"%s","species":"%s","growth":%s,"health":%s,"maxHealth":%s,"hunger":%s,"maxHunger":%s,"maxFood":%s,"carbValue":%s,"proteinValue":%s,"lipidValue":%s,"thirst":%s,"stamina":%s,"oxygen":%s,"gender":"%s","female":%s,"genderNum":%s,"skin":"%s","skinId":%s,"skinData":"%s","skinLocked":%s,"skinUnlocked":%s,"skinLockId":"%s","skinLockGrowth":%s,"primeElder":%s,"primeFlags":"%s","primeHave":%s,"mutations":"%s","unlocks":"%s","elderStacks":%s,"x":%s,"y":%s,"z":%s,"pitch":%s,"yaw":%s,"roll":%s,"capturedAt":%d}\n',
        jsonEscape(snap.id or ""),
        jsonEscape(snap.source or "store"),
        snap.stayPut == true and "true" or "false",
        jsonEscape(steam),
        jsonEscape(snap.classPath or ""),
        jsonEscape(snap.species or ""),
        numOrNull(snap.growth),
        numOrNull(snap.health),
        numOrNull(snap.maxHealth),
        numOrNull(snap.hunger),
        numOrNull(snap.maxHunger),
        numOrNull(snap.maxFood),
        numOrNull(snap.carbValue),
        numOrNull(snap.proteinValue),
        numOrNull(snap.lipidValue),
        numOrNull(snap.thirst),
        numOrNull(snap.stamina),
        numOrNull(snap.oxygen),
        jsonEscape(snap.gender or ""),
        boolOrNull(snap.female),
        numOrNull(snap.genderNum),
        jsonEscape(snap.skin or ""),
        numOrNull(snap.skinId),
        jsonEscape(snap.skinData or ""),
        snap.skinLocked == true and "true" or "false",
        snap.skinUnlocked == true and "true" or "false",
        jsonEscape(snap.skinLockId or ""),
        numOrNull(snap.skinLockGrowth or 0),
        boolOrNull(snap.primeElder),
        jsonEscape(snap.primeFlags or ""),
        numOrNull(snap.primeHave or 0),
        jsonEscape(snap.mutations or ""),
        jsonEscape(snap.unlocks or ""),
        numOrNull(snap.elderStacks or 0),
        numOrNull(snap.x),
        numOrNull(snap.y),
        numOrNull(snap.z),
        numOrNull(snap.pitch),
        numOrNull(snap.yaw),
        numOrNull(snap.roll),
        os.time()
    )
    local slotId = sanitizeSlot(snap.id)
    if slotId ~= "" then
        writeAll(slotFile(steam, slotId), json)
        appendLine(indexPath(steam), string.format(
            '{"id":"%s","species":"%s","gender":"%s","female":%s,"growth":%s,"source":"%s","skinLocked":%s,"skinUnlocked":%s,"capturedAt":%d}\n',
            jsonEscape(slotId),
            jsonEscape(snap.species or ""),
            jsonEscape(snap.gender or ""),
            boolOrNull(snap.female),
            numOrNull(snap.growth),
            jsonEscape(snap.source or "store"),
            snap.skinLocked == true and "true" or "false",
            snap.skinUnlocked == true and "true" or "false",
            os.time()
        ))
    end
    local okJson = writeAll(storedPath(steam), json)
    local okVault = writeAll(vaultPath(steam), json)
    return okJson or okVault
end

function consumeStored(steam, snap)
    snap = snap or {}
    local slotId = sanitizeSlot(snap.id)
    if slotId ~= "" then
        deleteFile(slotFile(steam, slotId))
        deleteFile(STORED_DIR .. "/" .. tostring(steam) .. "_" .. slotId .. ".json")
    end
    local idx = indexPath(steam)
    local body = readAll(idx) or ""
    local byId = {}
    local order = {}
    local latest = { at = -1, id = "" }
    for line in body:gmatch("[^\r\n]+") do
        local id = sanitizeSlot(jsonReadString(line, "id"))
        if id ~= "" and id ~= slotId then
            if byId[id] == nil then
                order[#order + 1] = id
            end
            byId[id] = line
            local at = tonumber(jsonReadNumber(line, "capturedAt")) or 0
            if at >= latest.at then
                latest = { at = at, id = id }
            end
        end
    end
    if #order > 0 then
        local out = {}
        for _, id in ipairs(order) do
            out[#out + 1] = byId[id]
        end
        writeAll(idx, table.concat(out, "\n") .. "\n")
    else
        writeAll(idx, "")
        deleteFile(idx)
    end
    local lastBody = readAll(storedPath(steam)) or readAll(vaultPath(steam))
    local last = snapFromBody(lastBody)
    local lastId = last and sanitizeSlot(last.id) or ""
    local lastIsThis = last == nil
        or (slotId ~= "" and lastId == slotId)
        or (slotId == "" and last ~= nil and tostring(last.species or "") == tostring(snap.species or ""))
    if lastIsThis then
        local nextBody = nil
        if latest.id ~= "" then
            nextBody = readAll(slotFile(steam, latest.id))
        end
        if nextBody ~= nil and nextBody ~= "" then
            writeAll(storedPath(steam), nextBody)
            writeAll(vaultPath(steam), nextBody)
        else
            deleteFile(storedPath(steam))
            deleteFile(vaultPath(steam))
            deleteFile(LEGACY_STORED .. "/" .. tostring(steam) .. ".json")
            deleteFile(LEGACY_VAULT .. "/" .. tostring(steam) .. ".json")
        end
    end
    log("consumed vault " .. tostring(steam) .. " slot=" .. tostring(slotId))
end

function savePendingRedeems()
    local lines = {}
    for _, r in ipairs(pendingRedeems) do
        lines[#lines + 1] = string.format(
            '{"id":"%s","steam":"%s","at":%d,"kind":"%s","slot":"%s","verb":"%s","tries":%d}',
            jsonEscape(r.id or ""),
            jsonEscape(r.steam or ""),
            tonumber(r.at) or 0,
            jsonEscape(r.kind or "stored"),
            jsonEscape(r.slot or ""),
            jsonEscape(r.verb or "redeem"),
            tonumber(r.tries) or 0
        )
    end
    writeAll(PENDING_REDEEMS_PATH, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

function loadPendingRedeems()
    local body = readAll(PENDING_REDEEMS_PATH)
    if body == nil or body == "" then return end
    local loaded = {}
    for line in body:gmatch("[^\r\n]+") do
        local steam = jsonReadString(line, "steam") or ""
        if steam ~= "" then
            loaded[#loaded + 1] = {
                steam = steam,
                at = jsonReadNumber(line, "at") or (os.time() + 1),
                kind = jsonReadString(line, "kind") or "stored",
                slot = jsonReadString(line, "slot") or "",
                id = jsonReadString(line, "id") or "",
                verb = jsonReadString(line, "verb") or "redeem",
                tries = jsonReadNumber(line, "tries") or 0,
            }
        end
    end
    if #loaded > 0 then
        pendingRedeems = loaded
        log("reloaded " .. tostring(#loaded) .. " pending redeem(s) after restart")
    end
end

function redeemStillWaiting(msg)
    if type(msg) ~= "string" then return false end
    return msg:find("not spawned", 1, true) ~= nil or msg:find("not on the server", 1, true) ~= nil
end

function beginRedeemAudit(steam, species, slot, percent)
    REDEEM_AUDIT_UNTIL = os.time() + 90
    REDEEM_AUDIT = {
        steam = tostring(steam or ""),
        species = tostring(species or ""),
        slot = tostring(slot or ""),
        percent = tonumber(percent) or 70,
        logged = false,
    }
end

function endRedeemAudit()
    REDEEM_AUDIT_UNTIL = 0
    REDEEM_AUDIT = nil
end

function redeemAuditActive()
    if REDEEM_AUDIT == nil then
        return false
    end
    if os.time() > (tonumber(REDEEM_AUDIT_UNTIL) or 0) then
        REDEEM_AUDIT = nil
        REDEEM_AUDIT_UNTIL = 0
        return false
    end
    return true
end

function emitResult(id, steam, verb, ok, msg)
    if id == nil or id == "" then return end
    local line = string.format(
        '{"id":"%s","ts":%d,"verb":"%s","steam":"%s","ok":%s,"msg":"%s","source":"%s"}',
        jsonEscape(id),
        os.time(),
        jsonEscape(verb or ""),
        jsonEscape(steam or ""),
        ok and "true" or "false",
        jsonEscape(msg or ""),
        MOD_NAME
    )
    appendLine(RESULTS_PATH, line)
    if PrimevalInbox and PrimevalInbox.rotateIfHuge then
        PrimevalInbox.rotateIfHuge(RESULTS_PATH)
    end
end

function snapGender(snap)
    if snap == nil then return "" end
    if snap.gender ~= nil and tostring(snap.gender) ~= "" then
        return tostring(snap.gender)
    end
    if snap.female == true then return "Female" end
    if snap.female == false then return "Male" end
    return ""
end

function writeRecap(steam, status, snap, detail)
    if steam == nil or steam == "" then return end
    ensureDir(RECAP_DIR)
    snap = snap or {}
    local nxt = "Spawn a matching juvenile, then Redeem."
    if status == "failed" then
        nxt = "Nothing vaulted. Store again, then safelog."
    elseif status == "cancelled" then
        nxt = "Store cancelled. Arm Store again when ready, then safelog."
    elseif status == "armed_lost" then
        nxt = "Store never finished. Arm Store, then safelog, if you still want this dino."
    end
    local json = string.format(
        '{"steam":"%s","status":"%s","species":"%s","gender":"%s","growth":%s,"primeHave":%s,"primeFlags":"%s","detail":"%s","next":"%s","capturedAt":%d}\n',
        jsonEscape(steam),
        jsonEscape(status or ""),
        jsonEscape(snap.species or ""),
        jsonEscape(snapGender(snap)),
        numOrNull(snap.growth),
        numOrNull(snap.primeHave or 0),
        jsonEscape(snap.primeFlags or ""),
        jsonEscape(detail or ""),
        jsonEscape(nxt),
        os.time()
    )
    writeAll(RECAP_DIR .. "/" .. tostring(steam) .. ".json", json)
    appendLine(RECAP_LOG, json)
    if PrimevalInbox and PrimevalInbox.rotateIfHuge then
        PrimevalInbox.rotateIfHuge(RECAP_LOG)
    end
    log("recap " .. tostring(steam) .. " " .. tostring(status) .. " " .. tostring(snap.species))
end

function captureAndStore(steam)
    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        return false, "not spawned — pick a dino first"
    end
    local snap = snapshotPawn(pawn)
    if skinInheritLockOnSnap then
        skinInheritLockOnSnap(steam, snap)
    end
    if snap.classPath == nil or snap.classPath == "" then
        return false, "could not read species"
    end
    if not saveStored(steam, snap) then
        return false, "failed to write vault file"
    end
    log(string.format(
        "vault keys steam=%s species=%s growth=%.3f hunger=%s thirst=%s health=%s gender=%s female=%s prime=%s/%s flags=%s mut=%s loc=%.0f,%.0f,%.0f",
        steam,
        tostring(snap.species),
        tonumber(snap.growth) or 0,
        tostring(snap.hunger),
        tostring(snap.thirst),
        tostring(snap.health),
        tostring(snap.gender),
        tostring(snap.female),
        tostring(snap.primeHave or 0),
        snap.primeElder and "prime" or "no",
        tostring(snap.primeFlags or ""),
        tostring(snap.mutations),
        snap.x or 0, snap.y or 0, snap.z or 0
    ))
    local locBit = ""
    if snap.x ~= nil then locBit = " at your current spot" end
    return true, string.format(
        "stored %s at %.0f%%%s — game safelog will finish; spawn that species as a juvie and !redeem to return here",
        snap.species,
        (tonumber(snap.growth) or 0) * 100,
        locBit
    )
end

local STORE_HINT = "start a safelog and stay in it. We snapshot you, then slay just before it finishes so the game does not keep this dino. Spawn a juvie of that species (same gender) and !redeem."

function armStore(steam)
    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        return false, "not spawned — pick a dino first"
    end
    
    -- Enforce the store arm timeout; a stale arm otherwise blocks !store forever.
    local armedAt = armedStores[steam]
    if armedAt ~= nil and pendingSnaps[steam] == nil and pendingSlays[steam] == nil
        and (os.time() - armedAt) >= JOB_LIMITS.store.timeout then
        armedStores[steam] = nil
        unregisterPlayerJob(steam, "store", steam)
    end

    local ok, why = canQueueJob(steam, "store")
    if not ok then
        return false, why
    end
    
    if armedStores[steam] ~= nil then
        return false, "store already armed — " .. STORE_HINT
    end
    
    armedStores[steam] = os.time()
    registerPlayerJob(steam, "store", { steam = steam, at = os.time() })
    log("store armed " .. steam .. " waiting for in-game safelog")
    return true, "store armed — " .. STORE_HINT
end
function cancelStoreArm(steam, reason)
    if armedStores[steam] == nil then
        return false, "no store waiting — type !store then complete a safelog"
    end
    pendingSnaps[steam] = nil
    pendingSlays[steam] = nil
    armedStores[steam] = nil
    unregisterPlayerJob(steam, "store", steam)
    log("store unarmed " .. steam .. " " .. tostring(reason))
    return true, reason or "store cancelled"
end

function forceAllPrime(pawn)
    return applyPrime(pawn, { primeElder = true, primeFlags = "1111111111" })
end

function applyPaidGrow(steam, wantSpecies, wantGrowth, withPrime)
    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        return false, "not spawned — log in as a fresh juvenile of that species first"
    end
    local livePath = classPathOf(pawn)
    local liveKey = speciesKey(livePath)
    local wantKey = speciesKey(wantSpecies)
    if liveKey == "" then
        return false, "could not read your current species"
    end
    if wantKey ~= "" and not speciesMatch(liveKey, wantKey) then
        return false, string.format("species mismatch: you are %s, grow is %s — spawn a fresh %s juvie", liveKey, wantKey, wantKey)
    end
    local g = tonumber(wantGrowth) or 0.7
    if g < 0 then g = 0 end
    if g > 1 then
        if g <= 100 then g = g / 100 else g = 1 end
    end
    local okSet, errSet = applyCapMaxes(pawn, liveKey, g)
    if okSet ~= true then
        local grew
        grew, errSet = pcall(function() pawn:SetGrowth(g) end)
        if grew ~= true then
            return false, "SetGrowth failed: " .. tostring(errSet)
        end
    end
    refillBuyVitals(pawn, { species = liveKey, growth = g, hunger = 0.75 })
    if ExecuteInGameThreadWithDelay ~= nil then
        local growSteam = steam
        local growKey = liveKey
        local growG = g
        ExecuteInGameThreadWithDelay(600, function()
            local live = livePawnFromCtrl(controllerForSteam(growSteam))
            pcall(function() applyDirectBuyStats(live, { species = growKey, growth = growG, hunger = 0.75 }, growG) end)
        end)
    end
    if withPrime ~= false then
        quietPrimeNotify(steam, 20)
        forceAllPrime(pawn)
        pendingMutationRestores[#pendingMutationRestores + 1] = {
            steam = steam,
            snap = { primeElder = true, primeFlags = "1111111111", mutations = "", unlocks = "" },
            at = os.time() + 1,
            tries = 0,
        }
    end
    return true, string.format(
        "grown %s to %.0f%% — prime flags set, mutation slots left open for you to pick",
        liveKey,
        g * 100
    )
end

function applyGrowth(steam, wantSpecies, wantGrowth)
    return applyPaidGrow(steam, wantSpecies, wantGrowth, true)
end

function redeemStored(steam, slotId)
    local ok, why = canQueueJob(steam, "redeem", slotId)
    if not ok then
        return false, why
    end
    
    local stored = loadStored(steam, slotId)
    if stored == nil or (stored.classPath == nil and stored.species == nil) then
        if slotId ~= nil and slotId ~= "" then
            return false, "that vault slot was not found"
        end
        return false, "nothing vaulted — buy a dino or use !store first"
    end
    if (stored.id == nil or stored.id == "") and slotId ~= nil then
        stored.id = sanitizeSlot(slotId)
    end
    local ctrl = controllerForSteam(steam)
    if ctrl == nil then
        return false, "not on the server — join the Isle, spawn a juvenile of " .. tostring(stored.species) .. ", then redeem"
    end
    local pawn = livePawnFromCtrl(ctrl)    if pawn == nil then
        return false, "not spawned — spawn a juvenile of " .. tostring(stored.species) .. " then redeem"
    end
    local liveKey = speciesKey(classPathOf(pawn))
    local wantKey = speciesKey(stored.classPath ~= nil and stored.classPath ~= "" and stored.classPath or stored.species)
    if liveKey == "" then
        return false, "could not read your current species"
    end
    if wantKey ~= "" and not speciesMatch(liveKey, wantKey) then
        return false, string.format("species mismatch: you are %s, vault is %s — spawn a matching juvie", liveKey, wantKey)
    end
    if stored.source == "buy" then
        stored.stayPut = true
    end
    if stored.source == "gamble" then
        stored.stayPut = true
        if stored.hunger == nil then
            stored.hunger = 0.75
        end
    end
    quietPrimeNotify(steam, 20)
    local applied
    if stored.source == "buy" then
        if pendingNativeBuyRedeems[steam] ~= nil then
            return false, "a bought-dino redeem is already pending"
        end
        clearSteamPawnJobs(steam)
        applied = applyBuyInject(pawn, stored)
        local oldMaxHunger = tryNumber(pawn, {
            "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
        })
        beginRedeemAudit(steam, stored.species or liveKey, stored.id, 70)
        applyDirectBuyStats(pawn, stored, 0.70)
        -- Bonus only. ServerGrow no-ops unless an admin controller is online.
        pcall(function() invokeAdminGrow(steam, 70) end)
        pendingNativeBuyRedeems[steam] = {
            steam = steam,
            snap = stored,
            oldMaxHunger = oldMaxHunger,
            wantGrowth = 0.70,
            at = os.time() + 1,
            tries = 0,
        }
        applied[#applied + 1] = "cap-grow"
    elseif stored.source == "gamble" then
        if pendingNativeBuyRedeems[steam] ~= nil then
            return false, "a redeem is already pending"
        end
        clearSteamPawnJobs(steam)
        applied = {}
        if applyGender(pawn, stored) then applied[#applied + 1] = "gender" end
        local mutN = applyMutations(pawn, stored.mutations)
        if mutN > 0 then applied[#applied + 1] = "mutations:" .. tostring(mutN) end
        if applyElderStacks(pawn, stored.elderStacks) then applied[#applied + 1] = "elderStacks" end
        local g = tonumber(stored.growth) or 0.60
        if g < 0.01 then g = 0.60 end
        if g > 1 then g = g / 100 end
        local pct = math.floor((g * 100) + 0.5)
        local oldMaxHunger = tryNumber(pawn, {
            "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
        })
        beginRedeemAudit(steam, stored.species or liveKey, stored.id, pct)
        applyDirectBuyStats(pawn, stored, g)
        pcall(function() invokeAdminGrow(steam, pct) end)
        pendingNativeBuyRedeems[steam] = {
            steam = steam,
            snap = stored,
            oldMaxHunger = oldMaxHunger,
            wantGrowth = g,
            at = os.time() + 1,
            tries = 0,
        }
        applied[#applied + 1] = "cap-grow"
    else
        local pct = (tonumber(stored.growth) or 0) * 100
        if pct < 1 then pct = 70 end
        if pct > 100 then pct = 100 end
        beginRedeemAudit(steam, stored.species or liveKey, stored.id, pct)
        pcall(function() invokeAdminGrow(steam, pct) end)
        -- Store redeem: caps only — do not run shop refillBuyVitals (ABY 50%
        -- + absolute hunger clamped to 1.0), which stomps live hunger/diet.
        local g = tonumber(stored.growth) or 0.70
        if g < 0.01 then g = 0.70 end
        if g > 1 then g = g / 100 end
        local species = speciesKey(classPathOf(pawn))
        local fromSnap = stored.classPath ~= nil and stored.classPath ~= "" and stored.classPath or stored.species
        if fromSnap ~= nil and fromSnap ~= "" then
            species = speciesKey(fromSnap)
        end
        applyCapMaxes(pawn, species, g)
        if skinRememberFromSnap then
            -- Upgrade old custom colors and arm restore before any native
            -- redeem setters can make SkinCode rebuild CustomizerData.
            skinRememberFromSnap(
                steam,
                stored,
                tryNumber(pawn, { "GetGrowth", "Growth" })
            )
        end
        applied = applySnapshot(pawn, stored, { skipGrowth = true, vaultVitals = true })
        ensureAdultMaxHunger(pawn, stored, nil)
        restoreVaultHunger(pawn, stored)
        queueStatHold(steam, stored, 1, 6, false)
        queueMutationRestore(steam, stored)
        applied[#applied + 1] = "cap-grow"
        endRedeemAudit()
    end
    log(string.format(
        "vault apply %s slot=%s %s loc=%.0f,%.0f,%.0f stay=%s",
        steam,
        tostring(slotId or ""),
        table.concat(applied, ","),
        stored.x or 0,
        stored.y or 0,
        stored.z or 0,
        tostring(stored.stayPut == true)
    ))
    if #applied == 0 then
        return false, "vault restore failed — no setters accepted"
    end
    local locBit = " — staying where you are"
    if stored.stayPut ~= true and stored.x ~= nil then
        locBit = " — returning to stored location"
    end
    if stored.source == "gamble" then
        return true, string.format(
            "entomb redeem queued for %s slot=%s mut=%s — vault held until %.0f%% growth, hunger 75%%, ABY 50%% verify",
            stored.species or liveKey,
            tostring(stored.id or ""),
            tostring(stored.mutations or ""),
            (tonumber(stored.growth) or 0.60) * 100
        )
    end
    if stored.source ~= "buy" then
        consumeStored(steam, stored)
        return true, string.format("restored %s (%.0f%%) [%s]%s — vault wiped, store again before you die", stored.species or liveKey, (stored.growth or 0) * 100, table.concat(applied, ","), locBit)
    end
    return true, string.format(
        "admin grow queued for %s — vault held until 70%% MaxHunger and vitals verify",
        stored.species or liveKey
    )
end


 function slayPawn(pawn, ctrl)
     if pawn == nil then return false end
     local ok = false
     pcall(function()
         pawn:SetHealth(0)
         ok = true
     end)

     log("slay attempted before native safelog")
     return ok
 end

 function requestSelfKill(steam, source)
     steam = normalizeSteam(tostring(steam or ""))
     source = tostring(source or "unknown")
 
     if steam == "" then
         return false, "missing SteamID"
     end
 
     local cooldown = COOLDOWN_TIMES.selfkill or 300
     local cooldownKey = steam .. "_selfkill"
     local lastKill = PLAYER_COOLDOWNS[cooldownKey]
 
     if lastKill ~= nil then
         local elapsed = os.time() - lastKill
         if elapsed < cooldown then
             return false, string.format(
                 "self-kill is on cooldown for %ds",
                 cooldown - elapsed
             )
         end
     end

    -- Do not interfere with the vault/safelog workflow.
     if armedStores[steam] ~= nil
         or pendingSnaps[steam] ~= nil
         or pendingSlays[steam] ~= nil then
         return false, "self-kill is unavailable while store/safelog is active"
     end

     local ctrl = controllerForSteam(steam)
     if ctrl == nil then
         return false, "you are not currently on the server"
     end
 
     local pawn = livePawnFromCtrl(ctrl)
     if pawn == nil or not isLiveDinoPawn(pawn) then
         return false, "you must be spawned as a living dinosaur"
     end
 
     local ok = slayPawn(pawn, ctrl)
     if not ok then
         return false, "the game refused the self-kill request"
     end
 
     PLAYER_COOLDOWNS[cooldownKey] = os.time()
 
     local message = "self-kill complete"
     queueNotify(steam, message)
 
     log(string.format(
         "self-kill steam=%s source=%s",
         steam,
         source
     ))
 
     return true, message
 end

function finishStoreBySlay(steam, ctrl)
    pendingSlays[steam] = nil
    ctrl = ctrl or controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        pawn = livePawnFromCtrl(controllerForSteam(steam))
    end
    if isLiveDinoPawn(pawn) then
        local snap = snapshotPawn(pawn)
        if skinInheritLockOnSnap then
            skinInheritLockOnSnap(steam, snap)
        end
        snap.capturedAt = os.time()
        pendingSnaps[steam] = snap
        log("refreshed snapshot before slay " .. steam .. " " .. tostring(snap.species) .. string.format(" loc=%.0f,%.0f,%.0f", snap.x or 0, snap.y or 0, snap.z or 0))
    end
    local committed = commitPendingSnap(steam, ctrl)
    if committed ~= true then
        notifyCtrl(ctrl, "vault was NOT saved — your dino was not slain. Reconnect normally and try Store again.")
        queueNotify(steam, "vault was NOT saved — your dino was not slain. Try Store again.")
        log("store slay aborted because vault commit failed " .. tostring(steam))
        return
    end
    if skinMarkStoreSlay then
        -- Vault skinData is committed; release only the old live override
        -- before the juvenile used for Redeem appears.
        skinMarkStoreSlay(steam)
    end
    if isLiveDinoPawn(pawn) then
        -- Shrink to 5% to prevent self-feeding abuse during safelog.
        local shrinkOk = false
        pcall(function()
            pawn:SetGrowth(0.05)
            shrinkOk = true
        end)
        if shrinkOk then
            log("shrink-before-slay " .. steam .. " → 5%")
        else
            log("shrink-before-slay FAILED " .. steam .. " — proceeding with slay anyway")
        end
        
        slayPawn(pawn, ctrl)
        notifyCtrl(ctrl, "vault saved and slain — let safelog finish, then spawn a matching juvie and Redeem")
        queueNotify(steam, "vault saved and slain — let safelog finish, then spawn a matching juvie and Redeem")
        log("slay before native safelog " .. steam)
    else
        log("slay skipped, pawn already gone " .. tostring(steam))
    end
end
function pollPendingSlays()
    local now = os.time()
    local due = {}
    for steam, at in pairs(pendingSlays) do
        if tonumber(at) ~= nil and now >= tonumber(at) then
            due[#due + 1] = steam
        end
    end
    for _, steam in ipairs(due) do
        log("slay timer fired " .. steam)
        finishStoreBySlay(steam, controllerForSteam(steam))
    end
end

function pollPendingTeleports()
    if #pendingTeleports == 0 then return end
    local now = os.time()
    local keep = {}
    for _, t in ipairs(pendingTeleports) do
        if now >= t.at then
            local ctrl = controllerForSteam(t.steam)
            local pawn = livePawnFromCtrl(ctrl)
            local ok = teleportPawn(pawn, t.snap, ctrl)
            log("delayed teleport " .. tostring(t.steam) .. " try=" .. tostring(t.tries) .. " ok=" .. tostring(ok))
            if ok then
                t.hits = (t.hits or 0) + 1
            else
                t.hits = 0
            end
            if t.hits < 1 and t.tries < 1 then
                t.tries = (t.tries or 0) + 1
                t.at = now + 1
                keep[#keep + 1] = t
            end
        else
            keep[#keep + 1] = t
        end
    end
    pendingTeleports = keep
end

BUY_GROW_FINAL = 0.70
BUY_MUTATION_STAGES = {
    { growth = 0.35, slot = "MutationSlot1", msg = "35% — pick mutation 1 (juvenile). You grow again after you pick." },
    { growth = 0.50, slot = "MutationSlot2", msg = "50% — pick mutation 2 (sub-adult). You grow to 70% after you pick." },
    { growth = BUY_GROW_FINAL, slot = "MutationSlot3", msg = "70% — pick mutation 3 (adult). Prime slot 4 should also be open." },
}
HUNGER_FILL_SECONDS = 12

function dropSteamJobs(list, steam)
    local keep = {}
    for _, job in ipairs(list or {}) do
        if job.steam ~= steam then
            keep[#keep + 1] = job
        end
    end
    return keep
end

function clearSteamPawnJobs(steam)
    pendingTeleports = dropSteamJobs(pendingTeleports, steam)
    pendingMutationRestores = dropSteamJobs(pendingMutationRestores, steam)
    pendingHungerFills = dropSteamJobs(pendingHungerFills, steam)
    pendingBuyGrows = dropSteamJobs(pendingBuyGrows, steam)
    pendingBuyInjects = dropSteamJobs(pendingBuyInjects, steam)
end

function queueBuyInject(steam, snap, pawn)
    pendingBuyInjects[#pendingBuyInjects + 1] = {
        steam = steam,
        snap = snap,
        addr = pawnAddr(pawn),
        next = 1,
        at = os.time() + 1,
        tries = 0,
    }
    log("buy inject queued growth@+1s ABY+hunger@+0.8s " .. tostring(steam))
end

function applyBuyHunger(steam, addr, snap)
    local pawn = livePawnFromCtrl(controllerForSteam(steam))
    if pawn == nil then
        log("buy inject vitals skipped, no pawn " .. tostring(steam))
        return false
    end
    -- SetGrowth often rebuilds the pawn; follow the live one instead of aborting.
    local ok = refillBuyVitals(pawn, snap)
    local liveH = tryNumber(pawn, { "GetHunger", "Hunger", "GetCurrentHunger", "CurrentHunger" })
    local liveF = tryNumber(pawn, { "GetFood", "Food", "GetFoodValue", "FoodValue" })
    local ns
    pcall(function() ns = pawn.NutrientsStruct end)
    if ns == nil then
        pcall(function() ns = pawn:GetNutrientsStruct() end)
    end
    local carb = ns and tryNumber(ns, { "CarbValue", "carbValue", "AlphaValue" })
    local prot = ns and tryNumber(ns, { "ProteinValue", "proteinValue", "BetaValue" })
    local lipid = ns and tryNumber(ns, { "LipidValue", "lipidValue", "GammaValue" })
    log(string.format(
        "buy inject hunger75 diet50 H=%s F=%s A=%s B=%s G=%s addr=%s",
        tostring(liveH), tostring(liveF), tostring(carb), tostring(prot), tostring(lipid),
        pawnAddr(pawn)
    ))
    return ok == true
end

function applyBuyVitalsAfterGrowth(steam, snap, attempt)
    attempt = tonumber(attempt) or 1
    if applyBuyHunger(steam, "", snap) then
        return
    end
    if attempt >= 6 or ExecuteInGameThreadWithDelay == nil then
        log("buy inject ABY+hunger gave up after " .. tostring(attempt) .. " attempts")
        return
    end
    ExecuteInGameThreadWithDelay(400, function()
        pcall(function() applyBuyVitalsAfterGrowth(steam, snap, attempt + 1) end)
    end)
end

function nearValue(value, target, frac)
    if value == nil or target == nil then return false end
    return math.abs(value - target) <= math.max(1, math.abs(target) * (frac or 0.12))
end

function nutrientHalf(value, maxHunger, maxFood)
    if value == nil then return false end
    -- Native SetNutrientSlotValue(50) is percent. The bar scale may be
    -- MaxFood or MaxHunger depending on species / patch.
    return nearValue(value, (maxFood or 0) * 0.50, 0.12)
        or nearValue(value, (maxHunger or 0) * 0.50, 0.12)
end

function nativeVitalsVerified(pawn, snap, wantGrowth)
    if pawn == nil then return false end
    local species = speciesKey(classPathOf(pawn))
    if snap ~= nil then
        local fromSnap = snap.classPath ~= nil and snap.classPath ~= "" and snap.classPath or snap.species
        if fromSnap ~= nil and fromSnap ~= "" then
            species = speciesKey(fromSnap)
        end
    end
    local cap = capForSpecies(species, wantGrowth or 0.70)
    local maxHunger = pawnMaxHunger(pawn)
    local hunger = tryNumber(pawn, {
        "GetHunger", "Hunger", "GetCurrentHunger", "CurrentHunger",
    })
    local maxFood = tryNumber(pawn, {
        "GetMaxFoodValue", "MaxFoodValue",
        "GetMaxFood", "MaxFood", "GetFoodMax", "FoodMax",
    })
    local wantH = cap and tonumber(cap.maxHunger)
    local wantF = cap and tonumber(cap.maxFood)
    if wantH ~= nil and (maxHunger == nil or maxHunger < (wantH * 0.85)) then
        maxHunger = wantH
    end
    if wantF ~= nil and (maxFood == nil or maxFood < (wantF * 0.85)) then
        maxFood = wantF
    end
    local nutrients
    pcall(function() nutrients = pawn.NutrientsStruct end)
    if nutrients == nil then
        pcall(function() nutrients = pawn:GetNutrientsStruct() end)
    end
    local carb = nutrients and tryNumber(nutrients, { "CarbValue", "carbValue", "AlphaValue" })
    local protein = nutrients and tryNumber(nutrients, { "ProteinValue", "proteinValue", "BetaValue" })
    local lipid = nutrients and tryNumber(nutrients, { "LipidValue", "lipidValue", "GammaValue" })
    local liveH = pawnMaxHunger(pawn)
    log(string.format(
        "vitals check Hmax=%s wantH=%s H=%s Fmax=%s A=%s B=%s Y=%s",
        tostring(liveH), tostring(wantH), tostring(hunger), tostring(maxFood),
        tostring(carb), tostring(protein), tostring(lipid)
    ))
    if liveH == nil or hunger == nil or liveH <= 1.5 then
        return false
    end
    local capOk = wantH == nil or nearValue(liveH, wantH, 0.12)
    local hungerOk = nearValue(hunger, liveH * 0.75, 0.12)
    local dietOk = nutrientHalf(carb, liveH, maxFood)
        and nutrientHalf(protein, liveH, maxFood)
        and nutrientHalf(lipid, liveH, maxFood)
    -- Cap match + 75% hunger + ABY 50% is the shop contract.
    return capOk == true and hungerOk == true and dietOk == true
end

function pollPendingNativeBuyRedeems()
    local now = os.time()
    for steam, job in pairs(pendingNativeBuyRedeems) do
        if now >= (job.at or 0) then
            local pawn = livePawnFromCtrl(controllerForSteam(steam))
            local growth = tryNumber(pawn, { "GetGrowth", "Growth" })
            local maxHunger = tryNumber(pawn, {
                "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
            })
            local speciesReady = pawn ~= nil and speciesMatch(
                speciesKey(classPathOf(pawn)),
                speciesKey(job.snap.species or job.snap.classPath)
            )
            local wantG = tonumber(job.wantGrowth) or 0.70
            local grew = growth ~= nil and growth >= (wantG - 0.04) and growth <= (wantG + 0.04)
            if speciesReady then
                applyDirectBuyStats(pawn, job.snap, wantG)
                growth = tryNumber(pawn, { "GetGrowth", "Growth" })
                maxHunger = pawnMaxHunger(pawn)
                grew = growth ~= nil and growth >= (wantG - 0.04) and growth <= (wantG + 0.04)
            end
            if speciesReady and grew and nativeVitalsVerified(pawn, job.snap, wantG) then
                applyPrime(pawn, job.snap)
                if job.snap.source == "gamble" then
                    applyElderStacks(pawn, job.snap.elderStacks)
                end
                queueMutationRestore(steam, job.snap)
                consumeStored(steam, job.snap)
                if job.snap.source == "gamble" then
                    queueNotify(steam, "Entombed restored: 60% growth, ABY 50%, hunger 75%, juvie + sub + 4 inherited.")
                    log("cap gamble redeem verified and consumed " .. tostring(steam) .. " slot=" .. tostring(job.snap.id or "") .. " mut=" .. tostring(job.snap.mutations or ""))
                else
                    queueNotify(steam, "Bought dino restored: 70% growth, ABY 50%, hunger 75%, Prime retained.")
                    log("cap buy redeem verified and consumed " .. tostring(steam))
                    pcall(function() recordSpeciesCap(pawn, "buy-redeem") end)
                end
                pendingNativeBuyRedeems[steam] = nil
                endRedeemAudit()
            else
                job.tries = (job.tries or 0) + 1
                if job.tries >= 12 then
                    queueNotify(steam, "Redeem did not verify; your vault was NOT consumed. Contact staff.")
                    log(string.format(
                        "cap buy redeem failed; vault retained %s growth=%s Hmax=%s",
                        tostring(steam), tostring(growth), tostring(maxHunger)
                    ))
                    pendingNativeBuyRedeems[steam] = nil
                    endRedeemAudit()
                else
                    job.at = now + 1
                end
            end
        end
    end
end

function pollPendingBuyInjects()
    if #pendingBuyInjects == 0 then return end
    local now = os.time()
    local keep = {}
    for _, job in ipairs(pendingBuyInjects) do
        local pawn = livePawnFromCtrl(controllerForSteam(job.steam))
        local addr = pawnAddr(pawn)
        if pawn == nil then
            job.tries = (job.tries or 0) + 1
            if job.tries < 20 then
                keep[#keep + 1] = job
            else
                log("buy inject aborted, pawn gone " .. tostring(job.steam))
            end
        elseif now < (job.at or 0) then
            keep[#keep + 1] = job
        elseif job.next == 1 then
            job.addr = addr
            job.tries = 0
            local growth = tonumber(job.snap and job.snap.growth) or 0.70
            if growth < 0.01 then growth = 0.01 end
            if growth > 1 then growth = 1 end
            local previousGrowth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 0
            local hungerMaxBefore = tryNumber(pawn, {
                "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
            })
            pcall(function() pawn:SetGrowth(growth) end)
            local liveG = tryNumber(pawn, { "GetGrowth", "Growth" })
            local hungerMaxAfter = tryNumber(pawn, {
                "GetMaxHunger", "MaxHunger", "GetHungerMax", "HungerMax",
            })
            log(string.format(
                "buy inject SetGrowth %.2f oldG=%s liveG=%s Hmax=%s->%s",
                growth,
                tostring(previousGrowth),
                tostring(liveG),
                tostring(hungerMaxBefore),
                tostring(hungerMaxAfter)
            ))
            queueMutationRestore(job.steam, job.snap)
            local steam = job.steam
            local snap = job.snap
            if ExecuteInGameThreadWithDelay ~= nil then
                ExecuteInGameThreadWithDelay(800, function()
                    pcall(function() applyBuyVitalsAfterGrowth(steam, snap, 1) end)
                end)
            else
                job.next = 2
                job.at = now + 1
                keep[#keep + 1] = job
            end
        elseif job.next == 2 then
            applyBuyHunger(job.steam, job.addr, job.snap)
        end
    end
    pendingBuyInjects = keep
end

function queueStatHold(steam, snap, delay, times, shopVitals)
    if steam == nil or steam == "" then return end
    local firstAt = os.time() + (tonumber(delay) or 1)
    local left = tonumber(times) or 8
    if left < 1 then left = 1 end
    local shop = shopVitals == true
    for _, job in ipairs(pendingHungerFills) do
        if job.steam == steam then
            job.at = firstAt
            job.left = left
            job.snap = snap or job.snap
            job.gap = 2
            job.tries = 0
            job.shopVitals = shop
            return
        end
    end
    pendingHungerFills[#pendingHungerFills + 1] = {
        steam = steam,
        snap = snap,
        at = firstAt,
        left = left,
        gap = 2,
        tries = 0,
        shopVitals = shop,
    }
end

function queueHungerFill(steam, delay, times)
    queueStatHold(steam, nil, delay, times, true)
end

function pollPendingHungerFills()
    if #pendingHungerFills == 0 then return end
    local now = os.time()
    local keep = {}
    for _, job in ipairs(pendingHungerFills) do
        if now >= (job.at or 0) then
            local pawn = livePawnFromCtrl(controllerForSteam(job.steam))
            if pawn ~= nil then
                job.tries = 0
                if job.shopVitals == true then
                    refillBuyVitals(pawn, job.snap)
                else
                    restoreVaultHunger(pawn, job.snap)
                end
                job.left = (job.left or 1) - 1
                if job.left > 0 then
                    job.at = now + (job.gap or 2)
                    keep[#keep + 1] = job
                end
            else
                job.tries = (job.tries or 0) + 1
                if job.tries < 12 then
                    job.at = now + 1
                    keep[#keep + 1] = job
                else
                    log("vitals hold dropped, pawn gone " .. tostring(job.steam))
                end
            end
        else
            keep[#keep + 1] = job
        end
    end
    pendingHungerFills = keep
end

function queueBuyMutationGrow(steam, snap)
    pendingBuyGrows[#pendingBuyGrows + 1] = {
        steam = steam,
        snap = snap,
        stage = 1,
        at = 0,
        tries = 0,
    }
end

function enterBuyGrowStage(job, pawn)
    local stage = BUY_MUTATION_STAGES[job.stage]
    if stage == nil then return false end
    if pawn ~= nil and stage.growth ~= nil then
        pcall(function() pawn:SetGrowth(stage.growth) end)
        if job.stage == 1 then
            applyPrime(pawn, job.snap)
        end
        queueHungerFill(job.steam)
    end
    queueNotify(job.steam, stage.msg)
    job.at = os.time()
    log(string.format(
        "buy mut stage %d %s g=%.2f",
        job.stage,
        tostring(job.steam),
        stage.growth or -1
    ))
    return true
end

function pollPendingBuyGrows()
    if #pendingBuyGrows == 0 then return end
    local keep = {}
    for _, job in ipairs(pendingBuyGrows) do
        local stage = BUY_MUTATION_STAGES[job.stage]
        if stage == nil then
            -- finished
        else
            local pawn = livePawnFromCtrl(controllerForSteam(job.steam))
            if job.at == 0 then
                enterBuyGrowStage(job, pawn)
                keep[#keep + 1] = job
            elseif pawn == nil then
                job.tries = (job.tries or 0) + 1
                if job.tries < 30 then
                    keep[#keep + 1] = job
                else
                    log("buy mut aborted, pawn gone " .. tostring(job.steam))
                end
            else
                job.tries = 0
                local filled = mutationSlotFilled(pawn, stage.slot)
                    or mutationFilledCount(pawn) >= job.stage
                if filled then
                    job.stage = job.stage + 1
                    job.at = 0
                    if BUY_MUTATION_STAGES[job.stage] ~= nil then
                        keep[#keep + 1] = job
                    else
                        fillHunger(pawn, 0.75)
                        queueHungerFill(job.steam)
                        queueNotify(job.steam, "Buy grow finished — 70%, prime met. Check all mutation slots.")
                        log("buy mut done " .. tostring(job.steam))
                    end
                else
                    keep[#keep + 1] = job
                end
            end
        end
    end
    pendingBuyGrows = keep
end

function pollPendingMutationRestores()
    if #pendingMutationRestores == 0 then return end
    local now = os.time()
    local keep = {}
    for _, t in ipairs(pendingMutationRestores) do
        if now >= t.at then
            local ctrl = controllerForSteam(t.steam)
            local pawn = livePawnFromCtrl(ctrl)
            local written = 0
            local liveFemale = nil
            if pawn ~= nil then
                if (t.snap and t.snap.source) == "store" then
                    local applied = applyStoredRestore(pawn, t.snap)
                    if skinRememberFromSnap then
                        skinRememberFromSnap(t.steam, t.snap)
                    end
                    written = 0
                    for _, name in ipairs(applied) do
                        if tostring(name):find("mutations", 1, true) then
                            written = tonumber(tostring(name):match(":(%d+)")) or 1
                        end
                    end
                else
                    written = applyMutations(pawn, t.snap.mutations)
                end
                _, liveFemale = genderFrom(pawn)
            end
            local live = pawn ~= nil and collectMutations(pawn) or ""
            local wantFemale = wantedFemale(t.snap)
            log("delayed restore " .. tostring(t.steam) .. " try=" .. tostring(t.tries) .. " mut=" .. tostring(written) .. " live=" .. tostring(live) .. " gender=" .. tostring(liveFemale) .. " want=" .. tostring(wantFemale))
            local storeRetry = (t.snap and t.snap.source) == "store" and (t.tries or 0) < 4
            local buyRetry = (t.snap and t.snap.source) ~= "store" and (t.tries or 0) < 1 and written == 0
            if storeRetry or buyRetry then
                t.tries = (t.tries or 0) + 1
                t.at = now + (storeRetry and 1 or 2)
                keep[#keep + 1] = t
            end
        else
            keep[#keep + 1] = t
        end
    end
    pendingMutationRestores = keep
end

function pollPendingCommits()
    local due = {}
    for steam, _ in pairs(pendingSnaps) do
        due[#due + 1] = steam
    end
    for _, steam in ipairs(due) do
        if pendingSlays[steam] ~= nil then
            -- wait for the last-second slay; do not let native safelog win first
        else
            local snap = pendingSnaps[steam]
            if snap ~= nil then
                local ctrl = controllerForSteam(steam)
                local pawn = livePawnFromCtrl(ctrl)
                local dinoGone = ctrl ~= nil and not isLiveDinoPawn(pawn)
                local stale = (os.time() - (tonumber(snap.capturedAt) or 0)) >= 90
                if dinoGone or (ctrl == nil and stale) then
                    log("commit after dino despawn " .. steam)
                    commitPendingSnap(steam, ctrl)
                end
            end
        end
    end
end

function onPrepareSafeLogout(selfParam)
    local steam, ctrl = steamFromHookSelf(selfParam)
    if steam == "" then
        log("PrepareSafeLogout missing steam")
        return
    end
    if skinMarkSafeLogout then
        skinMarkSafeLogout(steam)
    end
    if armedStores[steam] == nil then
        log("in-game safelog (not storing) " .. steam)
        return
    end
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        pawn = livePawnFromCtrl(controllerForSteam(steam))
    end
    if pawn == nil then
        log("PrepareSafeLogout no pawn " .. steam)
        return
    end
    if pendingSnaps[steam] ~= nil then
        return
    end
    local snap = snapshotPawn(pawn)
    if skinInheritLockOnSnap then
        skinInheritLockOnSnap(steam, snap)
    end
    snap.capturedAt = os.time()
    pendingSnaps[steam] = snap
    pendingSlays[steam] = os.time() + SAFELOG_KILL_DELAY
    notifyCtrl(ctrl, "safelog started — stay in it. We slay you at the last second so this dino is not kept.")
    queueNotify(steam, "safelog started — stay in the safelog until the slay")
    log("captured live pawn on PrepareSafeLogout " .. steam .. " " .. tostring(snap.species) .. " mut=" .. tostring(snap.mutations) .. " slay in " .. tostring(SAFELOG_KILL_DELAY) .. "s")
end

function onCancelSafeLogout(selfParam)
    local steam, ctrl = steamFromHookSelf(selfParam)
    if steam == "" then return end
    if skinCancelSafeLogout then
        skinCancelSafeLogout(steam)
    end
    -- Only abort once a safelog snap is in progress. Spurious CancelLogout while
    -- merely armed (before PrepareSafeLogout) used to wipe the arm and look like
    -- an "auto cancel" ~2s after Store.
    if pendingSnaps[steam] == nil then
        return
    end
    local snap = pendingSnaps[steam]
    pendingSnaps[steam] = nil
    pendingSlays[steam] = nil
    armedStores[steam] = nil
    unregisterPlayerJob(steam, "store", steam)
    writeRecap(steam, "cancelled", snap, "in-game safelog was cancelled")
    notifyCtrl(ctrl, "recap: store cancelled — safelog was cancelled")
    queueNotify(steam, "recap: store cancelled — safelog was cancelled")
    log("store cancelled with safelog cancel " .. steam)
end

function onGameLogout(selfParam, exitingParam)
    local steam, ctrl = steamFromHookSelf(exitingParam)
    if steam == "" then
        steam, ctrl = steamFromHookSelf(selfParam)
    end
    if steam == "" then return end
    if skinMarkGameLogout then
        skinMarkGameLogout(steam)
    end
    -- Drop queued pawn jobs (teleports, stat holds, grows) so they cannot be
    -- applied to this player's next pawn after relog.
    clearSteamPawnJobs(steam)
    if pendingSlays[steam] ~= nil then
        finishStoreBySlay(steam, ctrl)
    elseif pendingSnaps[steam] ~= nil then
        commitPendingSnap(steam, ctrl)
    elseif armedStores[steam] ~= nil then
        armedStores[steam] = nil
        writeRecap(steam, "armed_lost", nil, "left the game while store was armed, before safelog finished")
        notifyCtrl(ctrl, "recap: store armed but not saved — you left before safelog finished")
        queueNotify(steam, "recap: store armed but not saved")
    end
    -- A failed commit keeps pendingSnaps for retry; otherwise nothing is left to
    -- finish, so release the arm and job lock.
    if pendingSnaps[steam] == nil then
        armedStores[steam] = nil
        pendingSlays[steam] = nil
    end
    -- Clear all pending jobs for this player
    clearPlayerJobs(steam)
end
function tryHook(path, fn)
    local ok, err = pcall(function()
        RegisterHook(path, fn)
    end)
    if ok then
        log("hook ok " .. path)
    else
        log("hook miss " .. path .. " " .. tostring(err))
    end
end

function registerLogoutHooks()
    if LOGOUT_HOOKS_REGISTERED then return end
    LOGOUT_HOOKS_REGISTERED = true
    local prepare = {
        "/Script/TheIsle.TIPlayerController:PrepareSafeLogout",
        "/Script/TheIsle.TIPlayerController:ServerPrepareSafeLogout",
        "/Script/TheIsle.TIPlayerController:SafeLogout",
        "/Script/TheIsle.TIPlayerController:StartSafeLogout",
    }
    for _, path in ipairs(prepare) do
        tryHook(path, onPrepareSafeLogout)
    end
    local cancel = {
        "/Script/TheIsle.TIPlayerController:CancelSafeLogout",
        "/Script/TheIsle.TIPlayerController:CancelLogout",
        "/Script/TheIsle.TIPlayerController:AbortSafeLogout",
    }
    for _, path in ipairs(cancel) do
        tryHook(path, onCancelSafeLogout)
    end
    
    -- ZERO-LOG NOISE DEATH LIFECYCLE MONITORING
    -- Instead of relying on brittle game function hooks that constantly break,
    -- this monitors the engine's built-in Actor lifecycle safely.
    if skinOnPlayerPawnDeath then
        NotifyOnNewObject("/Script/TheIsle.TISurvivalCharacter", function(pawn)
            -- Hooks into the standard Unreal engine level 'Destroyed' event on the pawn itself
            pcall(function()
                pawn:RegisterHook("ReceiveDestroyed", function(self)
                    skinOnPlayerPawnDeath(self)
                end)
            end)
        end)
    end
    
    local logout = {
        "/Script/Engine.GameModeBase:K2_OnLogout",
    }
    for _, path in ipairs(logout) do
        tryHook(path, onGameLogout)
    end
end


function handleCmdLine(line)
    local verb0 = string.lower(string.match(line, "^%s*(%S+)") or "")
    if verb0 == "census" then
        local n = writeCensus()
        log("census " .. tostring(n))
        return
    end

    local verb, steam = string.match(line, "^%s*(%S+)%s+(%d+)")
    if verb == nil or steam == nil then return end

    local extra = string.match(line, "^%s*%S+%s+%d+%s+(.-)%s*$") or ""
    extra = extra:gsub("%s+$", "")
    verb = string.lower(verb)

    local steamId = normalizeSteam(steam)
    if steamId ~= "" then
        knownSteams[steamId] = true
        steam = steamId
    end

    log("cmd.flag " .. verb .. " " .. steam .. " " .. extra)

    if verb == "store" or verb == "safelog" then
        local ok, msg = armStore(steam)
        queueNotify(steam, msg)
        log(tostring(msg))
    elseif verb == "cancelstore" then
        local ok, msg = cancelStoreArm(steam, "store cancelled")
        queueNotify(steam, msg)
    elseif verb == "selfkill" then
        local ok, msg = requestSelfKill(steam, "discord-cmd")
        queueNotify(steam, msg)
        log("selfkill " .. tostring(ok) .. " " .. steam .. " " .. tostring(msg))
    elseif verb == "redeem" then
        local dup = false
        for _, r in ipairs(pendingRedeems) do
            if r.steam == steam and r.kind == "stored" and (r.slot or "") == extra then dup = true end
        end
        if not dup then
            pendingRedeems[#pendingRedeems + 1] = { steam = steam, at = os.time() + 3, kind = "stored", slot = extra }
        end
        queueNotify(steam, "redeem in 3s — stay spawned as that juvenile")
    elseif verb == "storeinfo" then
        handleChat(steam, "!storeinfo")
    elseif verb == "prime" or verb == "primeinfo" then
        handleChat(steam, "!prime")
    elseif verb == "grow" or verb == "apply" then
        queueNotify(steam, "grow is retired — buy a dino in Discord, spawn as that species, then redeem")
    elseif verb == "tpinfo" then
        local ok, msg = saveLiveReport(steam)
        log("tpinfo " .. steam .. " " .. tostring(msg))
    elseif verb == "tpstart" then
        local target, req = string.match(extra, "(%d+)%s+(%S+)")
        local ok, msg = startFriendTp(steam, target, req)
        log("tpstart " .. tostring(ok) .. " " .. tostring(msg))
    elseif verb == "tpcancel" then
        local ok, msg = cancelFriendTp(extra ~= "" and extra or steam, "teleport canceled")
        log("tpcancel " .. tostring(ok) .. " " .. tostring(msg))
    end
end

function pollCmdFlag()
    local body = readAll(CMD_FLAG)
    if body ~= nil and body ~= "" then
        writeAll(CMD_FLAG, "")
        log("legacy cmd.flag — use inbox/*.json")
        for line in body:gmatch("[^\r\n]+") do
            handleCmdLine(line)
        end
    end
end

function handleInboxLine(line)
    local id = jsonReadString(line, "id") or ""
    if id ~= "" and seenInboxIds[id] then
        log("inbox skip dup " .. id)
        return
    end
    if id ~= "" then
        seenInboxIds[id] = true
    end
    local verb = jsonReadString(line, "verb") or jsonReadString(line, "cmd") or ""
    local steam = jsonReadString(line, "steam") or ""
    local sid = normalizeSteam(steam)
    if sid ~= "" then
        knownSteams[sid] = true
        steam = sid
    end
    verb = string.lower(verb)
    local ok, msg
    if verb == "aiherd" then
        if applyAiHerdInbox then
            ok, msg = applyAiHerdInbox(line)
        else
            ok, msg = false, "ai.lua not loaded"
        end
    elseif verb == "aiforage" then
        if applyAiForageInbox then
            ok, msg = applyAiForageInbox(line)
        else
            ok, msg = false, "plants.lua not loaded"
        end
    elseif verb == "aispawn" then
        local kind = string.lower(jsonReadString(line, "species") or jsonReadString(line, "kind") or "teno")
        if kind ~= "teno" and kind ~= "dibble" then kind = "teno" end
        if spawnAiHerb then
            ok, msg = spawnAiHerb(kind)
        else
            ok, msg = false, "ai.lua not loaded"
        end
    elseif verb == "eventon" then
        applyTokenEventState(true, jsonReadString(line, "text"))
        ok, msg = true, "eventon"
    elseif verb == "eventoff" then
        applyTokenEventState(false)
        ok, msg = true, "eventoff"
    elseif verb == "eventchat" then
        local text = jsonReadString(line, "text") or tokenEventMsg
        local n = broadcastEventChat(text, steam, jsonReadBool(line, "localOnly") == true)
        ok, msg = n > 0, "eventchat " .. tostring(n)
    elseif steam == "" then
        ok, msg = false, "missing steam"
    elseif verb == "store" or verb == "safelog" then
        ok, msg = armStore(steam)
    elseif verb == "redeem" then
        local slot = jsonReadString(line, "slot") or ""
        local dup = false
        for _, r in ipairs(pendingRedeems) do
            if r.steam == steam and r.kind == "stored" and (r.slot or "") == slot then dup = true end
        end
        if dup then
            ok, msg = false, "a redeem is already queued for that slot"
        else
            pendingRedeems[#pendingRedeems + 1] = {
                steam = steam, at = os.time() + 3, kind = "stored", slot = slot, id = id, verb = verb, tries = 0,
            }
            savePendingRedeems()
            ok, msg = true, "queued redeem in 3s"
        end
    elseif verb == "apply" or verb == "grow" then
        ok, msg = false, "grow is retired — buy a dino in Discord then redeem"
    elseif verb == "census" then
        ok, msg = true, "census " .. tostring(writeCensus())
    elseif verb == "tpinfo" then
        ok, msg = saveLiveReport(steam)
    elseif verb == "tpstart" then
        local target = jsonReadString(line, "target") or jsonReadString(line, "to") or ""
        ok, msg = startFriendTp(steam, target, id)
    elseif verb == "tpcancel" then
        ok, msg = cancelFriendTp(id ~= "" and id or steam, "teleport canceled")
    elseif verb == "storeinfo" then
        handleChat(steam, "!storeinfo")
        ok, msg = true, "storeinfo"
    elseif verb == "prime" or verb == "primeinfo" then
        handleChat(steam, "!prime")
        ok, msg = true, "prime"

     elseif verb == "cancelstore" then
         ok, msg = cancelStoreArm(steam, "store cancelled")
     elseif verb == "selfkill" then
         ok, msg = requestSelfKill(steam, "discord-inbox")
     elseif verb == "skin" then
         if applySkinInbox then
             ok, msg = applySkinInbox(line)
        else
            ok, msg = false, "skin.lua not loaded"
        end
    elseif verb == "skinunlock" then
        if applySkinUnlockInbox then
            ok, msg = applySkinUnlockInbox(line)
        else
            ok, msg = false, "skin.lua not loaded"
        end
    else
        ok, msg = false, "unknown verb " .. verb
    end
    emitResult(id, steam, verb, ok, msg)
    log(string.format("inbox %s steam=%s ok=%s %s", verb, steam, tostring(ok), tostring(msg)))
end

function consumeInbox(path, maxLines)
    maxLines = maxLines or 10
    local body = readAll(path)
    if body == nil or body == "" then return end
    
    os.remove(path .. ".processing")
    os.rename(path, path .. ".processing")
    local stash = readAll(path .. ".processing") or ""
    os.remove(path .. ".processing")
    
    -- Now Discord can write fresh inbox.ndjson
    
    local lines = {}
    for line in stash:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    
    local processed = 0
    local keep = {}
    for i = 1, #lines do
        if processed < maxLines then
            handleInboxLine(lines[i])
            processed = processed + 1
        else
            keep[#keep + 1] = lines[i]
        end
    end
    
    -- Write unprocessed to a queue file, not back to inbox
    if #keep > 0 then
        appendLine(path .. ".queue", table.concat(keep, "\n"))
    end
end

function pollInbox()
    -- Process queued lines first, then fresh inbox
    consumeInbox(INBOX_PATH .. ".queue", 5)
    consumeInbox(INBOX_PATH, 5)
end
function drainDeferred()
    local now = os.time()
    if #pendingRedeems > 0 then
        local keep = {}
        for _, r in ipairs(pendingRedeems) do
            if now >= r.at then
                local ok, msg
                -- An error must not escape: pendingRedeems would never be pruned and
                -- the redeem (incl. position restore) would re-run every second.
                local pok, a, b = pcall(function()
                    if r.kind == "token" then
                        return applyGrowth(r.steam, r.species, r.growth)
                    end
                    return redeemStored(r.steam, r.slot)
                end)
                if pok then
                    ok, msg = a, b
                else
                    ok, msg = false, "redeem error: " .. tostring(a)
                end
                if not ok and redeemStillWaiting(msg) and (r.tries or 0) < 45 then
                    r.tries = (r.tries or 0) + 1
                    r.at = now + 1
                    keep[#keep + 1] = r
                    if r.tries == 1 or r.tries % 15 == 0 then
                        log("redeem waiting for spawn " .. r.steam .. " try=" .. tostring(r.tries) .. " " .. tostring(msg))
                    end
                else
                    queueNotify(r.steam, msg)
                    emitResult(r.id, r.steam, r.verb or "redeem", ok, msg)
                    if ok then
                        recordJobCooldown(r.steam, "redeem")
                        unregisterPlayerJob(r.steam, "redeem", r.steam)
                    end
                    log((ok and "redeem ok " or "redeem fail ") .. r.steam .. " " .. tostring(msg))
                end
            else
                keep[#keep + 1] = r
            end
        end
        pendingRedeems = keep
        savePendingRedeems()
    end
end

ensureDir(SAVED_DIR)
ensureDir(STORED_DIR)
ensureDir(VAULT_DIR)
ensureDir(PRIME_DIR)
ensureDir(LIVE_DIR)
ensureDir(TP_DIR)
ensureDir(RECAP_DIR)
ensureDir(INBOX_DIR)
if readAll(CONFIG_PATH) == nil then
    writeAll(CONFIG_PATH, '{"pollSeconds":1}\n')
end
loadPendingRedeems()
pcall(loadSpeciesCaps)

registerChatHook()
registerAdminHooks()
registerLogoutHooks()

-- ============================================================
-- Bounded scheduler
-- All gameplay-affecting handlers run on the game thread.
-- ============================================================

local activeLoop = LoopInGameThreadWithDelay

if activeLoop == nil then
    log("ERROR: LoopInGameThreadWithDelay missing — wrong UE4SS version")
    return
end

local MAIN_SCHEDULE = {
    fast = 0,
    medium = 0,
    slow = 0,
    census = 0,
}

local function scheduleDue(name, interval, now)
    if now < (MAIN_SCHEDULE[name] or 0) then
        return false
    end

    MAIN_SCHEDULE[name] = now + interval
    return true
end

local function runSafe(label, fn)
    if type(fn) ~= "function" then
        return
    end

    local ok, err = pcall(fn)
    if not ok then
        log("[PrimevalRedeem] " .. label .. " failed: " .. tostring(err))
    end
end

activeLoop(1000, function()
    local now = os.time()

    -- --------------------------------------------------------
    -- Fast track: approximately once per second.
    -- These contain player commands, delayed store actions,
    -- redeems, teleports, and notifications.
    -- --------------------------------------------------------
    if scheduleDue("fast", 1, now) then
        -- IMPORTANT:
        -- Inbox handlers touch pawns and controllers, so they stay
        -- on the game thread. Do not move these into ExecuteAsync.
        runSafe("pollInbox", pollInbox)
        runSafe("pollCmdFlag", pollCmdFlag)

        runSafe("drainNotifies", drainNotifies)
        runSafe("drainDeferred", drainDeferred)

        runSafe("pollPendingSlays", pollPendingSlays)
        runSafe("pollPendingTeleports", pollPendingTeleports)
        runSafe("pollPendingFriendTps", pollPendingFriendTps)
        runSafe("pollPendingCommits", pollPendingCommits)
    end

    -- --------------------------------------------------------
    -- Medium track: approximately every two seconds.
    -- These may perform repeated stat, mutation, or growth work.
    -- --------------------------------------------------------
    if scheduleDue("medium", 2, now) then
        runSafe("pollPendingNativeBuyRedeems", pollPendingNativeBuyRedeems)
        runSafe("pollPendingBuyInjects", pollPendingBuyInjects)
        runSafe("pollPendingHungerFills", pollPendingHungerFills)
        runSafe("pollPendingMutationRestores", pollPendingMutationRestores)
        runSafe("pollPendingBuyGrows", pollPendingBuyGrows)
        runSafe("pollSkinRestore", pollSkinRestore)
        runSafe("pollPrimePopups", pollPrimePopups)
    end

    -- --------------------------------------------------------
    -- Slow track: approximately every five seconds.
    -- AI, plants, cap samples, and event joins are background work.
    -- --------------------------------------------------------
    if scheduleDue("slow", 5, now) then
        runSafe("pollSpeciesCapSamples", pollSpeciesCapSamples)
        runSafe("pollAiHerd", pollAiHerd)
        runSafe("pollAiForage", pollAiForage)
        runSafe("pollPlantProbe", pollPlantProbe)
        runSafe("pollTokenEventJoins", pollTokenEventJoins)
    end

    -- --------------------------------------------------------
    -- Overlay telemetry is intentionally slower. If the overlay
    -- is disabled, runSafe simply does nothing.
    -- --------------------------------------------------------
    if scheduleDue("overlay", 15, now) then
        runSafe("pollOverlayTelemetry", pollOverlayTelemetry)
    end

    -- --------------------------------------------------------
    -- Census is intentionally slow and adaptive.
    -- --------------------------------------------------------
    local censusWait = (lastCensusCount == 0) and 60 or 15
    if scheduleDue("census", censusWait, now) then
        runSafe("writeCensus", writeCensus)
    end
end)

log("boot ok; bounded game-thread scheduler active; inbox safe; census adaptive")