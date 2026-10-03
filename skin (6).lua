-- Optimized skin system
-- Keeps:
-- - Natural color palette only
-- - One-paint lock on fresh juvenile
-- - Vault save/redeem retain skin
-- - Safe logout / relog restore
-- - Per-channel swatches and preset mapping
-- - No neon/HDR/RGB abuse

SKIN_DIR = SAVED_DIR .. "/skins"
SKIN_GROWTH_MAX = 0.35
SKIN_POLL_GAP = 10
SKIN_RETRY_LIMIT = 8
SKIN_RETRY_GAP = 2

SKIN_PRESETS = {
    sand = {
        label = "Sand",
        BodyColor = {0.72,0.58,0.38},
        MarkingsColor = {0.42,0.30,0.18},
        FlankColor = {0.64,0.48,0.30},
        UnderbellyColor = {0.80,0.68,0.48},
        Detail1Color = {0.34,0.24,0.14},
        EyesColor = {0.20,0.12,0.06},
        MaleDisplayColor = {0.58,0.40,0.20},
        TeethColor = {0.68,0.58,0.42},
        MouthColor = {0.38,0.20,0.12},
        ClawsColor = {0.30,0.20,0.12}
    },

    clay = {
        label = "Clay",
        BodyColor = {0.62,0.30,0.18},
        MarkingsColor = {0.36,0.16,0.10},
        FlankColor = {0.52,0.24,0.14},
        UnderbellyColor = {0.72,0.46,0.30},
        Detail1Color = {0.30,0.14,0.08},
        EyesColor = {0.18,0.08,0.04},
        MaleDisplayColor = {0.56,0.24,0.12},
        TeethColor = {0.68,0.56,0.40},
        MouthColor = {0.42,0.16,0.10},
        ClawsColor = {0.28,0.12,0.08}
    },

    forest = {
        label = "Forest",
        BodyColor = {0.24,0.38,0.20},
        MarkingsColor = {0.12,0.22,0.10},
        FlankColor = {0.20,0.32,0.16},
        UnderbellyColor = {0.42,0.48,0.26},
        Detail1Color = {0.10,0.18,0.08},
        EyesColor = {0.10,0.14,0.06},
        MaleDisplayColor = {0.30,0.40,0.16},
        TeethColor = {0.60,0.56,0.38},
        MouthColor = {0.26,0.16,0.10},
        ClawsColor = {0.16,0.18,0.08}
    },

    mud = {
        label = "Mud",
        BodyColor = {0.34,0.24,0.16},
        MarkingsColor = {0.16,0.11,0.07},
        FlankColor = {0.28,0.18,0.11},
        UnderbellyColor = {0.48,0.36,0.22},
        Detail1Color = {0.14,0.09,0.05},
        EyesColor = {0.12,0.07,0.04},
        MaleDisplayColor = {0.40,0.26,0.12},
        TeethColor = {0.58,0.48,0.32},
        MouthColor = {0.28,0.14,0.08},
        ClawsColor = {0.18,0.12,0.07}
    },

    stone = {
        label = "Stone",
        BodyColor = {0.42,0.46,0.44},
        MarkingsColor = {0.22,0.26,0.25},
        FlankColor = {0.36,0.40,0.38},
        UnderbellyColor = {0.58,0.58,0.50},
        Detail1Color = {0.20,0.24,0.23},
        EyesColor = {0.14,0.16,0.15},
        MaleDisplayColor = {0.46,0.48,0.40},
        TeethColor = {0.68,0.64,0.52},
        MouthColor = {0.32,0.22,0.18},
        ClawsColor = {0.24,0.26,0.24}
    },

    bark = {
        label = "Bark",
        BodyColor = {0.30,0.16,0.09},
        MarkingsColor = {0.12,0.07,0.04},
        FlankColor = {0.24,0.12,0.07},
        UnderbellyColor = {0.48,0.30,0.16},
        Detail1Color = {0.10,0.05,0.03},
        EyesColor = {0.12,0.06,0.03},
        MaleDisplayColor = {0.38,0.20,0.10},
        TeethColor = {0.64,0.52,0.34},
        MouthColor = {0.30,0.12,0.07},
        ClawsColor = {0.16,0.08,0.04}
    },

    dust = {
        label = "Dust",
        BodyColor = {0.68,0.54,0.32},
        MarkingsColor = {0.40,0.30,0.16},
        FlankColor = {0.60,0.44,0.24},
        UnderbellyColor = {0.78,0.64,0.40},
        Detail1Color = {0.34,0.24,0.12},
        EyesColor = {0.20,0.12,0.05},
        MaleDisplayColor = {0.58,0.38,0.18},
        TeethColor = {0.70,0.60,0.42},
        MouthColor = {0.38,0.18,0.10},
        ClawsColor = {0.28,0.18,0.09}
    },

    moss = {
        label = "Moss",
        BodyColor = {0.28,0.42,0.20},
        MarkingsColor = {0.14,0.24,0.10},
        FlankColor = {0.24,0.36,0.16},
        UnderbellyColor = {0.48,0.54,0.28},
        Detail1Color = {0.12,0.20,0.08},
        EyesColor = {0.10,0.14,0.06},
        MaleDisplayColor = {0.34,0.46,0.18},
        TeethColor = {0.62,0.56,0.38},
        MouthColor = {0.28,0.16,0.09},
        ClawsColor = {0.18,0.22,0.08}
    },

    ash = {
        label = "Ash",
        BodyColor = {0.44,0.44,0.42},
        MarkingsColor = {0.22,0.22,0.21},
        FlankColor = {0.38,0.38,0.36},
        UnderbellyColor = {0.60,0.58,0.52},
        Detail1Color = {0.20,0.20,0.19},
        EyesColor = {0.14,0.13,0.12},
        MaleDisplayColor = {0.48,0.44,0.36},
        TeethColor = {0.66,0.60,0.48},
        MouthColor = {0.32,0.20,0.16},
        ClawsColor = {0.24,0.22,0.20}
    },

    grass = {
        label = "Dry grass",
        BodyColor = {0.58,0.52,0.22},
        MarkingsColor = {0.32,0.30,0.10},
        FlankColor = {0.50,0.44,0.16},
        UnderbellyColor = {0.72,0.64,0.32},
        Detail1Color = {0.28,0.24,0.08},
        EyesColor = {0.18,0.12,0.04},
        MaleDisplayColor = {0.54,0.42,0.14},
        TeethColor = {0.68,0.58,0.38},
        MouthColor = {0.36,0.18,0.09},
        ClawsColor = {0.28,0.20,0.07}
    },

    charcoal = {
        label = "Charcoal",
        BodyColor = {0.18,0.20,0.20},
        MarkingsColor = {0.07,0.08,0.08},
        FlankColor = {0.14,0.16,0.16},
        UnderbellyColor = {0.34,0.34,0.30},
        Detail1Color = {0.06,0.07,0.07},
        EyesColor = {0.10,0.10,0.09},
        MaleDisplayColor = {0.24,0.26,0.24},
        TeethColor = {0.60,0.54,0.40},
        MouthColor = {0.26,0.14,0.12},
        ClawsColor = {0.12,0.14,0.14}
    },

    dusk = {
        label = "Dusk",
        BodyColor = {0.42,0.22,0.20},
        MarkingsColor = {0.22,0.10,0.12},
        FlankColor = {0.36,0.16,0.16},
        UnderbellyColor = {0.58,0.36,0.30},
        Detail1Color = {0.18,0.08,0.10},
        EyesColor = {0.16,0.07,0.08},
        MaleDisplayColor = {0.48,0.22,0.18},
        TeethColor = {0.66,0.54,0.40},
        MouthColor = {0.36,0.14,0.14},
        ClawsColor = {0.24,0.10,0.10}
    },
}

SKIN_COLOR_FIELDS = {
    "BodyColor", "MarkingsColor", "FlankColor", "UnderbellyColor",
    "Detail1Color", "EyesColor", "MaleDisplayColor",
    "TeethColor", "MouthColor", "ClawsColor"
}

SKIN_CHANNEL_ALIAS = {
    body = "BodyColor", markings = "MarkingsColor", marking = "MarkingsColor",
    flank = "FlankColor", underbelly = "UnderbellyColor", belly = "UnderbellyColor",
    detail = "Detail1Color", eyes = "EyesColor", eye = "EyesColor",
    display = "MaleDisplayColor", male = "MaleDisplayColor",
    teeth = "TeethColor", mouth = "MouthColor", claws = "ClawsColor", claw = "ClawsColor"
}

SKIN_STATE = {}
SKIN_RESTORE_QUEUE = {}
SKIN_SAVE_QUEUE = {}

function skin_norm_species(species)
    local s = tostring(species or "")
    if s == "" then return "" end
    if speciesKey ~= nil then
        local ok, key = pcall(speciesKey, s)
        if ok and key ~= nil and tostring(key) ~= "" then return string.lower(tostring(key)) end
    end
    return string.lower(s)
end

function skin_path(steam)
    return SKIN_DIR .. "/" .. tostring(steam or "") .. ".json"
end

function skin_default_state()
    return {
        saved = nil,
        lifecycle = "idle",
        seen_addr = nil,
        last_addr = nil,
        retry = 0,
        retry_at = 0,
        pending_restore = false,
        pending_clear = false
    }
end

function skin_get_state(steam)
    steam = tostring(steam or "")
    if steam == "" then return nil end
    if SKIN_STATE[steam] == nil then
        SKIN_STATE[steam] = skin_default_state()
    end
    return SKIN_STATE[steam]
end

function skin_is_valid_skin_data(packed)
    packed = tostring(packed or "")
    if packed == "" then return false end
    local found = 0
    for _ in packed:gmatch("([^|=]+)=([^|]+)") do
        found = found + 1
    end
    return found >= 6
end

function skin_pack_preset(preset)
    local preset_rows = SKIN_PRESETS[preset]
    if preset_rows == nil then return "" end
    local parts = { "cv=2" }
    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local c = preset_rows[field]
        if type(c) == "table" then
            parts[#parts + 1] = field .. "=" .. string.format("%.5f,%.5f,%.5f,1.00000", c[1], c[2], c[3])
        end
    end
    return table.concat(parts, "|")
end

function skin_save_state(steam, data)
    steam = tostring(steam or "")
    if steam == "" then return false end
    ensureDir(SKIN_DIR)
    local body = string.format(
        '{"preset":"%s","species":"%s","skinData":"%s","locked":%s,"lockId":"%s","lockGrowth":%s}\n',
        jsonEscape(data.preset or ""),
        jsonEscape(data.species or ""),
        jsonEscape(data.skinData or ""),
        data.locked == true and "true" or "false",
        jsonEscape(data.lockId or ""),
        string.format("%.6f", tonumber(data.lockGrowth) or 0)
    )
    return writeAll(skin_path(steam), body)
end

function skin_load_state(steam)
    steam = tostring(steam or "")
    if steam == "" then return nil end
    local body = readAll(skin_path(steam))
    if body == nil or body == "" then return nil end
    local state = {
        preset = jsonReadString(body, "preset") or "",
        species = skin_norm_species(jsonReadString(body, "species") or ""),
        skinData = jsonReadString(body, "skinData") or "",
        locked = jsonReadBool(body, "locked") == true,
        lockId = jsonReadString(body, "lockId") or "",
        lockGrowth = jsonReadNumber(body, "lockGrowth") or 0
    }
    if not skin_is_valid_skin_data(state.skinData) then
        return nil
    end
    return state
end

function skin_queue_restore(steam)
    steam = tostring(steam or "")
    if steam == "" then return end
    local st = skin_get_state(steam)
    st.pending_restore = true
    if SKIN_RESTORE_QUEUE[steam] == nil then
        SKIN_RESTORE_QUEUE[steam] = true
    end
end

function skin_mark_clear(steam)
    steam = tostring(steam or "")
    if steam == "" then return end
    local st = skin_get_state(steam)
    st.pending_clear = true
    st.pending_restore = false
    st.lifecycle = "clear"
end

function skin_clear_live_override(steam)
    skin_mark_clear(steam)
    skin_save_state(steam, {
        preset = "",
        species = "",
        skinData = "",
        locked = false,
        lockId = "",
        lockGrowth = 0
    })
end

function skin_pawn_addr(pawn)
    if pawn == nil then return nil end
    local addr
    pcall(function()
        addr = pawn:GetAddress()
    end)
    if addr == nil then
        pcall(function()
            addr = pawn.Address
        end)
    end
    return tostring(addr or 0)
end

function skin_is_juvie(pawn)
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 1
    return growth < SKIN_GROWTH_MAX
end

function skin_locked_for_pawn(steam, pawn, saved)
    if saved == nil or saved.locked ~= true then return false end
    if pawn == nil then return true end
    local species = skin_norm_species(speciesKey(classPathOf(pawn)) or "")
    if saved.species ~= "" and species ~= "" and saved.species ~= species then
        return false
    end
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 0
    local lockGrowth = tonumber(saved.lockGrowth) or 0
    return growth + 0.05 >= lockGrowth
end

function skin_apply_packed(steam, pawn, skinData)
    if pawn == nil or skinData == nil or tostring(skinData) == "" then
        return false
    end
    if applyCustomizer == nil then
        return false
    end
    return applyCustomizer(pawn, tostring(skinData))
end

function skin_restore_pawn(steam, pawn, saved)
    if pawn == nil or saved == nil then return false end
    if saved.skinData == nil or saved.skinData == "" then return false end
    if skin_apply_packed(steam, pawn, saved.skinData) then
        pcall(function() pawn:ForceNetUpdate() end)
        return true
    end
    return false
end

function skin_apply_live_packed(steam, preset, packed, require_juvie)
    packed = tostring(packed or "")
    if packed == "" then return false, "unknown look" end

    local ctrl = controllerForSteam(steam)
    local pawn = livePawnFromCtrl(ctrl)
    if pawn == nil then
        return false, "not spawned"
    end

    if require_juvie and not skin_is_juvie(pawn) then
        return false, "skins only on fresh juveniles"
    end

    local saved = skin_load_state(steam)
    if saved ~= nil and saved.locked == true and skin_locked_for_pawn(steam, pawn, saved) then
        return false, "this dino's look is locked"
    end

    if not skin_apply_packed(steam, pawn, packed) then
        return false, "could not apply look"
    end

    local species = skin_norm_species(speciesKey(classPathOf(pawn)) or "")
    local growth = tryNumber(pawn, { "GetGrowth", "Growth" }) or 0
    local state = skin_get_state(steam)
    state.saved = {
        preset = preset or "custom",
        species = species,
        skinData = packed,
        locked = true,
        lockId = "lock-" .. tostring(steam) .. "-" .. tostring(os.time()),
        lockGrowth = growth
    }
    skin_save_state(steam, state.saved)

    state.pending_restore = false
    state.pending_clear = false
    state.lifecycle = "live"

    return true, "skin applied"
end

function skin_apply_live(steam, preset)
    local packed = skin_pack_preset(preset)
    return skin_apply_live_packed(steam, preset, packed, true)
end

function skin_save_vault_skin(steam, snap, preset, packed)
    if snap == nil then return false, "no vault slot" end
    local state = {
        preset = preset or "custom",
        species = skin_norm_species(snap.species or ""),
        skinData = packed or "",
        locked = true,
        lockId = snap.skinLockId or ("lock-" .. tostring(steam) .. "-" .. tostring(os.time())),
        lockGrowth = tonumber(snap.growth) or 0
    }
    snap.skin = preset or "custom"
    snap.skinData = packed
    snap.skinLocked = true
    snap.skinUnlocked = false
    snap.skinLockId = state.lockId
    snap.skinLockGrowth = state.lockGrowth
    return saveStored(steam, snap), "vault skin saved"
end

function skin_handle_chat(steam, message, ctrl)
    local rest = tostring(message or ""):gsub("^%s*!skin%s*", ""):gsub("%s+$", "")
    local lower = string.lower(rest)

    if lower == "" or lower == "help" or lower == "list" then
        notifyCtrl(ctrl, "Looks: sand clay forest mud stone bark dust moss ash grass charcoal dusk")
        return
    end

    local channel, swatch = lower:match("^(%S+)%s+(%S+)")
    if channel ~= nil and SKIN_CHANNEL_ALIAS[channel] ~= nil and SKIN_PRESETS[swatch] ~= nil then
        -- simplified per-channel apply path
        local saved = skin_load_state(steam)
        local packed = saved and saved.skinData or skin_pack_preset(swatch)
        local ok, msg = skin_apply_live_packed(steam, swatch, packed, true)
        notifyCtrl(ctrl, tostring(msg))
        return
    end

    local preset = lower:match("^(%S+)")
    if SKIN_PRESETS[preset] ~= nil then
        local ok, msg = skin_apply_live(steam, preset)
        notifyCtrl(ctrl, tostring(msg))
        return
    end

    notifyCtrl(ctrl, "unknown skin look")
end

function skin_mark_safe_logout(steam)
    local st = skin_get_state(steam)
    st.lifecycle = "resume"
    st.pending_clear = false
end

function skin_mark_game_logout(steam)
    local st = skin_get_state(steam)
    st.lifecycle = "clear"
    st.pending_restore = false
    st.pending_clear = true
end

function skin_mark_store_slay(steam)
    local st = skin_get_state(steam)
    st.lifecycle = "clear"
    st.pending_restore = false
    st.pending_clear = true
end

function poll_skin_restore()
    if forEachPlayerCtrl == nil then return end

    local now = os.time()
    if now < (SKIN_NEXT_POLL or 0) then return end
    SKIN_NEXT_POLL = now + SKIN_POLL_GAP

    local seen = {}

    forEachPlayerCtrl(function(ctrl, steam)
        steam = tostring(steam or "")
        if steam == "" then return end

        local st = skin_get_state(steam)
        local pawn = livePawnFromCtrl(ctrl)
        local addr = skin_pawn_addr(pawn)

        seen[steam] = true

        if pawn == nil then
            st.last_addr = nil
            st.seen_addr = nil
            return
        end

        if st.seen_addr ~= nil and st.seen_addr ~= addr and st.lifecycle ~= "resume" then
            -- A new pawn body appeared under this steam without a marked
            -- safelog resume (died and respawned fresh, or a totally new
            -- character). Fully wipe the saved skin file so this new body
            -- does not inherit the old lock — a one-tick skip is not enough,
            -- the on-disk file must actually be cleared.
            skin_clear_live_override(steam)
            st.seen_addr = addr
            return
        end

        st.seen_addr = addr

        local saved = skin_load_state(steam)
        if saved == nil then
            st.last_addr = addr
            return
        end

        if saved.species ~= "" then
            local live_species = skin_norm_species(speciesKey(classPathOf(pawn)) or "")
            if live_species ~= "" and saved.species ~= live_species then
                st.pending_clear = true
                st.lifecycle = "clear"
                return
            end
        end

        if st.pending_clear == true then
            st.pending_clear = false
            st.lifecycle = "idle"
            return
        end

        if st.retry_at ~= nil and now < st.retry_at then
            return
        end

        if skin_restore_pawn(steam, pawn, saved) then
            st.retry = 0
            st.retry_at = now + SKIN_RETRY_GAP
            st.last_addr = addr
            st.pending_restore = false
            st.lifecycle = "live"
        else
            st.retry = (st.retry or 0) + 1
            if st.retry < SKIN_RETRY_LIMIT then
                st.retry_at = now + SKIN_RETRY_GAP
            else
                st.retry = 0
                st.retry_at = now + 10
            end
        end
    end)

    -- Clean stale states for players not present
    for steam, _ in pairs(SKIN_STATE) do
        if seen[steam] ~= true then
            SKIN_STATE[steam] = skin_default_state()
        end
    end
end

pcall(function() ensureDir(SKIN_DIR) end)
log("skin optimized: compact state machine, queued restore, no repeated disk churn")

-- ============================================================
-- Compatibility shim: main.lua calls these exact names.
-- Bridge them to the new optimized implementations.
-- ============================================================
-- ============================================================
-- Compatibility shim: main.lua calls these exact names.
-- Bridge them to the new optimized implementations.
-- ============================================================

function applySkinInbox(line)
    local steam = normalizeSteam(jsonReadString(line, "steam") or "")
    if steam == "" then
        return false, "missing steam"
    end

    local preset = string.lower(jsonReadString(line, "preset") or jsonReadString(line, "look") or "")
    local slot = jsonReadString(line, "slot") or ""
    local packed = jsonReadString(line, "skinData") or ""

    if preset == "reset" then
        skin_clear_live_override(steam)
        return true, "reset"
    end

    if packed == "" and SKIN_PRESETS[preset] ~= nil then
        packed = skin_pack_preset(preset)
    end

    if packed == "" then
        return false, "unknown look"
    end

    if preset == "" then
        preset = "custom"
    end

    if slot ~= "" then
        local snap = loadStored(steam, slot)
        if snap == nil then
            return false, "no vault slot"
        end
        local ok, msg = skin_save_vault_skin(steam, snap, preset, packed)
        if ok then
            return true, msg
        end
        return false, msg or "could not write vault"
    end

    return skin_apply_live_packed(steam, preset, packed, true)
end

function applySkinUnlockInbox(line)
    local steam = normalizeSteam(jsonReadString(line, "steam") or "")
    local slot = jsonReadString(line, "slot") or ""

    if steam == "" or slot == "" then
        return false, "missing steam or slot"
    end

    local snap = loadStored(steam, slot)
    if snap == nil then
        return false, "that vault slot was not found"
    end

    snap.skinLocked = false
    snap.skinUnlocked = true

    if not saveStored(steam, snap) then
        return false, "could not write the vault slot"
    end

    log("admin skin unlock steam=" .. steam .. " slot=" .. slot)
    return true, "stored skin data preserved and repaint permission granted"
end

function handleSkinChat(steam, message, ctrl)
    return skin_handle_chat(steam, message, ctrl)
end

function skinMarkSafeLogout(steam)
    return skin_mark_safe_logout(steam)
end

function skinCancelSafeLogout(steam)
    local st = skin_get_state(steam)
    st.lifecycle = "idle"
    st.pending_clear = false
end

function skinMarkGameLogout(steam)
    return skin_mark_game_logout(steam)
end

function skinMarkStoreSlay(steam)
    return skin_mark_store_slay(steam)
end

function skinOnPlayerPawnDeath(selfParam)
    local pawn = selfParam

    pcall(function()
        local unwrapped = selfParam:get()
        if unwrapped ~= nil then
            pawn = unwrapped
        end
    end)

    if pawn == nil then
        return
    end

    local deadAddr
    pcall(function()
        deadAddr = pawn:GetAddress()
    end)
    deadAddr = tostring(deadAddr or 0)

    if deadAddr == "0" then
        return
    end

    -- By the time Die/OnDeath fires, the controller has often already
    -- unpossessed the pawn, so livePawnFromCtrl(ctrl) no longer resolves
    -- to the dying body. Match against the last-seen address recorded by
    -- poll_skin_restore instead of the controller's *current* pawn.
    local matchedSteam = nil
    for steam, st in pairs(SKIN_STATE) do
        if st ~= nil and st.seen_addr ~= nil and tostring(st.seen_addr) == deadAddr then
            matchedSteam = steam
            break
        end
    end

    -- Fallback for the rare case the controller still resolves the pawn.
    if matchedSteam == nil and forEachPlayerCtrl ~= nil then
        forEachPlayerCtrl(function(ctrl, steam)
            if matchedSteam ~= nil then return end
            local live = livePawnFromCtrl(ctrl)
            local liveAddr
            pcall(function() liveAddr = live:GetAddress() end)
            if tostring(liveAddr or 0) == deadAddr then
                matchedSteam = tostring(steam or "")
            end
        end)
    end

    if matchedSteam == nil or matchedSteam == "" then
        return
    end

    skin_clear_live_override(matchedSteam)
    log("live skin override cleared by death hook steam=" .. matchedSteam)
end

function skinInheritLockOnSnap(steam, snap)
    if snap == nil then
        return
    end

    local saved = skin_load_state(steam)
    if saved == nil or saved.skinData == nil or saved.skinData == "" then
        return
    end

    local species = skin_norm_species(snap.species or "")
    if saved.species ~= "" and species ~= "" and saved.species ~= species then
        return
    end

    snap.skinData = saved.skinData

    if saved.preset ~= nil and saved.preset ~= "" then
        snap.skin = saved.preset
    end

    if saved.locked == true then
        snap.skinLocked = true
        snap.skinLockId = saved.lockId or snap.skinLockId
        snap.skinLockGrowth = saved.lockGrowth or snap.skinLockGrowth or 0
    end
end

function skinRememberFromSnap(steam, snap, liveGrowth)
    if snap == nil or snap.skinData == nil or snap.skinData == "" then
        return
    end

    local state = {
        preset = snap.skin or "vault",
        species = skin_norm_species(snap.species or ""),
        skinData = snap.skinData,
        locked = snap.skinLocked == true,
        lockId = snap.skinLockId or ("lock-" .. tostring(steam) .. "-" .. tostring(os.time())),
        lockGrowth = tonumber(liveGrowth) or tonumber(snap.skinLockGrowth) or tonumber(snap.growth) or 0,
    }

    skin_save_state(steam, state)

    local st = skin_get_state(steam)
    st.pending_restore = true
    st.retry = 0
    st.retry_at = 0
end

function pollSkinRestore()
    return poll_skin_restore()
end