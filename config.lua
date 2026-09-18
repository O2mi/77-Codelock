--[[
    qb-codedoors — configuration
    ------------------------------------------------------------------
    A door lock script for QBCore that works on ANY door you can look
    at: single doors, double doors, sliding gates and garage doors.

    Locks are stored in doors.json and are managed from an in-game
    admin panel (command below). Admins create a lock by looking at
    the door. Players open a lock with a 4-digit code and, if they
    know the current code, they may change it.
------------------------------------------------------------------]]

Config = {}

-- ▸ Permissions ────────────────────────────────────────────────────
-- QBCore permission levels allowed to create / edit / delete locks.
Config.AdminPermissions = { 'admin', 'god', 'mod' }

-- Optional extra ACE permission, e.g. in server.cfg:
--   add_ace group.admin doorcode.admin allow
Config.AdminAce = 'doorcode.admin'

-- ▸ Commands & keys ────────────────────────────────────────────────
Config.PanelCommand  = 'doors'        -- open the management panel (admins)
Config.CreateCommand = 'doorcreate'   -- start the "look at a door" creator (admins)
Config.InteractKey   = 'E'            -- default key (players can rebind it in GTA settings)

-- ▸ Interaction ────────────────────────────────────────────────────
Config.InteractDistance = 4.0      -- how far away you may aim at a door
Config.SyncRange        = 100.0    -- players inside this range get the door applied
Config.ShowHud          = true     -- aim hint / door label
Config.HudNearbyRange   = 12.0     -- only look for doors to label when one is this close
Config.InteractInVehicle = true    -- allow using the keypad from inside a vehicle (garages)

-- ▸ Codes ──────────────────────────────────────────────────────────
Config.PinLength            = 4      -- 4-digit codes (changing this changes the UI keypad)
Config.PlayersCanChangeCode = true   -- a player who knows the current code may set a new one
Config.MaxAttempts          = 3      -- wrong codes before a short lockout (0 = no limit)
Config.AttemptCooldown      = 10     -- seconds of lockout after Config.MaxAttempts failures
Config.CodeDistance         = 6.0    -- max distance between the player and the door when sending a code

-- ▸ Closing / locking behaviour ────────────────────────────────────
Config.AutoCloseTime    = 30     -- default seconds an unlocked door stays open (0 = never)
Config.RelockAfterClose = true   -- lock the door again once it is fully closed
Config.CloseRetryTime   = 6000   -- ms — how long the client keeps pushing a door until it is fully shut
Config.MinAutoCloseTime = 5      -- limits for the per-door slider
Config.MaxAutoCloseTime = 300
Config.LockOnStartup    = true   -- every lock starts locked when the resource (re)starts
Config.KickOutOfDoorway = false  -- doors push players out of the doorway while closing (door system default)

-- ▸ Door types ─────────────────────────────────────────────────────
-- Each type is just a preset for the creator form; every value can be
-- changed per door in the admin panel.
--   auto     : sliding / rolling door. The game animates it (gates, garage doors).
--   holdOpen : stays open while it is unlocked (typical for gates & garages).
--   rate     : automatic closing rate pushed to the door system
--              (nil = leave the game default, 10.0 = swinging door that shuts promptly).
Config.DoorTypes = {
    door   = { label = 'Single Door',  auto = false, holdOpen = false, rate = 10.0 },
    double = { label = 'Double Door',  auto = false, holdOpen = false, rate = 10.0 },
    gate   = { label = 'Gate',         auto = true,  holdOpen = true },
    garage = { label = 'Garage Door',  auto = true,  holdOpen = true },
}

Config.Defaults = {
    type      = 'door',
    autoClose = Config.AutoCloseTime, -- seconds
    distance  = 2.5,                  -- interaction radius of the door
}

-- ▸ Storage ────────────────────────────────────────────────────────
Config.SaveFile = 'doors.json'   -- inside the resource folder (v1 saves are migrated)
Config.MaxDoors = 750            -- safety cap
Config.Debug    = false

-- ▸ Shared helper ──────────────────────────────────────────────────
-- Fallback hash for doors the game has not registered in its own door
-- system (map / MLO doors). It must resolve to the same value on the
-- client and on the server, hence the integer-only formatting.
function Config.aliasHash(model, coords)
    return joaat(('qbcd_%d_%d_%d_%d'):format(
        math.floor((tonumber(model) or 0) + 0.5),
        math.floor((tonumber(coords.x) or 0.0) * 100 + 0.5),
        math.floor((tonumber(coords.y) or 0.0) * 100 + 0.5),
        math.floor((tonumber(coords.z) or 0.0) * 100 + 0.5)))
end
