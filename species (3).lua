-- Generated from bot/species.json + bot/species_caps.json. Do not edit by hand.
PRIMEVAL_PLAYABLE = {"Allo", "Austroraptor", "Beipiaosaurus", "Carnotaurus", "Ceratosaurus", "Deinosuchus", "Diabloceratops", "Dilophosaurus", "Dryosaurus", "Galli", "Herrerasaurus", "Hypsilophodon", "Kentrosaurus", "Maiasaura", "Omniraptor", "Pachycephalosaurus", "Pteranodon", "Stegosaurus", "Tenontosaurus", "Triceratops", "Troodon", "Tyrannosaurus"}
PRIMEVAL_ALIASES = {
    ["tyrannosaurus"] = "Tyrannosaurus",
    ["trex"] = "Tyrannosaurus",
    ["triceratops"] = "Triceratops",
    ["deinosuchus"] = "Deinosuchus",
    ["deino"] = "Deinosuchus",
    ["stegosaurus"] = "Stegosaurus",
    ["diabloceratops"] = "Diabloceratops",
    ["diablo"] = "Diabloceratops",
    ["allosaurus"] = "Allo",
    ["allo"] = "Allo",
    ["herrerasaurus"] = "Herrerasaurus",
    ["hypsilophodon"] = "Hypsilophodon",
    ["dryosaurus"] = "Dryosaurus",
    ["gallimimus"] = "Galli",
    ["galli"] = "Galli",
    ["pachycephalosaurus"] = "Pachycephalosaurus",
    ["troodon"] = "Troodon",
    ["tenontosaurus"] = "Tenontosaurus",
    ["dilophosaurus"] = "Dilophosaurus",
    ["omniraptor"] = "Omniraptor",
    ["ceratosaurus"] = "Ceratosaurus",
    ["maiasaura"] = "Maiasaura",
    ["carnotaurus"] = "Carnotaurus",
    ["beipiaosaurus"] = "Beipiaosaurus",
    ["pteranodon"] = "Pteranodon",
    ["ptera"] = "Pteranodon",
    ["austroraptor"] = "Austroraptor",
    ["austro"] = "Austroraptor",
    ["kentrosaurus"] = "Kentrosaurus",
    ["kentro"] = "Kentrosaurus"
}
PRIMEVAL_HERB_KEYS = {
    ["hypsilophodon"] = true,
    ["dryosaurus"] = true,
    ["pachycephalosaurus"] = true,
    ["stegosaurus"] = true,
    ["triceratops"] = true,
    ["diabloceratops"] = true,
    ["tenontosaurus"] = true,
    ["maiasaura"] = true,
    ["kentrosaurus"] = true
}
PRIMEVAL_OMNI_KEYS = {
    ["omniraptor"] = true,
    ["gallimimus"] = true,
    ["galli"] = true,
    ["beipiaosaurus"] = true,
    ["pteranodon"] = true
}
PRIMEVAL_GROWTH_CAPS = {
    ["allosaurus"] = { maxHunger = 751.7080688, maxFood = 1138.951538 },
    ["austroraptor"] = { maxHunger = 71.63188171, maxFood = 108.5331497 },
    ["beipiaosaurus"] = { maxHunger = 40.69990921, maxFood = 40.69990921 },
    ["carnotaurus"] = { maxHunger = 391.1595764, maxFood = 592.6660156 },
    ["ceratosaurus"] = { maxHunger = 418.5858765, maxFood = 634.2210083 },
    ["deinosuchus"] = { maxHunger = 1757.051514, maxFood = 2662.199219 },
    ["diabloceratops"] = { maxHunger = 1356.664551, maxFood = 1356.664551 },
    ["dilophosaurus"] = { maxHunger = 208.9263916, maxFood = 316.5551147 },
    ["dryosaurus"] = { maxHunger = 58.78870392, maxFood = 58.78870392 },
    ["gallimimus"] = { maxHunger = 226.1715088, maxFood = 226.1715088 },
    ["herrerasaurus"] = { maxHunger = 52.38071442, maxFood = 79.36471558 },
    ["hypsilophodon"] = { maxHunger = 9.044429779, maxFood = 9.044429779 },
    ["kentrosaurus"] = { maxHunger = 915.2766724, maxFood = 915.2766724 },
    ["maiasaura"] = { maxHunger = 1695.829834, maxFood = 1695.829834 },
    ["omniraptor"] = { maxHunger = 123.0972366, maxFood = 186.5109558 },
    ["pachycephalosaurus"] = { maxHunger = 321.3328247, maxFood = 321.3328247 },
    ["pteranodon"] = { maxHunger = 26.231287, maxFood = 39.74437332 },
    ["stegosaurus"] = { maxHunger = 2713.331299, maxFood = 2713.331299 },
    ["tenontosaurus"] = { maxHunger = 723.5541992, maxFood = 723.5541992 },
    ["triceratops"] = { maxHunger = 4152.773438, maxFood = 4152.773438 },
    ["troodon"] = { maxHunger = 17.90797424, maxFood = 27.13329315 },
    ["tyrannosaurus"] = { maxHunger = 2629.997803, maxFood = 3984.844971 }
}
-- ============================================================
-- Optimized species helper layer
-- Keep the generated species tables above unchanged.
-- ============================================================

-- speciesKey() yields "allo"/"galli"; the generated caps use the long names.
PRIMEVAL_GROWTH_CAPS["allo"] = PRIMEVAL_GROWTH_CAPS["allo"] or PRIMEVAL_GROWTH_CAPS["allosaurus"]
PRIMEVAL_GROWTH_CAPS["galli"] = PRIMEVAL_GROWTH_CAPS["galli"] or PRIMEVAL_GROWTH_CAPS["gallimimus"]

PRIMEVAL_SPECIES_CACHE = PRIMEVAL_SPECIES_CACHE or {}
PRIMEVAL_CAP_CACHE = PRIMEVAL_CAP_CACHE or {}

local PRIMEVAL_CANONICAL_BY_KEY = {}
local PRIMEVAL_PLAYABLE_BY_KEY = {}

for _, displayName in ipairs(PRIMEVAL_PLAYABLE or {}) do
    local display = tostring(displayName or "")
    local key = string.lower(display)

    PRIMEVAL_CANONICAL_BY_KEY[key] = display
    PRIMEVAL_PLAYABLE_BY_KEY[key] = true
end

for alias, displayName in pairs(PRIMEVAL_ALIASES or {}) do
    local aliasKey = string.lower(tostring(alias or ""))
    local display = tostring(displayName or "")
    local canonicalKey = string.lower(display)

    PRIMEVAL_CANONICAL_BY_KEY[aliasKey] = display
    PRIMEVAL_PLAYABLE_BY_KEY[canonicalKey] = true
end

local function primevalCleanSpeciesText(value)
    local text = tostring(value or "")
    if text == "" then
        return ""
    end

    text = text:gsub("\\", "/")
    text = text:gsub("_[Cc]$", "")
    text = text:gsub("%s+", "")
    text = text:gsub("^.*/", "")
    text = text:gsub("^Class%s+", "")
    text = text:gsub("^BP[_%-]", "")
    text = text:gsub("^BPC[_%-]", "")
    text = text:gsub("Character$", "")
    text = text:gsub("Dinosaur$", "")
    text = text:gsub("Pawn$", "")
    text = text:gsub("Player$", "")

    return string.lower(text)
end

local function primevalSpeciesFromClassPath(raw)
    local text = tostring(raw or "")
    if text == "" then
        return ""
    end

    -- Extract common class-name fragments from UE paths.
    local lower = string.lower(text)

    local candidates = {
        { "tyrannosaurus", "Tyrannosaurus" },
        { "triceratops", "Triceratops" },
        { "deinosuchus", "Deinosuchus" },
        { "stegosaurus", "Stegosaurus" },
        { "diabloceratops", "Diabloceratops" },
        { "allosaurus", "Allo" },
        { "herrerasaurus", "Herrerasaurus" },
        { "hypsilophodon", "Hypsilophodon" },
        { "dryosaurus", "Dryosaurus" },
        { "gallimimus", "Galli" },
        { "pachycephalosaurus", "Pachycephalosaurus" },
        { "troodon", "Troodon" },
        { "tenontosaurus", "Tenontosaurus" },
        { "dilophosaurus", "Dilophosaurus" },
        { "omniraptor", "Omniraptor" },
        { "ceratosaurus", "Ceratosaurus" },
        { "maiasaura", "Maiasaura" },
        { "carnotaurus", "Carnotaurus" },
        { "beipiaosaurus", "Beipiaosaurus" },
        { "pteranodon", "Pteranodon" },
        { "austroraptor", "Austroraptor" },
        { "kentrosaurus", "Kentrosaurus" },
    }

    for _, row in ipairs(candidates) do
        if lower:find(row[1], 1, true) ~= nil then
            return row[2]
        end
    end

    return nil
end

function speciesKey(value)
    local raw = tostring(value or "")
    if raw == "" then
        return ""
    end

    local cached = PRIMEVAL_SPECIES_CACHE[raw]
    if cached ~= nil then
        return cached
    end

    local fromPath = primevalSpeciesFromClassPath(raw)
    if fromPath ~= nil then
        PRIMEVAL_SPECIES_CACHE[raw] = string.lower(fromPath)
        return PRIMEVAL_SPECIES_CACHE[raw]
    end

    local cleaned = primevalCleanSpeciesText(raw)
    if cleaned == "" then
        PRIMEVAL_SPECIES_CACHE[raw] = ""
        return ""
    end

    local canonical = PRIMEVAL_CANONICAL_BY_KEY[cleaned]
    if canonical ~= nil then
        local result = string.lower(canonical)
        PRIMEVAL_SPECIES_CACHE[raw] = result
        return result
    end

    -- Try removing common UE suffixes one more time.
    local simplified = cleaned
        :gsub("character", "")
        :gsub("dinosaur", "")
        :gsub("pawn", "")
        :gsub("bp", "")

    canonical = PRIMEVAL_CANONICAL_BY_KEY[simplified]
    if canonical ~= nil then
        local result = string.lower(canonical)
        PRIMEVAL_SPECIES_CACHE[raw] = result
        return result
    end

    -- Unknown values are still cached so repeated bad paths are cheap.
    PRIMEVAL_SPECIES_CACHE[raw] = simplified
    return simplified
end

function speciesDisplayName(value)
    local key = speciesKey(value)
    if key == "" then
        return ""
    end

    local canonical = PRIMEVAL_CANONICAL_BY_KEY[key]
    if canonical ~= nil then
        return canonical
    end

    return tostring(value or "")
end

function speciesMatch(left, right)
    local a = speciesKey(left)
    local b = speciesKey(right)

    return a ~= "" and b ~= "" and a == b
end

function isPlayableSpecies(value)
    local key = speciesKey(value)
    return key ~= "" and PRIMEVAL_PLAYABLE_BY_KEY[key] == true
end

function isHerbivoreSpecies(value)
    local key = speciesKey(value)
    return PRIMEVAL_HERB_KEYS[key] == true
end

function isOmnivoreSpecies(value)
    local key = speciesKey(value)
    return PRIMEVAL_OMNI_KEYS[key] == true
end

function isCarnivoreSpecies(value)
    local key = speciesKey(value)
    return key ~= ""
        and PRIMEVAL_HERB_KEYS[key] ~= true
        and PRIMEVAL_OMNI_KEYS[key] ~= true
end

function clearSpeciesCaches()
    PRIMEVAL_SPECIES_CACHE = {}
    PRIMEVAL_CAP_CACHE = {}
end

function speciesCacheStats()
    local speciesCount = 0
    local capCount = 0

    for _ in pairs(PRIMEVAL_SPECIES_CACHE or {}) do
        speciesCount = speciesCount + 1
    end

    for _ in pairs(PRIMEVAL_CAP_CACHE or {}) do
        capCount = capCount + 1
    end

    return speciesCount, capCount
end

if log ~= nil then
    log(string.format(
        "species helpers ready: playable=%d aliases=%d caps=%d",
        #(PRIMEVAL_PLAYABLE or {}),
        (function()
            local n = 0
            for _ in pairs(PRIMEVAL_ALIASES or {}) do
                n = n + 1
            end
            return n
        end)(),
        (function()
            local n = 0
            for _ in pairs(PRIMEVAL_GROWTH_CAPS or {}) do
                n = n + 1
            end
            return n
        end)()
    ))
end