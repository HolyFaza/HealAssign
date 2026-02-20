# HealAssign

A raid healing assignment addon for **World of Warcraft 1.12.1** (Vanilla).

Raid leaders and assistants create healer assignment templates — defining which healers cover which tanks or groups — then sync them to the entire raid with a single command. Every healer with the addon installed instantly sees their personal assignment in a small, movable frame.

---

## Features

- Assign healers to tanks, raid groups, or custom targets
- Save and load multiple named templates
- One-click raid sync via addon messaging
- Personal assignment frame for each healer
- Editor lock system — only one person can edit at a time
- Role-gated access — Raid Leader and Assistants only
- Death notifications for tanks and healers in a configured chat channel
- Class-colored player names throughout the UI

---

## Installation

1. Download or clone this repository
2. Copy the `HealAssign` folder into your addons directory:
```
World of Warcraft/Interface/AddOns/HealAssign/
```
3. Restart the game client or type `/console reloadui`

---

## Commands

| Command | Description |
|---|---|
| `/ha` or `/healassign` | Toggle the main editor window |
| `/ha sync` | Sync the active template to all raid members |
| `/ha assign` | Toggle your personal assignments frame |
| `/ha options` | Open the options panel |
| `/ha help` | Print all commands to chat |

---

## Access & Permissions

Only **Raid Leaders and Assistants** can open the editor and make changes. Regular raid members receive assignments via sync but cannot edit them.

The editor can only be open by **one player at a time**. If another assistant already has it open, you will see their name in chat. When they close it, all eligible players are notified that the editor is free.

---

## Usage

### Typical workflow

1. Open the editor: `/ha`
2. Enter a template name in the **Template:** field (e.g. `MC_farm`)
3. Click **Add Tank** → select tanks from the raid roster
4. For each tank, click **Add Healer** → assign healers from the dropdown
5. Click **Save**
6. Type `/ha sync` — all raid members receive the assignments
7. Close the window — the editor lock is released

---

### Template toolbar

| Button | Description |
|---|---|
| **New** | Clear the workspace and start a fresh template. If there are unsaved changes, a prompt will ask whether to save first. |
| **Load** | Load a previously saved template from a dropdown list. |
| **Save** | Save the current template under the name in the **Template:** field. A name is required. |
| **Reset** | Clear all assignments while keeping the template name. |
| **Del** | Permanently delete the current template after confirmation. |

> **Note on New:** If you click **New** with unsaved changes, a dialog appears. Clicking **Save** in that dialog saves the template and clears the workspace. If the name field is empty, saving will be blocked with a warning — enter a name first.

---

### Adding targets

| Button | Description |
|---|---|
| **Add Tank** | Add a tank from the raid. Shows Warriors, Druids, and Paladins by default (configurable in Options). Falls back to the full roster if none are found. |
| **Add Group** | Add a raid group (Group 1–8) as an assignment target. |
| **Add Custom** | Add a custom target defined in Options (e.g. "Offtank", "Melee"). |

---

### Managing assignments

Once a target is added, it appears in the assignment list:

- **Add Healer** — opens a dropdown of raid members; select a healer to assign. A healer cannot be assigned to the same target twice.
- **X** next to a target — removes the target and all its assigned healers.
- **X** next to a healer — removes only that healer from the target.

Tank and healer names are displayed in **class colors** when the player is present in the raid.

---

## Personal Assignments Frame

A small, draggable frame visible to every player with the addon. It displays:

- The name of the active template
- The specific target this player is assigned to heal

If the player has no assignments in the current template, it shows `No assignments for you`.

Toggle visibility with `/ha assign` or via the **Show My Assignments Frame** checkbox in Options.

---

## Options (`/ha options`)

| Setting | Description |
|---|---|
| **Tank Classes** | Which classes appear in the Add Tank dropdown (default: Warrior, Druid, Paladin) |
| **Custom Targets** | Define your own assignment targets for the Add Custom button |
| **Chat Channel** | Channel number for death notifications (0 = disabled) |
| **Font Size** | Text size in the personal assignments frame |
| **Show My Assignments Frame** | Show or hide the personal assignments frame |

---

## Death Notifications

When a **Chat Channel** number is configured in Options, the addon automatically announces in that channel when:

- A **tank** from the active template dies — lists their assigned healers
- A **healer** from the active template dies — states who they were covering

---

## Compatibility

- World of Warcraft **1.12.1** (Vanilla / Classic Era private servers)
- Written in **Lua 5.0** — no Lua 5.1+ functions used (`string.find` instead of `string.match`, etc.)
- Uses `SendAddonMessage` for raid communication — recipients must have the addon installed to receive syncs

---

## License

This project is released under the [MIT License](LICENSE).
