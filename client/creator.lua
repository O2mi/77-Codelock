--[[
    qb-codedoors · door creator
    ------------------------------------------------------------------
    The admin looks at a door and selects it. Several doors (a double
    door, a gate pair, a garage with two roll-ups, ...) can be added to
    one lock. When the selection is done the management panel opens
    with the form pre-filled.
------------------------------------------------------------------]]

local MAX_LEAVES = 4

local leaves = {}     -- captured door leaves
local editId = nil    -- id of the door lock being edited (nil = new lock)
local stage  = 'select'

local function marker(coords, r, g, b, scale, alpha)
    DrawMarker(28, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        scale, scale, scale, r, g, b, alpha or 110,
        false, true, 2, false, nil, nil, false)
    DrawMarker(1, coords.x, coords.y, coords.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        scale * 0.72, scale * 0.72, 0.9, r, g, b, 40,
        false, true, 2, false, nil, nil, false)
end

local function hud(aimInfo)
    local title, hint
    if stage == 'select' then
        title = editId and 'Add doors to this lock' or 'New door lock'
        hint  = 'Look at a door  ·  [E] select  ·  [BACKSPACE] cancel'
        if aimInfo then
            title = aimInfo.name or ('model ' .. tostring(aimInfo.model))
        end
    else
        title = ('%d door%s captured'):format(#leaves, #leaves == 1 and '' or 's')
        hint  = '[E] add another door  ·  [ENTER] continue  ·  [BACKSPACE] undo'
    end

    local rows = math.max(#leaves, 1)
    local height = 0.070 + rows * 0.019
    local y = 0.855
    local top = y - height / 2

    DrawRect(0.5, y, 0.26, height, 10, 12, 17, 216)
    DrawRect(0.5, top, 0.26, 0.002, 79, 140, 255, 130)

    CD.drawText('DOOR LOCK CREATOR', 0.5, top + 0.010, 0.24, { 79, 140, 255, 235 }, true)
    CD.drawText(title, 0.5, top + 0.030, 0.34, { 255, 255, 255, 240 }, true)
    CD.drawText(hint, 0.5, top + 0.048, 0.25, { 150, 165, 200, 225 }, true)

    for i = 1, #leaves do
        local leaf = leaves[i]
        CD.drawText(('%d  ·  %s'):format(i, leaf.name or ('model ' .. tostring(leaf.model))),
            0.5, top + 0.062 + (i - 1) * 0.019, 0.25, { 46, 230, 168, 230 }, true)
    end
end

local function isCaptured(info)
    for i = 1, #leaves do
        local leaf = leaves[i]
        if leaf.hash == info.hash then return true end
        local c = leaf.coords
        if math.abs(c.x - info.coords.x) < 0.05
            and math.abs(c.y - info.coords.y) < 0.05
            and math.abs(c.z - info.coords.z) < 0.05 then
            return true
        end
    end
    return false
end

local function finish()
    CD.creatorActive = false

    local x, y, z = 0.0, 0.0, 0.0
    local draft = { id = editId, doors = {} }

    for i = 1, #leaves do
        local leaf = leaves[i]
        x, y, z = x + leaf.coords.x, y + leaf.coords.y, z + leaf.coords.z
        draft.doors[i] = {
            hash    = leaf.hash,
            model   = leaf.model,
            name    = leaf.name,
            coords  = { x = leaf.coords.x + 0.0, y = leaf.coords.y + 0.0, z = leaf.coords.z + 0.0 },
            heading = leaf.heading + 0.0,
        }
    end

    if #draft.doors == 0 then
        CD.openPanel('list')
        return
    end

    local n = #draft.doors
    draft.zone = GetLabelText(GetNameOfZone(x / n, y / n, z / n))
    CD.openPanel(editId and 'edit' or 'create', draft)
end

function CD.startCreator(options)
    if CD.creatorActive then return end
    options = options or {}

    CD.closeUi()
    CD.creatorActive = true
    editId = options.id or nil
    leaves = {}

    -- editing an existing lock: start from the doors it already has
    if options.doors then
        for i = 1, math.min(#options.doors, MAX_LEAVES) do
            local d = options.doors[i]
            leaves[i] = {
                hash    = tonumber(d.hash) or d.hash,
                model   = tonumber(d.model) or d.model,
                name    = d.name,
                coords  = { x = d.coords.x + 0.0, y = d.coords.y + 0.0, z = d.coords.z + 0.0 },
                heading = (tonumber(d.heading) or 0.0) + 0.0,
            }
        end
    end

    if options.first then leaves[#leaves + 1] = options.first end
    stage = #leaves > 0 and 'link' or 'select'

    CreateThread(function()
        while CD.creatorActive do
            Wait(0)

            -- no shooting / aiming while picking doors
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)

            local hit, coords, entity = CD.raycast()
            local info = hit and CD.resolveDoor(entity, coords) or nil
            if info and isCaptured(info) then info = nil end

            -- markers: green for captured doors, blue for the one under the crosshair
            for i = 1, #leaves do
                marker(CD.v3(leaves[i].coords), 46, 230, 168, 0.26)
            end
            if info then
                marker(CD.v3(info.coords), 79, 140, 255, 0.32, 150)
            end

            hud(info)

            if IsControlJustReleased(0, 177) then                        -- backspace
                if #leaves > 0 then
                    table.remove(leaves)
                    stage = #leaves > 0 and 'link' or 'select'
                else
                    CD.creatorActive = false
                end
            elseif IsControlJustReleased(0, 191) and #leaves > 0 then    -- enter
                finish()
            elseif IsControlJustReleased(0, 38) and info then            -- E
                if #leaves >= MAX_LEAVES then
                    CD.toast('warning', ('A lock can hold %d doors at most'):format(MAX_LEAVES))
                else
                    leaves[#leaves + 1] = info
                    stage = 'link'
                end
            end
        end
    end)
end
