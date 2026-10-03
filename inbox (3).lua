--[[
  Inbox helpers for PrimevalRedeem.
  Discord appends JSON lines to Saved/inbox.ndjson. Do not spawn cmd.exe.
]]

local function inboxDir(saved)
    return saved .. "/inbox"
end

local function rotateIfHuge(path, limit)
    limit = limit or 800000
    local f = io.open(path, "rb")
    if f == nil then return end
    local size = f:seek("end")
    f:close()
    if size ~= nil and size > limit then
        os.rename(path, path .. "." .. tostring(os.time()) .. ".old")
    end
end

local function listJsonNames(_dirPath, _listPath)
    -- Do not spawn cmd.exe. The bot appends to inbox.ndjson; Lua reads that file.
    return {}
end

PrimevalInbox = {
    dir = inboxDir,
    rotateIfHuge = rotateIfHuge,
    listJsonNames = listJsonNames,
}
