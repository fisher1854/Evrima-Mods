--[[ PrimevalRedeem friend teleport + live report. ]]

TP_MIN_TARGET_HP = 100

function targetHealthPoints(pawn)
    local hp = tryNumber(pawn, { "GetHealth", "Health", "GetCurrentHealth", "CurrentHealth" })
    local maxHp = tryNumber(pawn, { "GetMaxHealth", "MaxHealth" })
    if hp == nil then
        return nil, maxHp
    end
    -- Some reads come back 0–1. Scale those to 0–100 so "100 HP" still means full.
    if hp <= 1.5 and (maxHp == nil or maxHp <= 1.5) then
        return hp * 100, (maxHp or 1) * 100
    end
    return hp, maxHp
end

function friendTpTargetHpReason(pawn)
    local hp = targetHealthPoints(pawn)
    if hp == nil then
        return "could not read target health — teleport canceled"
    end
    if hp < (TP_MIN_TARGET_HP or 100) then
        return "target is below 100 HP — teleport canceled"
    end
    return nil
end

function writeTpStatus(id, status, msg, extra)
    if id == nil or id == "" then return end
    ensureDir(TP_DIR)
    extra = extra or {}
    local json = string.format(
        '{"id":"%s","status":"%s","msg":"%s","from":"%s","to":"%s","capturedAt":%d}\n',
        jsonEscape(id),
        jsonEscape(status or ""),
        jsonEscape(msg or ""),
        jsonEscape(extra.from or ""),
        jsonEscape(extra.to or ""),
        os.time()
    )
    writeAll(TP_DIR .. "/" .. tostring(id) .. ".json", json)
end

function saveLiveReport(steam)
    ensureDir(LIVE_DIR)
    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    local spawned = isLiveDinoPawn(pawn)
    local snap = spawned and snapshotPawn(pawn) or nil
    local species = (snap and snap.species) or ""
    local json = string.format(
        '{"steam":"%s","ok":%s,"spawned":%s,"species":"%s","diet":"%s","health":%s,"maxHealth":%s,"x":%s,"y":%s,"z":%s,"capturedAt":%d}\n',
        jsonEscape(steam or ""),
        spawned and "true" or "false",
        spawned and "true" or "false",
        jsonEscape(prettySpecies(species)),
        jsonEscape(dietOf(species)),
        numOrNull(snap and snap.health),
        numOrNull(snap and snap.maxHealth),
        snap and snap.x and string.format("%.3f", snap.x) or "null",
        snap and snap.y and string.format("%.3f", snap.y) or "null",
        snap and snap.z and string.format("%.3f", snap.z) or "null",
        os.time()
    )
    writeAll(LIVE_DIR .. "/" .. tostring(steam) .. ".json", json)
    if not spawned then
        return false, "not spawned"
    end
    return true, species
end

CENSUS_PATH = SAVED_DIR .. "/census.json"
lastCensusAt = 0
lastCensusCount = 0

function writeCensus()
    local rows = {}
    forEachPlayerCtrl(function(ctrl, steam)
        local pawn = livePawnFromCtrl(ctrl)
        local spawned = isLiveDinoPawn(pawn)
        local sp = ""
        if spawned then
            sp = prettySpecies(speciesKey(classPathOf(pawn)))
        end
        rows[#rows + 1] = string.format(
            '{"steam":"%s","spawned":%s,"species":"%s"}',
            jsonEscape(steam),
            spawned and "true" or "false",
            jsonEscape(sp)
        )
    end)
    local body = string.format(
        '{"capturedAt":%d,"online":%d,"players":[%s]}\n',
        os.time(),
        #rows,
        table.concat(rows, ",")
    )
    writeAll(CENSUS_PATH, body)
    lastCensusCount = #rows
    return #rows
end

function startFriendTp(fromSteam, toSteam, id)
    if fromSteam == nil or toSteam == nil or fromSteam == "" or toSteam == "" then
        return false, "missing steam"
    end
    if fromSteam == toSteam then
        return false, "cannot teleport to yourself"
    end
    id = tostring(id or ("tp" .. tostring(os.time())))
    for _, row in pairs(pendingFriendTps) do
        if row.from == fromSteam or row.to == fromSteam or row.from == toSteam or row.to == toSteam then
            return false, "a teleport is already in progress"
        end
    end
    local fromCtrl = controllerForSteam(fromSteam)
    local toCtrl = controllerForSteam(toSteam)
    local fromPawn = livePawnFromCtrl(fromCtrl)
    local toPawn = livePawnFromCtrl(toCtrl)
    if not isLiveDinoPawn(fromPawn) then
        writeTpStatus(id, "fail", "requester not spawned", { from = fromSteam, to = toSteam })
        return false, "requester not spawned"
    end
    if not isLiveDinoPawn(toPawn) then
        writeTpStatus(id, "fail", "target not spawned", { from = fromSteam, to = toSteam })
        return false, "target not spawned"
    end
    local fromSnap = snapshotPawn(fromPawn)
    local toSnap = snapshotPawn(toPawn)
    local okDiet, why = tpDietOk(fromSnap.species, toSnap.species)
    if not okDiet then
        writeTpStatus(id, "fail", why, { from = fromSteam, to = toSteam })
        return false, why
    end
    if fromSnap.x == nil or toSnap.x == nil then
        writeTpStatus(id, "fail", "could not read location", { from = fromSteam, to = toSteam })
        return false, "could not read location"
    end
    local hpWhy = friendTpTargetHpReason(toPawn)
    if hpWhy then
        writeTpStatus(id, "fail", hpWhy, { from = fromSteam, to = toSteam })
        return false, hpWhy
    end
    pendingFriendTps[id] = {
        id = id,
        from = fromSteam,
        to = toSteam,
        fromStart = { x = fromSnap.x, y = fromSnap.y, z = fromSnap.z },
        toStart = { x = toSnap.x, y = toSnap.y, z = toSnap.z },
        started = os.time(),
        ends = os.time() + TP_HOLD_SECONDS,
        lastTick = 0,
    }
    writeTpStatus(id, "hold", "stand still 60s", { from = fromSteam, to = toSteam })
    queueNotify(fromSteam, "Teleport started. Both players must stand still for 60s.")
    queueNotify(toSteam, "Teleport started. Both players must stand still for 60s.")
    return true, "hold"
end

function cancelFriendTp(key, reason)
    local job = pendingFriendTps[key]
    local id = key
    if job == nil then
        for rowId, row in pairs(pendingFriendTps) do
            if row.from == key or row.to == key or row.id == key then
                job = row
                id = rowId
                break
            end
        end
    end
    if job == nil then return false, "no teleport waiting" end
    pendingFriendTps[id] = nil
    writeTpStatus(job.id, "cancel", reason or "canceled", { from = job.from, to = job.to })
    queueNotify(job.from, reason or "teleport canceled")
    queueNotify(job.to, reason or "teleport canceled")
    emitResult(job.id, job.from, "tpstart", false, reason or "canceled")
    return true, reason or "canceled"
end

function pollPendingFriendTps()
    local now = os.time()
    local moveLim = TP_MOVE_DIST * TP_MOVE_DIST
    local done = {}
    for id, job in pairs(pendingFriendTps) do
        local fromCtrl = controllerForSteam(job.from)
        local toCtrl = controllerForSteam(job.to)
        local fromPawn = livePawnFromCtrl(fromCtrl)
        local toPawn = livePawnFromCtrl(toCtrl)
        if not isLiveDinoPawn(fromPawn) or not isLiveDinoPawn(toPawn) then
            done[#done + 1] = { id = id, reason = "a player despawned", moved = false }
        else
            local hpWhy = friendTpTargetHpReason(toPawn)
            local fromLoc = readLocation(fromPawn)
            local toLoc = readLocation(toPawn)
            if hpWhy then
                done[#done + 1] = { id = id, reason = hpWhy, moved = false }
            elseif distSq(fromLoc, job.fromStart) > moveLim or distSq(toLoc, job.toStart) > moveLim then
                done[#done + 1] = { id = id, reason = "a player moved — teleport canceled", moved = true }
            elseif now >= job.ends then
                local lateWhy = friendTpTargetHpReason(toPawn)
                if lateWhy then
                    done[#done + 1] = { id = id, reason = lateWhy, moved = false }
                else
                    local dest = snapshotPawn(toPawn)
                    local ok = teleportPawn(fromPawn, dest, fromCtrl)
                    if ok then
                        writeTpStatus(job.id, "ok", "Teleport executed.", { from = job.from, to = job.to })
                        queueNotify(job.from, "Teleport executed.")
                        queueNotify(job.to, "Teleport executed.")
                        emitResult(job.id, job.from, "tpstart", true, "Teleport executed.")
                        pendingFriendTps[id] = nil
                    else
                        done[#done + 1] = { id = id, reason = "teleport failed", moved = false }
                    end
                end
            elseif now - (job.lastTick or 0) >= 15 then
                job.lastTick = now
                local left = math.max(0, job.ends - now)
                queueNotify(job.from, "Stand still — teleport in " .. tostring(left) .. "s")
                queueNotify(job.to, "Stand still — teleport in " .. tostring(left) .. "s")
            end
        end
    end
    for _, row in ipairs(done) do
        local job = pendingFriendTps[row.id]
        if job ~= nil then
            pendingFriendTps[row.id] = nil
            local status = row.moved and "moved" or "fail"
            writeTpStatus(job.id, status, row.reason, { from = job.from, to = job.to })
            queueNotify(job.from, row.reason)
            queueNotify(job.to, row.reason)
            emitResult(job.id, job.from, "tpstart", false, row.reason)
        end
    end
end
