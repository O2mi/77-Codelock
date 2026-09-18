--[[
    qb-codedoors · admin side
    ------------------------------------------------------------------
    Only admins may create, edit or delete locks. Every event below
    re-checks the permission on the server, so a modified client can
    never manage locks.
------------------------------------------------------------------]]

local QBCore = exports['qb-core']:GetCoreObject()

--========================================================================
--  Permission
--========================================================================

function CDServer.isAdmin(src)
    if not src or src == 0 then return true end -- console

    if Config.AdminAce and Config.AdminAce ~= '' and IsPlayerAceAllowed(src, Config.AdminAce) then
        return true
    end

    local ok, allowed = pcall(function()
        return QBCore.Functions.HasPermission(src, Config.AdminPermissions)
    end)
    if ok and allowed then return true end

    -- common fallbacks for servers using ACE groups
    return IsPlayerAceAllowed(src, 'admin')
        or IsPlayerAceAllowed(src, 'god')
        or IsPlayerAceAllowed(src, 'command')
end

local function requireAdmin(src)
    if CDServer.isAdmin(src) then return true end
    CDServer.notify(src, 'You are not allowed to manage door locks', 'error')
    return false
end

--========================================================================
--  Door list (admins receive the codes, players never do)
--========================================================================

QBCore.Functions.CreateCallback('codedoors:server:list', function(source, cb)
    if not CDServer.isAdmin(source) then return cb(nil) end

    local list = {}
    for _, door in pairs(CDServer.doors) do
        list[#list + 1] = CDServer.payload(door, true)
    end
    table.sort(list, function(a, b)
        return string.lower(a.name or '') < string.lower(b.name or '')
    end)
    cb(list)
end)

--========================================================================
--  Create / update
--========================================================================

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function cleanLeaves(input)
    local leaves = {}
    if type(input) ~= 'table' then return leaves end

    for i = 1, math.min(#input, 4) do
        local leaf = input[i]
        if type(leaf) == 'table' and type(leaf.coords) == 'table' and tonumber(leaf.coords.x) then
            local model = math.floor((tonumber(leaf.model) or 0) + 0.5)
            local hash = math.floor((tonumber(leaf.hash) or 0) + 0.5)
            if model ~= 0 then
                if hash == 0 then hash = Config.aliasHash(model, leaf.coords) end
                leaves[#leaves + 1] = {
                    hash    = hash,
                    model   = model,
                    name    = (type(leaf.name) == 'string' and leaf.name ~= '') and leaf.name:sub(1, 40) or nil,
                    coords  = {
                        x = tonumber(leaf.coords.x) + 0.0,
                        y = tonumber(leaf.coords.y) + 0.0,
                        z = tonumber(leaf.coords.z) + 0.0,
                    },
                    heading = (tonumber(leaf.heading) or 0.0) + 0.0,
                }
            end
        end
    end
    return leaves
end

RegisterNetEvent('codedoors:server:save', function(data)
    local src = source
    if not requireAdmin(src) then return end
    if type(data) ~= 'table' then return end

    local name = tostring(data.name or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 40)
    if name == '' then name = 'Door' end

    local pin = tostring(data.pin or ''):gsub('%s', '')
    if #pin ~= Config.PinLength or not pin:match('^%d+$') then
        return CDServer.notify(src, ('The code must be exactly %d digits'):format(Config.PinLength), 'error')
    end

    local dtype = tostring(data.type or Config.Defaults.type)
    if not Config.DoorTypes[dtype] then dtype = Config.Defaults.type end
    local preset = Config.DoorTypes[dtype]

    local leaves = cleanLeaves(data.doors)
    if #leaves == 0 then
        return CDServer.notify(src, 'No door selected — look at a door and press E first', 'error')
    end

    -- update the lock being edited, or the lock that already sits on this door
    local door = (data.id and CDServer.doors[data.id]) or nil
    if not door then
        local id = CDServer.makeId(leaves[1].hash, leaves[1].coords)
        door = CDServer.doors[id]
    end
    local isNew = door == nil
    door = door or {}

    -- one door leaf may only belong to a single lock
    for i = 1, #leaves do
        for otherId, other in pairs(CDServer.doors) do
            if otherId ~= door.id then
                for j = 1, #other.doors do
                    if other.doors[j].hash == leaves[i].hash then
                        return CDServer.notify(src,
                            ('That door is already part of "%s"'):format(other.name), 'error')
                    end
                end
            end
        end
    end

    if isNew then
        local count = 0
        for _ in pairs(CDServer.doors) do count = count + 1 end
        if count >= Config.MaxDoors then
            return CDServer.notify(src,
                ('Door limit reached (%d) — raise Config.MaxDoors'):format(Config.MaxDoors), 'error')
        end
    end

    door.id = door.id or CDServer.makeId(leaves[1].hash, leaves[1].coords)
    door.name = name
    door.pin = pin
    door.type = dtype
    door.autoClose = clamp(math.floor(tonumber(data.autoClose) or Config.Defaults.autoClose),
        Config.MinAutoCloseTime, Config.MaxAutoCloseTime)
    door.distance = clamp(tonumber(data.distance) or Config.Defaults.distance, 1.0, 10.0)
    door.auto = data.auto ~= nil and data.auto or preset.auto
    door.holdOpen = data.holdOpen ~= nil and data.holdOpen or preset.holdOpen
    door.rate = preset.rate
    door.doors = leaves
    if type(data.zone) == 'string' and data.zone ~= '' then door.zone = data.zone:sub(1, 40) end
    if door.locked == nil then door.locked = data.locked ~= false end

    CDServer.doors[door.id] = door
    CDServer.save()
    CDServer.broadcast(door.id)

    if door.locked then
        CDServer.cancelTimer(door.id)
    else
        CDServer.scheduleAutoClose(door.id)
    end

    CDServer.notify(src, isNew and ('Lock created on "%s"'):format(name) or ('"%s" saved'):format(name), 'success')
    TriggerClientEvent('codedoors:client:refreshPanel', src)

    print(('[qb-codedoors] %s %s "%s" — %d door leaf/leaves'):format(
        GetPlayerName(src) or tostring(src),
        isNew and 'created' or 'updated',
        name, #leaves))
end)

--========================================================================
--  Delete
--========================================================================

RegisterNetEvent('codedoors:server:delete', function(id)
    local src = source
    if not requireAdmin(src) then return end
    if type(id) ~= 'string' or not CDServer.doors[id] then return end

    local name = CDServer.doors[id].name
    CDServer.cancelTimer(id)
    CDServer.doors[id] = nil
    CDServer.save()

    TriggerClientEvent('codedoors:client:sync', -1, id, nil)
    CDServer.notify(src, ('Lock on "%s" removed'):format(name), 'success')
    TriggerClientEvent('codedoors:client:refreshPanel', src)

    print(('[qb-codedoors] %s removed the lock on "%s"'):format(GetPlayerName(src) or tostring(src), name))
end)

--========================================================================
--  Quick lock / unlock from the panel
--========================================================================

RegisterNetEvent('codedoors:server:setLock', function(id, locked)
    local src = source
    if not requireAdmin(src) then return end
    if type(id) ~= 'string' or not CDServer.doors[id] then return end

    CDServer.setLocked(id, locked == true)
    TriggerClientEvent('codedoors:client:refreshPanel', src)
end)
