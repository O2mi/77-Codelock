--[[
    qb-codedoors · client core
    ------------------------------------------------------------------
    Every lock is applied through GTA's native door system
    (DoorSystemSetDoorState & friends), which is what makes doors,
    double doors, sliding gates and garage doors lock and shut
    properly - no entity freezing hacks.

    Shared client namespace: CD   (used by creator.lua and nui.lua)
------------------------------------------------------------------]]

local QBCore = exports['qb-core']:GetCoreObject()

CD = CD or {}

CD.doors         = {}     -- id -> door data (never contains the pin)
CD.applied       = {}     -- id -> state we last pushed to the door system (1 locked / 0 unlocked)
CD.closing       = {}     -- id -> true while a force-close thread is running
CD.aimed         = nil    -- door currently under the crosshair
CD.uiOpen        = false  -- NUI has focus
CD.panelOpen     = false  -- admin panel is the open view
CD.creatorActive = false  -- "look at a door" capture flow running
CD.isAdmin       = false

--========================================================================
--  Small helpers
--========================================================================

function CD.v3(c) return vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end

function CD.log(...)
    if Config.Debug then print('[qb-codedoors]', ...) end
end

function CD.notify(message, kind)
    QBCore.Functions.Notify(message, kind or 'primary')
end

function CD.toast(kind, message)
    QBCore.Functions.Notify(message, kind or 'primary')
    if CD.uiOpen then CD.send({ action = 'toast', kind = kind, message = message }) end
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

-- archetype (model) name of an entity, nil when the game will not tell us
local function archetypeName(entity)
    local ok, name = pcall(GetEntityArchetypeName, entity)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return nil
end
CD.doorCenter = doorCenter

-- distance from the player to the nearest leaf of a door
function CD.distanceTo(door, coords)
    local ped = coords or GetEntityCoords(PlayerPedId())
    local best = 9999.0
    for i = 1, #door.doors do
        local d = #(ped - CD.v3(door.doors[i].coords))
        if d < best then best = d end
    end
    return best
end

function CD.doorById(id)
    if type(id) ~= 'string' then return nil end
    return CD.doors[id]
end

function CD.hasDoorNearby(coords, range)
    for _, door in pairs(CD.doors) do
        if CD.distanceTo(door, coords) <= range then return true end
    end
    return false
end

--========================================================================
--  Aim detection
--========================================================================

local function rotationToDirection(rot)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cosx = math.abs(math.cos(rx))
    return vector3(-math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx))
end

-- Returns hit, hitCoords, entity
function CD.raycast(distance)
    local cam = GetGameplayCamCoord()
    local dir = rotationToDirection(GetGameplayCamRot(2))
    local dest = cam + dir * (distance or Config.InteractDistance)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, 17, PlayerPedId(), 7)
    local _, hit, coords, _, entity = GetShapeTestResult(handle)
    return hit == 1, coords, entity or 0
end

-- Turn the object we are looking at into door data (hash / model / coords).
-- Returns nil when the object cannot be used as a door.
function CD.resolveDoor(entity, hitCoords)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        -- The ray hit the map mesh (some interior doors are not entities).
        -- Grab the closest object next to the impact point instead.
        if not hitCoords then return nil end
        local best, bestDist = 0, 2.0
        for _, obj in ipairs(GetGamePool('CObject')) do
            if DoesEntityExist(obj) then
                local d = #(GetEntityCoords(obj) - CD.v3(hitCoords))
                if d < bestDist then best, bestDist = obj, d end
            end
        end
        entity = best
        if entity == 0 then return nil end
    end

    if not (IsEntityAnObject(entity) or IsEntityAVehicle(entity)) then return nil end

    local model = GetEntityModel(entity)
    if not model or model == 0 then return nil end

    local coords = GetEntityCoords(entity)

    -- The door system usually knows the door already; that hash is unique
    -- per door object (identical models stay independent). When it does not
    -- (map / MLO doors registered later), fall back to our own stable hash.
    local hash = DoorSystemFindExistingDoor(coords.x, coords.y, coords.z, model)
    local source = 'system'
    if not hash or hash == 0 then
        hash = Config.aliasHash(model, coords)
        source = 'alias'
    end

    return {
        hash   = hash,
        model  = model,
        source = source,
        name   = archetypeName(entity),
        coords = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 },
        heading = GetEntityHeading(entity) + 0.0,
    }
end

-- Which registered lock am I aiming at?
function CD.findDoorFromAim(entity, hitCoords)
    local pcoords = GetEntityCoords(PlayerPedId())

    -- 1) exact leaf hash match (fast path)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        local ecoords = GetEntityCoords(entity)
        local hash = DoorSystemFindExistingDoor(ecoords.x, ecoords.y, ecoords.z, GetEntityModel(entity))
        if hash and hash ~= 0 then
            for _, door in pairs(CD.doors) do
                for i = 1, #door.doors do
                    if door.doors[i].hash == hash and CD.distanceTo(door, pcoords) <= Config.InteractDistance + 2.0 then
                        return door
                    end
                end
            end
        end
    end

    -- 2) proximity of the impact point to a door leaf
    if not hitCoords then return nil end
    local hitPos = CD.v3(hitCoords)
    local best, bestDist
    for _, door in pairs(CD.doors) do
        if CD.distanceTo(door, pcoords) <= Config.InteractDistance + 6.0 then
            local limit = (door.distance or Config.Defaults.distance) + 1.25
            for i = 1, #door.doors do
                local d = #(hitPos - CD.v3(door.doors[i].coords))
                if d <= limit and (not bestDist or d < bestDist) then
                    best, bestDist = door, d
                end
            end
        end
    end
    return best
end

--========================================================================
--  Applying lock state through the door system
--========================================================================

local function ensureRegistered(leaf)
    if IsDoorRegisteredWithSystem(leaf.hash) then return true end
    local now = GetGameTimer()
    if leaf.registerAt and now - leaf.registerAt < 2000 then return false end
    leaf.registerAt = now
    AddDoorToSystem(leaf.hash, leaf.model, leaf.coords.x, leaf.coords.y, leaf.coords.z, false, false, false)
    return IsDoorRegisteredWithSystem(leaf.hash)
end
CD.ensureRegistered = ensureRegistered

local function pushState(door, state)
    local applied = false
    -- on the first apply of a (re)loaded door we clear whatever forced state
    -- the door was left in, afterwards only the wanted state is pushed
    local reset = not door.resetDone
    door.resetDone = true

    for i = 1, #door.doors do
        local leaf = door.doors[i]
        ensureRegistered(leaf)
        if DoorSystemGetIsPhysicsLoaded(leaf.hash) then
            if reset then
                DoorSystemSetDoorState(leaf.hash, 4, false, false)
            end
            DoorSystemSetDoorState(leaf.hash, state, false, false)    -- 1 = locked, 0 = unlocked
            if door.holdOpen then
                DoorSystemSetHoldOpen(leaf.hash, state == 0)
            end
            if door.rate or not door.auto then
                DoorSystemSetAutomaticRate(leaf.hash, door.rate or 10.0, false, false)
            end
            applied = true
        end
    end
    return applied
end

function CD.applyDoor(door)
    local state = door.locked and 1 or 0
    if pushState(door, state) then
        CD.applied[door.id] = state
    end
    if not door.locked then door.closeTries = nil end
end

-- Keep pushing the leaves of a door shut until they really are closed,
-- so a door is never left half open.
function CD.forceClose(door)
    if not door or CD.closing[door.id] then return end
    -- give up on doors that refuse to report as closed (keeps the loop light)
    local tries = door.closeTries or 0
    if tries >= 5 then return end
    door.closeTries = tries + 1
    CD.closing[door.id] = true
    CreateThread(function()
        local start, deadline = GetGameTimer(), GetGameTimer() + Config.CloseRetryTime
        while GetGameTimer() < deadline do
            local allClosed = true
            for i = 1, #door.doors do
                local leaf = door.doors[i]
                if DoorSystemGetIsPhysicsLoaded(leaf.hash) and not IsDoorClosed(leaf.hash) then
                    allClosed = false
                    local hard = (GetGameTimer() - start) > 1500
                    DoorSystemSetDoorState(leaf.hash, 4, false, true)
                    if hard then DoorSystemSetDoorState(leaf.hash, 6, false, true) end -- force closed
                    DoorSystemSetDoorState(leaf.hash, door.locked and 1 or 0, false, true)
                end
            end
            if allClosed then break end
            Wait(200)
        end
        CD.closing[door.id] = nil
    end)
end

--========================================================================
--  Server sync
--========================================================================

local function requestSync()
    TriggerServerEvent('codedoors:server:request')
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CD.isAdmin = false
    requestSync()
end)

-- also sync when the resource is (re)started while we are already playing
CreateThread(function()
    Wait(2500)
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    requestSync()
end)

RegisterNetEvent('codedoors:client:sync', function(id, data)
    if type(id) ~= 'string' then return end
    if data == nil then
        CD.doors[id] = nil
        CD.applied[id] = nil
        if CD.panelOpen then CD.refreshPanel() end
        return
    end
    data.closeTries = nil
    CD.doors[id] = data
    CD.applyDoor(data)
    if CD.panelOpen then CD.refreshPanel() end
end)

RegisterNetEvent('codedoors:client:closeDoor', function(id)
    local door = CD.doorById(id)
    if door then CD.forceClose(door) end
end)

RegisterNetEvent('codedoors:client:admin', function(state)
    CD.isAdmin = state and true or false
end)

RegisterNetEvent('codedoors:client:toast', function(kind, message)
    CD.toast(kind, message)
end)

RegisterNetEvent('codedoors:client:keypadResult', function(success, message)
    if CD.uiOpen then
        CD.send({ action = 'keypadResult', success = success and true or false, message = message })
    end
    if success and not CD.uiOpen then CD.notify(message or 'Unlocked', 'success') end
end)

RegisterNetEvent('codedoors:client:refreshPanel', function()
    if CD.panelOpen then CD.refreshPanel() end
end)

--========================================================================
--  Maintenance loop
--  Re-applies locks for nearby doors: catches doors that streamed in,
--  locks that changed while we were away and doors left ajar.
--========================================================================

CreateThread(function()
    while true do
        Wait(750)
        local pcoords = GetEntityCoords(PlayerPedId())

        for id, door in pairs(CD.doors) do
            if CD.distanceTo(door, pcoords) <= Config.SyncRange then
                local desired = door.locked and 1 or 0
                local needsWork = CD.applied[id] ~= desired
                for i = 1, #door.doors do
                    local leaf = door.doors[i]
                    if not IsDoorRegisteredWithSystem(leaf.hash) then needsWork = true end
                    if DoorSystemGetIsPhysicsLoaded(leaf.hash) then
                        if door.locked and not IsDoorClosed(leaf.hash) then needsWork = true end
                    end
                end
                if needsWork then
                    CD.applyDoor(door)
                    if door.locked then CD.forceClose(door) end
                end
            end
        end
    end
end)

--========================================================================
--  Aim HUD
--========================================================================

local function drawText(text, x, y, scale, colour, centre)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(colour[1], colour[2], colour[3], colour[4] or 255)
    SetTextCentre(centre and true or false)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

CD.drawText = drawText

local function drawHud(door)
    local locked = door.locked
    local accent = locked and { 255, 84, 112 } or { 46, 230, 168 }
    local hint = locked
        and ('Press [%s] to enter the code'):format(Config.InteractKey)
        or ('Press [%s] to lock it again'):format(Config.InteractKey)

    -- background panel
    DrawRect(0.5, 0.885, 0.20, 0.062, 10, 12, 17, 205)
    DrawRect(0.402, 0.885, 0.004, 0.062, accent[1], accent[2], accent[3], 255)
    DrawRect(0.5, 0.856, 0.20, 0.002, accent[1], accent[2], accent[3], 90)

    drawText(door.name or 'Door', 0.5, 0.868, 0.42, { 255, 255, 255, 235 }, true)
    drawText(('%s  ·  %s'):format(locked and 'LOCKED' or 'UNLOCKED', hint),
        0.5, 0.898, 0.30, { locked and 255 or 200, locked and 130 or 235, locked and 150 or 210, 200 }, true)
end

CreateThread(function()
    while true do
        local sleep = 400
        if Config.ShowHud and not CD.uiOpen and not CD.creatorActive then
            local pcoords = GetEntityCoords(PlayerPedId())
            if CD.hasDoorNearby(pcoords, Config.HudNearbyRange) then
                sleep = 0
                local hit, coords, entity = CD.raycast()
                CD.aimed = hit and CD.findDoorFromAim(entity, coords) or nil
                if CD.aimed then drawHud(CD.aimed) end
            else
                CD.aimed = nil
            end
        else
            CD.aimed = nil
        end
        Wait(sleep)
    end
end)

--========================================================================
--  Interaction
--========================================================================

function CD.interact()
    if CD.uiOpen or CD.creatorActive then return end
    if not Config.InteractInVehicle and IsPedInAnyVehicle(PlayerPedId(), false) then return end

    local hit, coords, entity = CD.raycast()
    if not hit then return end

    local door = CD.findDoorFromAim(entity, coords)
    if door then
        if door.locked then
            CD.openKeypad(door, 'unlock')
        else
            TriggerServerEvent('codedoors:server:lock', door.id)
        end
        return
    end

    -- Admins can start a new lock straight from the door they are looking at
    if CD.isAdmin then
        local info = CD.resolveDoor(entity, coords)
        if info then
            CD.startCreator({ first = info })
        end
    end
end

RegisterCommand('+codedoor', function() CD.interact() end, false)
RegisterCommand('-codedoor', function() end, false)
RegisterKeyMapping('+codedoor', 'Door locks — use the door you are aiming at', 'keyboard', Config.InteractKey)

RegisterCommand(Config.CreateCommand, function()
    if not CD.isAdmin then
        CD.notify('You are not allowed to create door locks', 'error')
        return
    end
    CD.startCreator({})
end, false)

RegisterCommand(Config.PanelCommand, function()
    CD.openPanel('list')
end, false)

--========================================================================
--  NUI focus handling
--========================================================================

CreateThread(function()
    while true do
        if CD.uiOpen and not CD.creatorActive then
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
            Wait(0)
        else
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
