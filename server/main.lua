--[[
    qb-codedoors · server core
    ------------------------------------------------------------------
    Stores the locks in doors.json, keeps them in sync with the
    clients and checks every code. Codes never leave the server unless
    the requester is an admin, so a player can never read a code from
    the client files.
------------------------------------------------------------------]]

local QBCore = exports['qb-core']:GetCoreObject()
local RES = GetCurrentResourceName()

CDServer = CDServer or {}
CDServer.doors    = {}   -- id -> door
CDServer.timers   = {}   -- id -> auto close handle
CDServer.attempts = {}   -- playerId -> { fails, blockedUntil }

function CDServer.log(...)
    if Config.Debug then print('[qb-codedoors]', ...) end
end

function CDServer.notify(src, message, kind)
    if src and src > 0 then
        TriggerClientEvent('QBCore:Notify', src, message, kind or 'primary')
    end
end

--========================================================================
--  Helpers
--========================================================================

local function vec(coords)
    return vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
end

local function doorCenter(door)
    local x, y, z = 0.0, 0.0, 0.0
    for i = 1, #door.doors do
        local c = door.doors[i].coords
        x, y, z = x + c.x, y + c.y, z + c.z
    end
    local n = math.max(#door.doors, 1)
    return vector3(x / n, y / n, z / n)
end

function CDServer.distanceToPlayer(src, door)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 9999.0 end
    local pcoords = GetEntityCoords(ped)
    local best = 9999.0
    for i = 1, #door.doors do
        local d = #(pcoords - vec(door.doors[i].coords))
        if d < best then best = d end
    end
    return best
end

function CDServer.isNear(src, door, distance)
    return CDServer.distanceToPlayer(src, door) <= (distance or Config.CodeDistance)
end

-- id of a lock: derived from its first leaf, so a door can only ever
-- hold one lock (created twice = the same id, updated instead of duplicated)
function CDServer.makeId(hash, coords)
    return ('%d_%d_%d_%d'):format(
        math.floor((tonumber(hash) or 0) + 0.5),
        math.floor(coords.x * 10 + 0.5),
        math.floor(coords.y * 10 + 0.5),
        math.floor(coords.z * 10 + 0.5))
end

function CDServer.payload(door, withPin)
    local leaves = {}
    for i = 1, #door.doors do
        local leaf = door.doors[i]
        leaves[i] = {
            hash    = leaf.hash,
            model   = leaf.model,
            name    = leaf.name,
            coords  = { x = leaf.coords.x, y = leaf.coords.y, z = leaf.coords.z },
            heading = leaf.heading,
        }
    end

    local data = {
        id        = door.id,
        name      = door.name,
        type      = door.type,
        locked    = door.locked and true or false,
        autoClose = door.autoClose,
        distance  = door.distance,
        auto      = door.auto and true or false,
        holdOpen  = door.holdOpen and true or false,
        rate      = door.rate,
        zone      = door.zone,
        doors     = leaves,
    }
    if withPin then data.pin = door.pin end
    return data
end

--========================================================================
--  Storage
--========================================================================

local function aliasLeaf(model, coords, heading)
    return {
        hash = Config.aliasHash(model, coords),
        model = math.floor((tonumber(model) or 0) + 0.5),
        coords = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 },
        heading = (tonumber(heading) or 0.0) + 0.0,
    }
end

-- Accepts old saves (v1 of this resource and the "doorcode" layout) so
-- existing doors keep working after the upgrade.
local function sanitizeDoor(id, raw)
    if type(raw) ~= 'table' then return nil end

    local door = {}
    door.id = tostring(raw.id or id)
    door.name = tostring(raw.name or raw.label or 'Door'):sub(1, 40)
    if door.name == '' then door.name = 'Door' end

    door.pin = tostring(raw.pin or raw.code or ''):gsub('%s', '')
    if #door.pin ~= Config.PinLength or not door.pin:match('^%d+$') then
        door.pin = string.rep('0', Config.PinLength)
    end

    door.locked = raw.locked ~= false
    door.autoClose = math.floor(tonumber(raw.autoClose) or Config.Defaults.autoClose)
    door.distance = tonumber(raw.distance) or Config.Defaults.distance
    door.zone = raw.zone and tostring(raw.zone) or nil

    local dtype = raw.type or raw.dtype
    if dtype == 'standard' then dtype = 'door' elseif dtype == 'sliding' then dtype = 'gate' end
    if not Config.DoorTypes[dtype] then dtype = Config.Defaults.type end
    door.type = dtype

    local preset = Config.DoorTypes[dtype]
    door.auto = raw.auto ~= nil and raw.auto or preset.auto
    door.holdOpen = raw.holdOpen ~= nil and raw.holdOpen or preset.holdOpen
    door.rate = tonumber(raw.rate) or preset.rate

    -- door leaves
    door.doors = {}
    if type(raw.doors) == 'table' then
        for i = 1, math.min(#raw.doors, 4) do
            local leaf = raw.doors[i]
            if type(leaf) == 'table' and type(leaf.coords) == 'table' and leaf.coords.x then
                door.doors[#door.doors + 1] = {
                    hash = math.floor((tonumber(leaf.hash) or tonumber(leaf.model) or 0) + 0.5),
                    model = math.floor((tonumber(leaf.model) or 0) + 0.5),
                    name = leaf.name and tostring(leaf.name) or nil,
                    coords = { x = leaf.coords.x + 0.0, y = leaf.coords.y + 0.0, z = leaf.coords.z + 0.0 },
                    heading = (tonumber(leaf.heading) or 0.0) + 0.0,
                }
            end
        end
    elseif raw.model and type(raw.coords) == 'table' and raw.coords.x then
        -- v1 save: a single door leaf
        local leaf = aliasLeaf(raw.model, raw.coords, raw.heading)
        leaf.name = nil
        door.doors[1] = leaf
    end

    if #door.doors == 0 then return nil end
    return door
end

function CDServer.save()
    local ok, encoded = pcall(json.encode, CDServer.doors)
    if not ok or type(encoded) ~= 'string' then
        print('[qb-codedoors] ERROR: could not encode the door data — nothing written')
        return
    end
    local ok2, written = pcall(SaveResourceFile, RES, Config.SaveFile, encoded, -1)
    if not ok2 or written == false then
        print(('[qb-codedoors] ERROR: could not write %s — check folder permissions'):format(Config.SaveFile))
    end
end

function CDServer.load()
    local loaded = {}
    local raw = LoadResourceFile(RES, Config.SaveFile)

    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then
            for id, entry in pairs(data) do
                local door = sanitizeDoor(id, entry)
                if door and not loaded[door.id] then loaded[door.id] = door end
            end
        else
            print(('[qb-codedoors] ERROR: %s is not valid json — ignored'):format(Config.SaveFile))
        end
    end

    CDServer.doors = loaded

    local count = 0
    for _ in pairs(loaded) do count = count + 1 end
    print(('[qb-codedoors] %d door lock(s) loaded'):format(count))

    if Config.LockOnStartup then
        for _, door in pairs(loaded) do door.locked = true end
        if count > 0 then CDServer.save() end
    end
end

--========================================================================
--  Syncing
--========================================================================

local function sendTo(src, id, door)
    TriggerClientEvent('codedoors:client:sync', src, id, CDServer.payload(door, false))
end

function CDServer.syncTo(src)
    if not src or src == 0 then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local pcoords = GetEntityCoords(ped)

    for id, door in pairs(CDServer.doors) do
        if #(pcoords - doorCenter(door)) <= Config.SyncRange then
            sendTo(src, id, door)
        end
    end
end

function CDServer.broadcast(id)
    local door = CDServer.doors[id]
    if not door then return end
    local center = doorCenter(door)

    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        local ped = src and GetPlayerPed(src)
        if ped and ped ~= 0 and #(GetEntityCoords(ped) - center) <= Config.SyncRange then
            sendTo(src, id, door)
        end
    end
end

--========================================================================
--  Lock state & auto closing
--========================================================================

function CDServer.cancelTimer(id)
    if CDServer.timers[id] then
        ClearTimeout(CDServer.timers[id])
        CDServer.timers[id] = nil
    end
end

function CDServer.scheduleAutoClose(id)
    CDServer.cancelTimer(id)

    local door = CDServer.doors[id]
    if not door or door.locked then return end

    local seconds = tonumber(door.autoClose) or 0
    if seconds <= 0 then return end

    CDServer.timers[id] = SetTimeout(seconds * 1000, function()
        CDServer.timers[id] = nil

        local current = CDServer.doors[id]
        if not current or current.locked then return end

        if Config.RelockAfterClose then
            current.locked = true
            CDServer.save()
            CDServer.broadcast(id)
            CDServer.log(('auto closed & locked "%s"'):format(current.name))
        else
            -- stay unlocked, but make sure the door itself is shut again
            local center = doorCenter(current)
            for _, srcStr in ipairs(GetPlayers()) do
                local src = tonumber(srcStr)
                local ped = src and GetPlayerPed(src)
                if ped and ped ~= 0 and #(GetEntityCoords(ped) - center) <= Config.SyncRange then
                    TriggerClientEvent('codedoors:client:closeDoor', src, id)
                end
            end
            CDServer.log(('auto closed "%s"'):format(current.name))
        end
    end)
end

function CDServer.setLocked(id, locked)
    local door = CDServer.doors[id]
    if not door then return end

    door.locked = locked and true or false
    CDServer.save()
    CDServer.broadcast(id)

    if door.locked then
        CDServer.cancelTimer(id)
    else
        CDServer.scheduleAutoClose(id)
    end
end

--========================================================================
--  Players
--========================================================================

RegisterNetEvent('codedoors:server:request', function()
    local src = source
    if not src or src == 0 then return end
    TriggerClientEvent('codedoors:client:admin', src, CDServer.isAdmin(src))
    CDServer.syncTo(src)
end)

local function registerResult(src, door)
    CDServer.attempts[src] = nil

    local seconds = math.floor(tonumber(door.autoClose) or 0)
    local message = seconds > 0
        and ('%s unlocked — it closes again in %d seconds'):format(door.name, seconds)
        or ('%s unlocked'):format(door.name)

    CDServer.notify(src, message, 'success')
    TriggerClientEvent('codedoors:client:keypadResult', src, true, message)
end

local function registerFailure(src)
    local state = CDServer.attempts[src]
    if not state then
        state = { fails = 0, blockedUntil = 0 }
        CDServer.attempts[src] = state
    end

    state.fails = state.fails + 1

    if Config.MaxAttempts > 0 and state.fails >= Config.MaxAttempts then
        state.fails = 0
        state.blockedUntil = GetGameTimer() + Config.AttemptCooldown * 1000
        CDServer.notify(src, ('Too many wrong codes — try again in %d seconds'):format(Config.AttemptCooldown), 'error')
    else
        CDServer.notify(src, 'Wrong code', 'error')
    end

    TriggerClientEvent('codedoors:client:keypadResult', src, false, nil)
end

RegisterNetEvent('codedoors:server:code', function(id, code, mode, newCode)
    local src = source
    if not src or src == 0 then return end
    if type(id) ~= 'string' or type(code) ~= 'string' then return end

    local door = CDServer.doors[id]
    if not door then return end

    if not CDServer.isNear(src, door, Config.CodeDistance) then
        CDServer.notify(src, 'You are too far away from that door', 'error')
        TriggerClientEvent('codedoors:client:keypadResult', src, false, nil)
        return
    end

    local state = CDServer.attempts[src]
    if state and state.blockedUntil and state.blockedUntil > GetGameTimer() then
        CDServer.notify(src, ('Wait %d seconds before trying again')
            :format(math.ceil((state.blockedUntil - GetGameTimer()) / 1000)), 'error')
        TriggerClientEvent('codedoors:client:keypadResult', src, false, nil)
        return
    end

    code = code:gsub('%s', '')
    if #code ~= Config.PinLength or not code:match('^%d+$') then
        TriggerClientEvent('codedoors:client:keypadResult', src, false, nil)
        return
    end

    if code ~= door.pin then
        registerFailure(src)
        return
    end

    -- ── change the code ──────────────────────────────────────────────
    if mode == 'change' then
        if not Config.PlayersCanChangeCode then
            CDServer.notify(src, 'Changing codes is disabled on this server', 'error')
            return
        end

        newCode = tostring(newCode or ''):gsub('%s', '')
        if #newCode ~= Config.PinLength or not newCode:match('^%d+$') then
            TriggerClientEvent('codedoors:client:keypadResult', src, false, 'invalid-new')
            return
        end

        door.pin = newCode
        CDServer.attempts[src] = nil
        CDServer.save()

        print(('[qb-codedoors] %s changed the code of "%s"'):format(GetPlayerName(src) or src, door.name))

        if door.locked then
            -- they proved they know the code, so let them in
            door.locked = false
            CDServer.save()
            CDServer.broadcast(id)
            CDServer.scheduleAutoClose(id)
        end

        CDServer.notify(src, ('Code updated for %s'):format(door.name), 'success')
        TriggerClientEvent('codedoors:client:keypadResult', src, true, 'changed')
        return
    end

    -- ── unlock ───────────────────────────────────────────────────────
    if not door.locked then
        TriggerClientEvent('codedoors:client:keypadResult', src, true, 'already')
        return
    end

    door.locked = false
    CDServer.save()
    CDServer.broadcast(id)
    CDServer.scheduleAutoClose(id)
    registerResult(src, door)
end)

-- Anyone standing at an unlocked door may lock it again (no code needed)
RegisterNetEvent('codedoors:server:lock', function(id)
    local src = source
    if not src or src == 0 or type(id) ~= 'string' then return end

    local door = CDServer.doors[id]
    if not door or door.locked then return end

    if not CDServer.isNear(src, door, Config.CodeDistance + 2.0) then return end

    CDServer.setLocked(id, true)
    CDServer.notify(src, ('%s locked'):format(door.name), 'success')
end)

AddEventHandler('playerDropped', function()
    CDServer.attempts[source] = nil
end)

--========================================================================
--  Startup & keep-alive
--========================================================================

AddEventHandler('onResourceStart', function(resource)
    if resource ~= RES then return end
    CDServer.load()
    SetTimeout(3000, function()
        for _, srcStr in ipairs(GetPlayers()) do
            local src = tonumber(srcStr)
            if src then CDServer.syncTo(src) end
        end
    end)
end)

-- Periodic resync: late joiners, players walking into a new area and
-- doors that changed while nobody was around.
CreateThread(function()
    while true do
        Wait(10000)
        for _, srcStr in ipairs(GetPlayers()) do
            local src = tonumber(srcStr)
            if src then CDServer.syncTo(src) end
        end
    end
end)
