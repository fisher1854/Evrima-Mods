--[[ PrimevalRedeem prime elder read + in-game popups. ]]

PRIME_NAMES = {
    "Visit a Sanctuary",
    "Visit 2 Migration Zones",
    "Perfect Diet",
    "Visit 4 Patrol Zones",
    "Born from a player nest",
    "Raise a hatchling to 50%",
    "Never go infertile (keep a nutrient)",
    "Never get muscle spasms",
    "Per-life objective",
    "Breeding lifetime objective",
}

PRIME_PROGRESS_FIELDS = {
    [2] = {
        need = 2,
        fields = {
            "NumMigrationZonesVisited", "MigrationZonesVisited", "iMigrationZoneCount",
            "MigrationZoneCount", "VisitedMigrationZones",
        },
    },
    [4] = {
        need = 4,
        fields = {
            "NumPatrolZonesVisited", "PatrolZonesVisited", "iPatrolZoneCount",
            "PatrolZoneCount", "VisitedPatrolZones", "PatrolZones",
        },
    },
}

function boolField(obj, name)
    if obj == nil then return nil end
    local v
    pcall(function() v = obj[name] end)
    if v == true then return true end
    if v == false then return false end
    local n = numericValue(v)
    if n == 1 then return true end
    if n == 0 then return false end
    return nil
end

function readPrimeStruct(pawn)
    if pawn == nil then return nil end
    local pe
    pcall(function() pe = pawn.EligiblePrimeElderData end)
    if pe == nil then
        pcall(function() pe = pawn:GetEligiblePrimeElderData() end)
    end
    return pe
end

-- Poll path: property only. Calling GetEligiblePrimeElderData on a timer
-- was part of the always-on hitch. !prime still uses readPrimeStruct.
function readPrimeStructQuiet(pawn)
    if pawn == nil then return nil end
    local pe
    pcall(function() pe = pawn.EligiblePrimeElderData end)
    return pe
end

function collectPrimeFlags(pawn)
    local pe = readPrimeStructQuiet(pawn)
    local conds = {}
    local have = 0
    for i = 1, 10 do
        local ok = pe ~= nil and boolField(pe, "bPrimeCondition" .. tostring(i)) == true
        conds[i] = ok
        if ok then have = have + 1 end
    end
    return {
        have = have,
        conds = conds,
        species = speciesKey(classPathOf(pawn)),
        pe = pe,
    }
end

function collectPrime(pawn)
    local pe = readPrimeStruct(pawn)
    local conds = {}
    local have = 0
    for i = 1, 10 do
        local ok = pe ~= nil and boolField(pe, "bPrimeCondition" .. tostring(i)) == true
        conds[i] = ok
        if ok then have = have + 1 end
    end
    local eligible = pe ~= nil and boolField(pe, "bIsEligiblePrime") == true
    if not eligible then
        local alt = tryBool(pawn, { "IsPrimeElder", "GetPrimeElder", "bPrimeElder", "PrimeElder" })
        if alt == true then eligible = true end
    end
    return {
        growth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 0,
        eligible = eligible,
        have = have,
        conds = conds,
        species = speciesKey(classPathOf(pawn)),
        pe = pe,
    }
end

function readPrimeProgress(pe)
    local progress = {}
    if pe == nil then return progress end
    for slot, spec in pairs(PRIME_PROGRESS_FIELDS) do
        local n = tryNumber(pe, spec.fields)
        if n ~= nil then
            if n < 0 then n = 0 end
            if n > spec.need then n = spec.need end
            progress[slot] = n
        end
    end
    return progress
end

function savePrimeReport(steam, report, err)
    ensureDir(PRIME_DIR)
    local condJson = {}
    local conds = (report and report.conds) or {}
    for i = 1, 10 do
        condJson[#condJson + 1] = string.format(
            '{"slot":%d,"ok":%s,"name":"%s"}',
            i,
            conds[i] and "true" or "false",
            jsonEscape(PRIME_NAMES[i] or ("Objective " .. tostring(i)))
        )
    end
    local json = string.format(
        '{"steam":"%s","ok":%s,"error":"%s","species":"%s","growth":%.4f,"eligible":%s,"have":%d,"need":5,"capturedAt":%d,"conditions":[%s]}\n',
        jsonEscape(steam or ""),
        (err == nil) and "true" or "false",
        jsonEscape(err or ""),
        jsonEscape((report and report.species) or ""),
        (report and report.growth) or 0,
        (report and report.eligible) and "true" or "false",
        (report and report.have) or 0,
        os.time(),
        table.concat(condJson, ",")
    )
    writeAll(PRIME_DIR .. "/" .. tostring(steam) .. ".json", json)
end

function reportPrime(steam)
    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        savePrimeReport(steam, nil, "not spawned")
        return false, "not spawned — join the Isle as your dino first"
    end
    local path = string.lower(tostring(classPathOf(pawn) or ""))
    if path:find("spectator") or path:find("cameraman") or path:find("freecam") then
        savePrimeReport(steam, nil, "spectator")
        return false, "not spawned — leave spectator and spawn your dino first"
    end
    local report = collectPrime(pawn)
    savePrimeReport(steam, report, nil)
    local remain = math.max(0, 5 - (report.have or 0))
    local lockBit = ""
    if (report.growth or 0) >= 0.75 then
        if report.eligible then
            lockBit = " — locked in at 75%"
        else
            lockBit = " — past 75% without eligibility (frail path)"
        end
    elseif remain > 0 then
        lockBit = string.format(" — %d more flag(s) before 75%%", remain)
    else
        lockBit = " — threshold met, stay under 75% until it locks"
    end
    local msg = string.format(
        "prime %s %.0f%% — %d/5 engine flags, eligible=%s%s",
        report.species ~= "" and report.species or "dino",
        (report.growth or 0) * 100,
        math.min(5, report.have or 0),
        report.eligible and "yes" or "no",
        lockBit
    )
    return true, msg
end

local recentChat = {}
local ADMIN_VERBS = {
    adminpanel = true, slay = true, kill = true, kick = true, ban = true, banid = true,
    unban = true, heal = true, grow = true, ["goto"] = true, bring = true, teleport = true,
    tp = true, revive = true, announce = true, mute = true, unmute = true, time = true,
    weather = true, god = true, fly = true, ghost = true, spectate = true, setgroup = true,
    addadmin = true, removeadmin = true, give = true, spawn = true, wipe = true,
    wipecorpses = true, save = true, pause = true, freeze = true, thaw = true,
    setgrowth = true, growth = true, diet = true, hunger = true, thirst = true,
    stamina = true, damage = true, sethealth = true, posses = true, possess = true,
}

function steamForPlayerName(name)
    local want = string.lower(tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if want == "" then return "" end
    if normalizeSteam(want) ~= "" then return normalizeSteam(want) end
    local found = ""
    forEachPlayerCtrl(function(ctrl, steam)
        if found ~= "" or ctrl == nil then return end
        local n = ""
        pcall(function() n = tostring(ctrl:GetPlayerName()) end)
        if n == "" then
            pcall(function()
                local ps = ctrl.PlayerState
                if ps ~= nil then n = tostring(ps:GetPlayerName()) end
            end)
        end
        n = string.lower(tostring(n or ""))
        if n ~= "" and (n == want or n:find(want, 1, true)) then
            found = steam
        end
    end)
    return found
end

function recordAdminCommand(actorSteam, command, target, extra, source)
    command = tostring(command or "")
    if command == "" then return end
    extra = tostring(extra or "")
    if #extra > 180 then extra = extra:sub(1, 180) end
    target = tostring(target or "")
    if target ~= "" and normalizeSteam(target) == "" then
        local mapped = steamForPlayerName(target)
        if mapped ~= "" then
            extra = (extra ~= "" and (extra .. " name:" .. target) or ("name:" .. target))
            target = mapped
        end
    else
        target = normalizeSteam(target)
    end
    local path = ADMIN_AUDIT_LOG or (SAVED_DIR .. "/admin_audit.ndjson")
    local line = string.format(
        '{"at":%d,"source":"%s","actor":"%s","command":"%s","target":"%s","extra":"%s"}',
        os.time(),
        jsonEscape(source or "chat"),
        jsonEscape(tostring(actorSteam or "")),
        jsonEscape(command),
        jsonEscape(target),
        jsonEscape(extra)
    )
    appendLine(path, line)
    if PrimevalInbox and PrimevalInbox.rotateIfHuge then
        PrimevalInbox.rotateIfHuge(path)
    end
    log("admin cmd " .. command .. " src=" .. tostring(source or "chat"))
end

function makeAdminHook(name)
    return function(selfParam, a, b, c)
        if redeemAuditActive and redeemAuditActive() then
            local n = string.lower(tostring(name or ""))
            if n:find("hunger", 1, true) or n:find("nutrient", 1, true) then
                return
            end
            if n:find("grow", 1, true) then
                local info = REDEEM_AUDIT
                if info ~= nil and info.logged ~= true then
                    info.logged = true
                    recordAdminCommand(
                        "PrimevalRedeem",
                        "RedeemGrow",
                        info.steam,
                        string.format(
                            "species=%s slot=%s pct=%s",
                            tostring(info.species or ""),
                            tostring(info.slot or ""),
                            tostring(info.percent or 70)
                        ),
                        "redeem"
                    )
                end
                if info ~= nil then
                    queueSpeciesCapSample(info.steam, 2)
                end
                return
            end
        end
        local steam = steamFromHookSelf(selfParam)
        local extra = table.concat({
            ftextToString(a),
            ftextToString(b),
            ftextToString(c),
        }, " ")
        extra = extra:gsub("^%s+", ""):gsub("%s+$", "")
        local target = normalizeSteam(extra) ~= "" and normalizeSteam(extra) or extra:match("(%S+)") or ""
        recordAdminCommand(steam, name, target, extra, "hook")
        if string.lower(tostring(name or "")):find("grow", 1, true) then
            queueSpeciesCapSample(target ~= "" and target or steam, 2)
        end
    end
end

function registerAdminHooks()
    local classes = {
        "/Script/TheIsle.TIPlayerController",
        "/Script/TheIsle.TICheatManager",
        "/Script/Engine.CheatManager",
        "/Script/Engine.PlayerController",
        "/Script/TheIsle.TIGameMode",
        "/Script/TheIsle.TIGameState",
    }
    local names = {
        "ServerAdminCommand", "AdminCommand", "ExecuteAdminCommand", "ProcessAdminCommand",
        "ServerSlay", "SlayPlayer", "AdminSlay", "ServerKickPlayer", "KickPlayer",
        "AdminKick", "ServerBanPlayer", "BanPlayer", "AdminBan", "ServerHeal",
        "HealPlayer", "AdminHeal", "ServerGrow", "GrowPlayer", "AdminGrow",
        "ServerGoto", "GotoPlayer", "AdminGoto", "ServerBring", "BringPlayer",
        "AdminBring", "ServerTeleport", "TeleportPlayer", "AdminTeleport",
        "ServerRevive", "RevivePlayer", "AdminRevive", "ToggleGodMode",
    }
    local hooked = 0
    for _, cls in ipairs(classes) do
        for _, name in ipairs(names) do
            local path = cls .. ":" .. name
            local ok = pcall(function()
                RegisterHook(path, makeAdminHook(name))
            end)
            if ok then
                hooked = hooked + 1
            end
        end
    end
    log("admin hooks registered n=" .. tostring(hooked))
end

function ftextToString(p)
    if p == nil then return "" end
    local obj = p
    pcall(function() obj = p:get() end)
    if obj == nil then obj = p end
    local s = safeString(obj)
    if s ~= "" and not s:find("^FText") and not s:find("^UObject") and not s:find("^userdata") then
        return s
    end
    local t
    pcall(function() t = obj:ToString() end)
    if t ~= nil and tostring(t) ~= "" then return tostring(t) end
    pcall(function() t = p:ToString() end)
    if t ~= nil and tostring(t) ~= "" then return tostring(t) end
    return ""
end

function unwrapCtrl(p)
    if p == nil then return nil end
    local obj
    pcall(function() obj = p:get() end)
    return obj or nil
end

function notifyCtrl(ctrl, message)
    if ctrl == nil or message == nil or message == "" then return end
    pcall(function()
        ctrl:ClientShowNotification(makeText(message))
    end)
end

-- Chat inject. NEVER call UpdateChat from Lua — it access-violates the
-- dedicated server (FText Client RPC). GetChatMessage is invoked per
-- receiving controller; we call it only on the target so Spatial does
-- not leak to nearby players.
CHAT_SPATIAL = 0
CHAT_GLOBAL = 1
injectingChat = false
tokenEventOn = false
tokenEventMsg = (
    "Opening event: new Discord members who link Steam get 15 tokens once. "
    .. "Linked players earn 5 tokens every 30 minutes in-game. Join https://discord.gg/MNnhAQyhkr"
)
tokenEventGreeted = {}
tokenEventPendingJoin = {}
tokenEventSeeded = false
lastTokenEventFlagAt = 0

function isEventChatText(text)
    text = tostring(text or "")
    if text == "" then return false end
    return text:find("Welcome to Primeval", 1, true) ~= nil
        or text:find("Token event:", 1, true) ~= nil
        or text:find("Opening event:", 1, true) ~= nil
        or text:find("Fallen Earth Elder", 1, true) ~= nil
        or text:find("Primeval Island Elder", 1, true) ~= nil
end

function elderText(text)
    text = tostring(text or tokenEventMsg or "")
    if text == "" then return "" end
    if text:find("Fallen Earth Elder", 1, true) or text:find("Primeval Island Elder", 1, true) then
        return text
    end
    return "Fallen Earth Elder — " .. text
end

function postChatToCtrl(ctrl, text, mode)
    if ctrl == nil or text == nil or text == "" then return false end
    local ft = makeText(text)
    injectingChat = true
    local ok = pcall(function()
        ctrl:GetChatMessage(ft, ctrl, mode, ft)
    end)
    injectingChat = false
    return ok
end

-- Never inject event text into Local/Global. GetChatMessage always shows a
-- real player as the sender. UpdateChat (custom name) AVs from Lua.
-- In-game reminder is RCON announce only: one server banner every 30 minutes.
function postEventChatToCtrl(ctrl, text, _localOnly)
    log("eventchat skip — no player-spoofed chat, no popup")
    return 0
end

function broadcastEventChat(text, steam, localOnly)
    log("eventchat skipped — RCON announce only")
    return 0
end

function applyTokenEventState(on, msg)
    if msg ~= nil and tostring(msg) ~= "" then
        tokenEventMsg = tostring(msg)
    end
    on = on == true
    if on == tokenEventOn then return end
    tokenEventOn = on
    tokenEventGreeted = {}
    tokenEventPendingJoin = {}
    tokenEventSeeded = false
    log("token event " .. (on and "on" or "off"))
end

function loadTokenEventFlag()
    local path = TOKEN_EVENT_PATH
    if path == nil or path == "" then return end
    local body = readAll(path)
    if body == nil or body == "" then return end
    local msg = jsonReadString(body, "message")
    local enabled = jsonReadBool(body, "enabled")
    if enabled == nil then
        log("token event flag missing enabled")
        return
    end
    applyTokenEventState(enabled, msg)
end

function playerHasLiveDino(ctrl)
    if ctrl == nil then return false end
    local pawn
    pcall(function() pawn = livePawnFromCtrl(ctrl) end)
    return isLiveDinoPawn(pawn) == true
end

function pollTokenEventJoins()
    local now = os.time()
    if (now - (lastTokenEventFlagAt or 0)) >= 5 then
        lastTokenEventFlagAt = now
        pcall(loadTokenEventFlag)
    end
    if not tokenEventOn then
        tokenEventGreeted = {}
        tokenEventPendingJoin = {}
        tokenEventSeeded = false
        return
    end
    local present = {}
    forEachPlayerCtrl(function(ctrl, steam)
        present[steam] = ctrl
    end)
    if not tokenEventSeeded then
        for steam, ctrl in pairs(present) do
            if playerHasLiveDino(ctrl) then
                tokenEventGreeted[steam] = true
            end
        end
        tokenEventSeeded = true
        return
    end
    for steam, ctrl in pairs(present) do
        if tokenEventGreeted[steam] then
            tokenEventPendingJoin[steam] = nil
        elseif not playerHasLiveDino(ctrl) then
            tokenEventPendingJoin[steam] = nil
        else
            tokenEventGreeted[steam] = true
            tokenEventPendingJoin[steam] = nil
        end
    end
    local gone = {}
    for steam, _ in pairs(tokenEventGreeted) do
        if present[steam] == nil then gone[#gone + 1] = steam end
    end
    for steam, _ in pairs(tokenEventPendingJoin) do
        if present[steam] == nil then gone[#gone + 1] = steam end
    end
    for _, steam in ipairs(gone) do
        tokenEventGreeted[steam] = nil
        tokenEventPendingJoin[steam] = nil
    end
end

function handleChat(steam, message, ctrl)
    if steam == nil or steam == "" then return end
    if message == nil then return end
    local msg = tostring(message):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = string.lower(msg)
    local key = steam .. "|" .. cmd
    local now = os.time()
    if recentChat[key] and (now - recentChat[key]) < 3 then
        return
    end
    local verb, rest = msg:match("^/(%S+)%s*(.*)$")
    if verb and ADMIN_VERBS[string.lower(verb)] then
        recentChat[key] = now
        recordAdminCommand(steam, string.lower(verb), (rest or ""):match("(%S+)") or "", rest or "", "chat")
    end
    local function tell(text)
        notifyCtrl(ctrl, text)
        queueNotify(steam, text)
    end
    if cmd == "!store" or cmd == "!safelog" or cmd:find("^!store%s") or cmd:find("^!safelog%s") then
        recentChat[key] = now
        local ok, result = armStore(steam)
        tell(result)
        log((ok and "store armed " or "store arm fail ") .. steam .. " " .. tostring(result))
    elseif cmd == "!cancelstore" or cmd == "!cancelsafelog" or cmd == "!cancel" then
        recentChat[key] = now
        local ok, result = cancelStoreArm(steam, "store cancelled")
        tell(result)
        log(tostring(ok) .. " " .. tostring(result))
    elseif cmd == "!redeem" or cmd:find("^!redeem") then
        recentChat[key] = now
        pendingRedeems[#pendingRedeems + 1] = { steam = steam, at = os.time() + 3, kind = "stored" }
        tell("redeem in 3s — stay spawned as the vault species juvenile")
        log("queued redeem " .. steam)
    elseif cmd == "!storeinfo" or cmd:find("^!storeinfo") then
        recentChat[key] = now
        local stored = loadStored(steam)
        if stored == nil then
            tell("no stored dino")
            log("storeinfo empty " .. steam)
        else
            local extra = ""
            if stored.mutations ~= nil and stored.mutations ~= "" then extra = extra .. " mut" end
            if stored.skin ~= nil and stored.skin ~= "" then extra = extra .. " skin:" .. stored.skin end
            if stored.gender ~= nil and stored.gender ~= "" then
                extra = extra .. " " .. stored.gender
            elseif stored.female == true then extra = extra .. " Female"
            elseif stored.female == false then extra = extra .. " Male"
            end
            if stored.primeFlags ~= nil and stored.primeFlags ~= "" then
                extra = extra .. " prime " .. tostring(stored.primeHave or 0) .. "/10"
            end
            if stored.x ~= nil then extra = extra .. " loc" end
            local line = string.format("vault %s at %.0f%%%s", stored.species or "?", (stored.growth or 0) * 100, extra)
            tell(line)
            log("storeinfo " .. steam .. " " .. tostring(stored.species))
        end
    elseif cmd == "!prime" or cmd == "!primeinfo" or cmd:find("^!prime") then
        recentChat[key] = now
        local ok, result = reportPrime(steam)
        tell(result)
        log((ok and "prime ok " or "prime fail ") .. steam .. " " .. tostring(result))
    elseif cmd == "!capdump" then
        recentChat[key] = now
        local pawn = livePawnFromCtrl(ctrl) or livePawnFromCtrl(controllerForSteam(steam))
        local row, err = recordSpeciesCap(pawn, "capdump")
        if row ~= nil then
            tell(string.format(
                "cap saved %s %s%% Hmax=%.2f Fmax=%s",
                row.species, tostring(row.pct), tonumber(row.maxHunger) or 0,
                row.maxFood ~= nil and string.format("%.2f", row.maxFood) or "?"
            ))
        else
            tell("capdump failed: " .. tostring(err))
        end
    elseif cmd == "!skin" or cmd:find("^!skin%s") then
        recentChat[key] = now
        if handleSkinChat then
            handleSkinChat(steam, msg, ctrl)
        else
            tell("skins not loaded yet — wait for the next Isle restart")
        end
    elseif cmd == "!caps" then
        recentChat[key] = now
        local missing = missingSpeciesCaps(70)
        local have = 0
        for _, name in ipairs(PRIMEVAL_PLAYABLE or {}) do
            if lookupSpeciesCap(name, 70) ~= nil then have = have + 1 end
        end
        if #missing == 0 then
            tell(string.format("70%% caps complete %s/%s", tostring(have), tostring(#(PRIMEVAL_PLAYABLE or {}))))
        else
            tell(string.format(
                "70%% caps %s/%s missing: %s",
                tostring(have),
                tostring(#(PRIMEVAL_PLAYABLE or {})),
                table.concat(missing, ", ")
            ))
        end
    end
end

function onGetChatMessage(selfParam, newTextParam, senderParam, _chatMode, _noFilter)
    if injectingChat then return end
    local sender = unwrapCtrl(senderParam)
    local selfCtrl = unwrapCtrl(selfParam)
    if sender == nil then
        sender = selfCtrl
    end
    local steam = getControllerSteamId(sender)
    if steam == "" then
        steam = getControllerSteamId(selfCtrl)
    end
    if steam == "" then
        steam = normalizeSteam(safeString(senderParam))
    end
    local text = ftextToString(newTextParam)
    if text == "" then
        text = ftextToString(_noFilter)
    end
    if isEventChatText(text) then return end
    if text ~= "" or steam ~= "" then
        log(string.format("chat fire steam=%s text=%s", tostring(steam), tostring(text)))
    end
    if steam ~= "" then
        knownSteams[steam] = true
    end
    if steam ~= "" and text ~= "" then
        handleChat(steam, text, sender or selfCtrl)
    elseif text ~= "" then
        log("chat fire missing steam id")
        notifyCtrl(sender or selfCtrl, "redeem mod heard chat but could not read steam id")
    end
end

function registerChatHook()
    local ok, err = pcall(function()
        RegisterHook("/Script/TheIsle.TIPlayerController:GetChatMessage", onGetChatMessage)
    end)
    if ok then
        log("chat hook registered (use GLOBAL chat if you are the only player)")
    else
        log("chat hook FAILED: " .. tostring(err))
    end
end

function steamFromHookSelf(selfParam)
    local ctrl = unwrapCtrl(selfParam)
    if ctrl == nil then ctrl = selfParam end
    local steam = getControllerSteamId(ctrl)
    if steam == "" then
        steam = normalizeSteam(safeString(selfParam))
    end
    return steam, ctrl
end

function commitPendingSnap(steam, ctrl)
    local snap = pendingSnaps[steam]
    pendingSnaps[steam] = nil
    armedStores[steam] = nil
    if snap == nil or snap.classPath == nil or snap.classPath == "" then
        local msg = "recap: vault NOT saved — nothing captured. Store and safelog again."
        writeRecap(steam, "failed", snap, "safelog finished but nothing was captured")
        notifyCtrl(ctrl, msg)
        queueNotify(steam, msg)
        log("store commit empty " .. tostring(steam))
        return false
    end
    if not saveStored(steam, snap) then
        local msg = "recap: vault NOT saved — write failed. Store and safelog again."
        writeRecap(steam, "failed", snap, "safelog finished but vault write failed")
        notifyCtrl(ctrl, msg)
        queueNotify(steam, msg)
        log("store commit write fail " .. steam)
        return false
    end
    log(string.format(
        "vault keys steam=%s species=%s growth=%.3f hunger=%s mut=%s skin=%s loc=%.0f,%.0f,%.0f",
        steam,
        tostring(snap.species),
        tonumber(snap.growth) or 0,
        tostring(snap.hunger),
        tostring(snap.mutations),
        tostring(snap.skinData ~= nil and snap.skinData ~= "" and "yes" or "no"),
        snap.x or 0, snap.y or 0, snap.z or 0
    ))
    local locBit = ""
    if snap.x ~= nil then locBit = " — redeem returns you here" end
    local genderBit = snapGender(snap)
    if genderBit ~= "" then genderBit = " " .. genderBit end
    writeRecap(steam, "saved", snap, "vault saved from safelog")
    local msg = string.format(
        "recap: vault SAVED %s%s %.0f%% Prime %s/10%s — spawn matching juvie, Redeem",
        snap.species or "dino",
        genderBit,
        (tonumber(snap.growth) or 0) * 100,
        tostring(snap.primeHave or 0),
        locBit
    )
    notifyCtrl(ctrl, msg)
    queueNotify(steam, msg)
    log("store via game safelog " .. steam .. " " .. msg)
    return true
end

function isLiveDinoPawn(pawn)
    if pawn == nil then return false end
    local path = string.lower(tostring(classPathOf(pawn) or ""))
    if path == "" then return false end
    if path:find("spectator") or path:find("cameraman") or path:find("freecam") then
        return false
    end
    local sp = speciesKey(path)
    if sp == "" then return false end
    if path:find("bp_") then return true end
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" })
    return growth ~= nil
end

function eachFoundObject(list, fn)
    if list == nil or fn == nil then return end
    if type(list) == "table" then
        for _, obj in pairs(list) do
            if obj ~= nil then fn(obj) end
        end
        return
    end
    local n
    pcall(function() n = list:GetArrayNum() end)
    if n == nil then pcall(function() n = list:Num() end) end
    n = tonumber(n)
    if n == nil then pcall(function() n = #list end) end
    n = tonumber(n) or 0
    if n <= 0 then return end
    for i = 0, n - 1 do
        local elem
        pcall(function() elem = list:Get(i) end)
        if elem == nil then pcall(function() elem = list[i] end) end
        if elem == nil then pcall(function() elem = list[i + 1] end) end
        if elem ~= nil then fn(elem) end
    end
end

function ctrlFromPlayerState(ps)
    if ps == nil then return nil end
    local ctrl
    pcall(function() ctrl = ps:GetOwningController() end)
    if ctrl == nil then pcall(function() ctrl = ps:GetOwner() end) end
    if ctrl == nil then pcall(function() ctrl = ps.Owner end) end
    if ctrl == nil then pcall(function() ctrl = ps:GetPlayerController() end) end
    return ctrl
end

function forEachPlayerCtrl(fn)
    local seen = {}
    local function consider(ctrl)
        if ctrl == nil then return end
        local steam = getControllerSteamId(ctrl)
        if steam == "" or seen[steam] ~= nil then return end
        seen[steam] = true
        fn(ctrl, steam)
    end
    for steam, _ in pairs(knownSteams) do
        consider(controllerForSteam(steam))
    end
    -- PlayerArray only. FindAllOf still walks GUObjectArray even when the
    -- class is narrow, which hitches a dedicated Isle server.
    local gsNames = {
        "TISurvivalGameState",
        "BP_SurvivalGameState_C",
        "TIGameStateBase",
        "GameStateBase",
    }
    local usedArray = false
    for _, name in ipairs(gsNames) do
        local gs
        pcall(function() gs = FindFirstOf(name) end)
        if gs ~= nil then
            local arr
            pcall(function() arr = gs.PlayerArray end)
            if arr ~= nil then
                usedArray = true
                eachFoundObject(arr, function(ps)
                    consider(ctrlFromPlayerState(ps))
                end)
            end
            break
        end
    end
    if not usedArray then
        local list
        pcall(function() list = FindAllOf("TIPlayerController") end)
        eachFoundObject(list, consider)
    end
end

function primePopupText(slot, have, progress, progressNeed)
    local name = PRIME_NAMES[slot] or ("Objective " .. tostring(slot))
    if progress ~= nil and progressNeed ~= nil then
        return string.format("met prime condition %s %d/%d", name, progress, progressNeed)
    end
    return string.format("met prime condition %s %d/5", name, math.min(5, have or 0))
end

function pollPrimePopups()
    local now = os.time()
    if now - (lastPrimeWorkAt or 0) < 15 then
        return
    end
    lastPrimeWorkAt = now
    local alive = {}
    forEachPlayerCtrl(function(ctrl, steam)
        alive[steam] = true
        local pawn = livePawnFromCtrl(ctrl)
        if not isLiveDinoPawn(pawn) then
            lastPrimeState[steam] = nil
            return
        end
        local report = collectPrimeFlags(pawn)
        local progress = readPrimeProgress(report.pe)
        local bits = {}
        for i = 1, 10 do
            bits[i] = report.conds[i] == true
            if bits[i] then
                local spec = PRIME_PROGRESS_FIELDS[i]
                if spec ~= nil and progress[i] == nil then
                    progress[i] = spec.need
                end
            end
        end
        local addr
        pcall(function() addr = pawn:GetAddress() end)
        local pawnKey = tostring(addr or "") .. "|" .. tostring(report.species or "")
        local prev = lastPrimeState[steam]
        local quiet = tonumber(primeQuietUntil[steam] or 0) or 0
        if quiet > 0 and now < quiet then
            lastPrimeState[steam] = { pawnKey = pawnKey, bits = bits, progress = progress, have = report.have }
            return
        end
        if quiet > 0 and now >= quiet then
            primeQuietUntil[steam] = nil
        end
        if prev == nil or prev.pawnKey ~= pawnKey then
            lastPrimeState[steam] = { pawnKey = pawnKey, bits = bits, progress = progress, have = report.have }
            log(string.format("prime watch %s %s flags=%d/10", steam, tostring(report.species or ""), report.have or 0))
            return
        end
        local newly = {}
        for i = 1, 10 do
            local spec = PRIME_PROGRESS_FIELDS[i]
            local oldP = prev.progress and prev.progress[i]
            local newP = progress[i]
            if spec ~= nil and newP ~= nil and (oldP == nil or newP > oldP) then
                newly[#newly + 1] = { slot = i, progress = newP, need = spec.need }
            elseif bits[i] == true and prev.bits[i] ~= true then
                newly[#newly + 1] = { slot = i, progress = spec and spec.need or nil, need = spec and spec.need or nil }
            end
        end
        lastPrimeState[steam] = { pawnKey = pawnKey, bits = bits, progress = progress, have = report.have }
        -- First load can dump several flags at once. A real in-life unlock is 1-2.
        if #newly >= 3 and (prev.have or 0) <= 1 then
            return
        end
        for _, row in ipairs(newly) do
            local msg = primePopupText(row.slot, report.have, row.progress, row.need)
            notifyCtrl(ctrl, msg)
            queueNotify(steam, msg)
            log("prime met " .. steam .. " " .. msg)
        end
    end)
    local gone = {}
    for steam, _ in pairs(lastPrimeState) do
        if alive[steam] ~= true then
            gone[#gone + 1] = steam
        end
    end
    for _, steam in ipairs(gone) do
        lastPrimeState[steam] = nil
    end
    if now - lastPrimePollLog >= 30 then
        lastPrimePollLog = now
        local n = 0
        for _ in pairs(alive) do n = n + 1 end
        log("prime poll players=" .. tostring(n))
    end
end

