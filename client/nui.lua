--[[
    qb-codedoors · NUI bridge
    ------------------------------------------------------------------
    Everything that talks to html/index.html lives here:
    focus handling, keypad, admin panel and the admin CRUD events.
------------------------------------------------------------------]]

local QBCore = exports['qb-core']:GetCoreObject()

CD.panelOpen     = CD.panelOpen or false
CD.keypadDoor    = nil
CD.lastHeartbeat = 0
CD.nuiReady      = false   -- the interface answered at least once
CD.uiOpenedAt    = 0       -- when focus was handed to the interface

local refreshQueued = false

--========================================================================
--  Lua -> NUI
--========================================================================

function CD.send(data)
    if type(data) ~= 'table' then return end
    SendNUIMessage(data)
end

function CD.setUi(open)
    CD.uiOpen = open and true or false
    SetNuiFocus(CD.uiOpen, CD.uiOpen)
    SetNuiFocusKeepInput(false)
    if CD.uiOpen then
        CD.uiOpenedAt = GetGameTimer()
    else
        CD.panelOpen = false
        CD.keypadDoor = nil
    end
end

function CD.closeUi()
    CD.panelOpen = false
    CD.keypadDoor = nil
    CD.setUi(false)
    CD.send({ action = 'close' })
end

--========================================================================
--  Keypad (every player)
--========================================================================

function CD.openKeypad(door, mode)
    if not door then return end
    CD.panelOpen = false
    CD.keypadDoor = door.id
    CD.setUi(true)
    CD.send({
        action = 'keypad',
        mode   = mode or 'unlock',
        door   = {
            id     = door.id,
            name   = door.name,
            type   = door.type,
            locked = door.locked and true or false,
            zone   = door.zone,
        },
        config = {
            pinLength = Config.PinLength,
            canChange = Config.PlayersCanChangeCode and true or false,
        },
    })
end

--========================================================================
--  Admin panel
--========================================================================

local function panelPayload(list, view, draft)
    return {
        action = 'openPanel',
        view   = view or 'list',
        draft  = draft,
        doors  = list,
        meta   = {
            total   = #list,
            locked  = (function()
                local n = 0
                for i = 1, #list do if list[i].locked then n = n + 1 end end
                return n
            end)(),
            types       = Config.DoorTypes,
            pinLength   = Config.PinLength,
            minAutoClose = Config.MinAutoCloseTime,
            maxAutoClose = Config.MaxAutoCloseTime,
            defaults    = Config.Defaults,
        },
    }
end

function CD.refreshPanel()
    if not CD.panelOpen or refreshQueued then return end
    refreshQueued = true
    SetTimeout(400, function() refreshQueued = false end)
    QBCore.Functions.TriggerCallback('codedoors:server:list', function(list)
        if type(list) == 'table' and CD.panelOpen then
            CD.send({ action = 'doors', doors = list })
        end
    end)
end

function CD.openPanel(view, draft)
    QBCore.Functions.TriggerCallback('codedoors:server:list', function(list)
        if type(list) ~= 'table' then
            CD.notify('You are not allowed to manage door locks', 'error')
            return
        end
        CD.panelOpen = true
        CD.setUi(true)
        CD.send(panelPayload(list, view, draft))
    end)
end

--========================================================================
--  NUI callbacks — player
--========================================================================

RegisterNUICallback('ready', function(_, cb)
    CD.nuiReady = true
    CD.lastHeartbeat = GetGameTimer()
    cb('ok')
end)

RegisterNUICallback('heartbeat', function(_, cb)
    CD.lastHeartbeat = GetGameTimer()
    cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
    CD.closeUi()
    cb('ok')
end)

RegisterNUICallback('submitCode', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or not data.id then return end
    TriggerServerEvent('codedoors:server:code',
        tostring(data.id),
        tostring(data.code or ''),
        tostring(data.mode or 'unlock'),
        data.newCode and tostring(data.newCode) or nil)
end)

--========================================================================
--  NUI callbacks — admin
--========================================================================

RegisterNUICallback('adminSave', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' then return end

    local doors = {}
    if type(data.doors) == 'table' then
        for i = 1, math.min(#data.doors, 4) do
            local d = data.doors[i]
            if type(d) == 'table' and d.coords then
                doors[i] = {
                    hash    = tonumber(d.hash) or 0,
                    model   = tonumber(d.model) or 0,
                    name    = tostring(d.name or ''),
                    coords  = { x = tonumber(d.coords.x) or 0.0, y = tonumber(d.coords.y) or 0.0, z = tonumber(d.coords.z) or 0.0 },
                    heading = tonumber(d.heading) or 0.0,
                }
            end
        end
    end

    TriggerServerEvent('codedoors:server:save', {
        id        = data.id and tostring(data.id) or nil,
        name      = tostring(data.name or ''),
        type      = tostring(data.type or Config.Defaults.type),
        pin       = tostring(data.pin or ''),
        autoClose = tonumber(data.autoClose) or Config.Defaults.autoClose,
        distance  = tonumber(data.distance) or Config.Defaults.distance,
        auto      = data.auto and true or false,
        holdOpen  = data.holdOpen and true or false,
        zone      = data.zone and tostring(data.zone) or nil,
        doors     = doors,
    })
end)

RegisterNUICallback('adminDelete', function(data, cb)
    cb('ok')
    if type(data) == 'table' and data.id then
        TriggerServerEvent('codedoors:server:delete', tostring(data.id))
    end
end)

RegisterNUICallback('adminSetLock', function(data, cb)
    cb('ok')
    if type(data) == 'table' and data.id then
        TriggerServerEvent('codedoors:server:setLock', tostring(data.id), data.locked and true or false)
    end
end)

RegisterNUICallback('adminStartCapture', function(data, cb)
    cb('ok')
    data = type(data) == 'table' and data or {}
    CD.startCreator({ id = data.id and tostring(data.id) or nil, doors = data.doors })
end)

RegisterNUICallback('adminNewDoor', function(_, cb)
    cb('ok')
    CD.startCreator({})
end)

RegisterNUICallback('adminRefresh', function(_, cb)
    cb('ok')
    CD.refreshPanel()
end)

RegisterNUICallback('adminTeleport', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or not data.coords then return end
    local c = data.coords
    CD.closeUi()
    local ped = PlayerPedId()
    SetEntityCoords(ped,
        (tonumber(c.x) or 0.0) + 0.75,
        (tonumber(c.y) or 0.0) + 0.75,
        (tonumber(c.z) or 0.0) + 0.25,
        false, false, false, false)
    if data.heading then
        SetEntityHeading(ped, (tonumber(data.heading) or 0.0) + 180.0)
    end
end)

--========================================================================
--  Failsafes
--========================================================================

-- Handshake with the page: the interface needs to know the resource name
-- to send callbacks back (the folder name is whatever you called it), and
-- this also tells us the interface is alive.
CreateThread(function()
    for _ = 1, 40 do
        if CD.nuiReady then break end
        CD.send({ action = 'init', resource = GetCurrentResourceName() })
        Wait(500)
    end
end)

-- Close the keypad when the player walks away from the door
CreateThread(function()
    while true do
        Wait(1000)
        if CD.uiOpen and CD.keypadDoor then
            local door = CD.doorById(CD.keypadDoor)
            if not door or CD.distanceTo(door) > Config.CodeDistance + 3.0 then
                CD.closeUi()
            end
        end
    end
end)

-- Release the mouse if the interface never answers, or stops answering.
-- Without this a broken page would leave the cursor captured forever.
CreateThread(function()
    while true do
        Wait(2000)
        if CD.uiOpen then
            local idle = GetGameTimer() - CD.uiOpenedAt

            if not CD.nuiReady and idle > 6000 then
                print('[qb-codedoors] the interface never answered — releasing the mouse')
                CD.closeUi()
            elseif CD.nuiReady and CD.lastHeartbeat > 0
                and (GetGameTimer() - CD.lastHeartbeat) > 8000 then
                print('[qb-codedoors] the interface stopped responding — releasing the mouse')
                CD.closeUi()
                CD.lastHeartbeat = 0
            end
        end
    end
end)
