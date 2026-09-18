# 77-codedoors

Aim-based **4-digit code door locks** for **QBCore** — single doors, double doors, sliding gates and
garage doors, all managed from an in-game admin panel.

You never type coordinates or door indexes: you **look at the door and press `E`**.

---

## Features

| | |
|---|---|
| 🎯 **Aim to create** | Look at any door and select it. Up to **4 door leaves** can share one lock (both halves of a double door, gate pairs, a garage with several roll-ups). |
| 🔢 **4-digit code** | Checked **on the server**. Codes are never sent to a client unless that client is an admin. |
| 🚪 **Every door type** | Single door, double, gate and garage door presets (sliding/rolling doors are handled as automatic doors, so they open and shut properly). |
| ⏲️ **Auto close** | After unlocking, the lock **closes itself again** (30s by default, per-door slider). A door left ajar is pushed shut until it is fully closed — never half open. |
| 🛡️ **Admin only** | Creating, editing and deleting is admin-only and re-checked on the server for every request. |
| 🔑 **Players can change the code** | Enter the current code in the keypad → *Change code* → new code → repeat. Optional (`Config.PlayersCanChangeCode`). |
| 🧊 **Proper locking** | Uses GTA's native door system — no entity freezing, no fake doors, so MLO doors, gates and garage doors behave normally. |
| 💾 **Persistent** | Saved to `doors.json` inside the resource and reloaded on restart. Saves from the older version of this resource are migrated automatically. |
| 🎨 **Real UI** | Dark management panel (search, filters, reveal codes, lock toggle, teleport, edit, delete) plus a keypad for players. |

---

## Installation

1. Put the resource folder in your server's `resources` folder (this delivery is named `codelock`).
2. Add it to `server.cfg` **after** `qb-core` — `ensure` uses the **folder name**:

   ```cfg
   ensure codelock
   ```

3. Make sure you are an admin — either with QBCore permissions (`admin`, `god`, `mod` — see
   `Config.AdminPermissions`) or with an ACE:

   ```cfg
   add_ace group.admin doorcode.admin allow
   add_principal identifier.license:YOUR_LICENSE group.admin
   ```

4. **Important:** remove/disable any other doorlock resource that manages the same doors
   (`qb-doorlock`, `esx_doorlock`, `ox_doorlock`, …). Two scripts writing door states will fight and
   the door will flicker or refuse to lock.

---

## For admins

| Command | What it does |
|---|---|
| `/doors` | Opens the management panel (door list, codes, lock toggles, edit, delete, teleport). |
| `/doorcreate` | Starts the "look at a door" creator. |
| Aim at an unregistered door + `E` | Also starts the creator straight away. |

**In the creator**

| Key | Action |
|---|---|
| `E` | Select the door you are looking at / add another door to the same lock |
| `Enter` | Finish and open the form |
| `Backspace` | Remove the last selected door (or cancel when nothing is selected) |

Then fill in the form: **name**, **door type**, **4-digit code**, **auto close** seconds, **use
distance** and the two behaviour switches. `Save lock` writes it immediately (new locks start locked).

**Behind the eye icon** in the list you can reveal a code. `Go to door` teleports you to it.
Deleting asks for a second click.

---

## For players

1. Aim at a locked door and press **`E`** → the keypad opens.
2. Type the **4-digit code** → the door unlocks for everyone and **closes + locks itself again** after
   the configured timer.
3. Aim at an already unlocked door and press `E` to lock it straight away (no code needed).
4. Know the code and want to change it? Keypad → **Change code** → current code → new code → repeat.
   You need the current code; this can be turned off in the config.

**Rebinding:** `E` is registered as a FiveM key mapping
(*GTA Settings → Key Bindings → FiveM → "Door locks — use the door you are aiming at"*).
The creator keys (`E` / `Enter` / `Backspace`) are fixed.

---

## Configuration (`config.lua`)

| Option | Default | Description |
|---|---|---|
| `Config.AdminPermissions` | `{ 'admin', 'god', 'mod' }` | QBCore permissions allowed to manage locks. |
| `Config.AdminAce` | `'doorcode.admin'` | Optional extra ACE permission. |
| `Config.PanelCommand` | `'doors'` | Admin panel command. |
| `Config.CreateCommand` | `'doorcreate'` | Creator command. |
| `Config.InteractKey` | `'E'` | Default key for using the door you aim at. |
| `Config.InteractDistance` | `4.0` | How far away you may aim at a door. |
| `Config.SyncRange` | `100.0` | Players within this range receive and apply the door. |
| `Config.ShowHud` | `true` | Lock state + hint while aiming at a door. |
| `Config.InteractInVehicle` | `true` | Allow using a garage door keypad from a vehicle. |
| `Config.PinLength` | `4` | Code length (the keypad follows this). |
| `Config.PlayersCanChangeCode` | `true` | Let players who know the code replace it. |
| `Config.MaxAttempts` / `Config.AttemptCooldown` | `3` / `10` | Wrong codes before a short lockout. |
| `Config.CodeDistance` | `6.0` | Max distance between player and door when submitting a code. |
| `Config.AutoCloseTime` | `30` | Default auto-close/relock seconds for new locks (`0` = never). |
| `Config.RelockAfterClose` | `true` | Lock the door again once it is fully closed. |
| `Config.CloseRetryTime` | `6000` | How long the client keeps pushing a door shut. |
| `Config.LockOnStartup` | `true` | Every lock starts locked when the resource restarts. |
| `Config.DoorTypes` | — | The presets behind the four door types. |
| `Config.SaveFile` | `'doors.json'` | Where locks are stored. |

---

## How it works (technical)

* Locking uses GTA's door system: `DoorSystemSetDoorState(hash, 4)` to clear a stuck forced state,
  then `1` (locked) or `0` (unlocked), `DoorSystemSetHoldOpen` so gates/garage doors stay open while
  unlocked, and `DoorSystemSetAutomaticRate` so swinging doors shut promptly instead of staying ajar.
* The hash stored per door leaf comes from `DoorSystemFindExistingDoor`, i.e. the game's own door
  object hash (two doors with the same model stay independent). When the game has not registered the
  door, a stable hash is generated from the model + position and the door is added to the door system
  with `AddDoorToSystem`.
* **Auto close** is a server timer: when it fires, the new state is broadcast and every client keeps
  pushing the leaves of that door shut (`DoorSystemSetDoorState` + `IsDoorClosed`) for
  `Config.CloseRetryTime` — that is why a door can never be left half open.
* Doors near a player are re-applied by a maintenance loop (catches streamed-in doors, changes made
  while away, and doors left ajar), and all players get a full resync every 10 seconds.
* **Security:** codes are only compared server-side. `codedoors:server:list` (the only event that
  contains codes) requires an admin, all admin events re-check the permission, and every code request
  is distance-checked and rate-limited.

### Files

```
qb-codedoors/
├── fxmanifest.lua
├── config.lua                 ← everything you may want to change
├── doors.json                 ← created on the first save
├── client/
│   ├── main.lua               door system handling, aim HUD, interaction
│   ├── creator.lua            the "look at a door" selection flow
│   └── nui.lua                keypad + admin panel bridge, NUI callbacks
├── server/
│   ├── main.lua               storage, syncing, codes, auto close
│   └── admin.lua              permissions and create/edit/delete
└── html/                      the interface (index.html, style.css, script.js)
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `E` does nothing | Another doorlock resource is handling the door, or you are not an admin (`Config.AdminPermissions`). Check the server console for `[qb-codedoors] N door lock(s) loaded`. |
| The door unlocks but does not open | Normal for a swinging door — walk into it. Gates/garage doors open by themselves once unlocked. |
| A door will not lock at all | The object you selected is not a real door in the game's door system (a mesh or decoration). Aim directly at the door leaf and capture it again; the creator prefers the game's own door hash. |
| Two different doors with the same model lock together | Re-create the lock with the *Look at doors* flow so the game's per-object hash is used. |
| The lock is gone after a restart | `doors.json` could not be written — the resource folder must be writable by the server user. |
| Mouse cursor stays on screen after closing the UI | The UI answers the client through `https://<folder name>/close`. The page resolves the folder name at runtime (see `resourceName` in `html/script.js`) — keep that logic if you edit the file. As a last resort the client releases the mouse by itself after a few seconds. |
| Nothing is saved / the lock list stays empty | The UI could not deliver the save to the script. With `Config.Debug = true` the server console prints `[qb-codedoors] <player> created "…"` — if that line never shows up, the page cannot reach the script (see the mouse-cursor row above). |

---

## Credits / notes

Door states used: `0 UNLOCKED`, `1 LOCKED`, `4 FORCE_LOCKED_THIS_FRAME`, `6 FORCE_CLOSED_THIS_FRAME`
(see the [FiveM native reference](https://docs.fivem.net/natives/?_0x6BAB9442830C7F53)).


---
## Photo
*  /doors [you can tp or change code or see or delete ] *
<img width="1023" height="681" alt="image" src="https://github.com/user-attachments/assets/2550e2e8-7c08-41d6-adf7-ff2be8ffac9e" />
*  press E at any door hust by looking  *
<img width="2560" height="1440" alt="FiveM FiveM exe Screenshot 2026 09 18 - 17 42 48 99" src="https://github.com/user-attachments/assets/ae56454d-0623-494c-8626-aecdf6294ebd" />
*  put code and name for the playes to see and save  *
<img width="2560" height="1440" alt="FiveM FiveM exe Screenshot 2026 09 18 - 17 42 54 75" src="https://github.com/user-attachments/assets/358f7bb5-5cdc-41ac-8c75-ee0a65b7c6a4" />
*  if you press alt at the door you can see the status of the doors  *
<img width="2560" height="1440" alt="FiveM FiveM exe Screenshot 2026 09 18 - 17 43 10 36" src="https://github.com/user-attachments/assets/9e326225-47c7-4ff4-85dd-7dd802aa54b5" />
*  the playes can put the code and change  *
<img width="2560" height="1440" alt="FiveM FiveM exe Screenshot 2026 09 18 - 17 43 13 36" src="https://github.com/user-attachments/assets/fdea3737-8919-4a8d-b6be-57e82b52e6ea" />



---
