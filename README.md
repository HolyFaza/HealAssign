# HealAssign v2.0.6

A healer assignment addon for **World of Warcraft 1.12.1 (Vanilla / Turtle WoW)**.

Designed for raid leaders and healers to manage and display healing assignments in real time — with death alerts, unattended target tracking, and a viewer mode for tanks and officers.

---

## Features

### Assignment Management (Raid Leader)
- Create, save, load, and delete named **templates**
- Assign healers to **tanks** (by name), **groups** (1–8), or **custom targets**
- **Reset** clears all assignments while keeping the template
- **Sync** broadcasts the current template to all raid members with the addon

### Raid Roster
- Tag players with:
  - **T** — Tank (appears in the Tank dropdown when assigning)
  - **H** — Healer (appears as a healer column in the main grid)
  - **V** — Viewer (receives assignments read-only, e.g. tanks, officers)
- T and H are mutually exclusive; V can be combined with either
- **Reset Tags** clears all tags for the current template

### Healer Assignment Window
- Each healer tagged **H** sees their own compact assignment window
- Targets colored by type: Tank = class color, Group = blue, Custom = purple
- Hidden outside raid by default (toggle in Options)
- When another healer dies: their **unattended targets** appear in your window under the dead healer's name (in their class color), until they are resurrected

### Death Alerts
- When a healer dies, all players tagged **H** or **V** receive:
  - A large **on-screen alert** (DBM-style) with the healer's name — fades after 7 seconds
  - An **audio alert**
  - **Unattended targets** appear in their assignment window
- Targets clear automatically when the healer is resurrected
- Ghost state does not count as resurrection — targets stay until the healer is actually alive

### Viewer Mode (V tag)
- Inverted read-only window: **Target → Healers**
- Dead healers shown in **red**
- Receives death alerts and audio notification

### Rebirth (Druid)
- All druids receive a dedicated **Rebirth** window with a live list of dead T/H-tagged raid members
- Click a name in the list to target that player, then press the **Rebirth** cast button
- Target status is synced across all druids in real time:
  - 🟢 Green — not targeted by any druid
  - 🟡 Yellow — targeted by you
  - 🔴 Red — targeted by another druid
- Rebirth icon shows the remaining **30-minute cooldown** timer
- Healer-druids see the Rebirth section integrated into their existing assignment window

### Options
- Font size for the assignment window (8–24)
- Window opacity
- Show assignment window outside raid
- Hide addon in Battlegrounds (enabled by default)
- Custom assignment targets (e.g. "Main Tank", "OT", "Skull")

---

## Installation

1. Place the `HealAssign` folder in:
   ```
   World of Warcraft/Interface/AddOns/HealAssign/
   ```
2. The folder must contain `HealAssign.lua`, `HealAssign.xml` and `HealAssign.toc`
3. Enable the addon in the AddOns menu on the character select screen

---

## Commands

| Command | Description |
|---|---|
| `/ha` | Toggle the main window (RL/Assistant only) |
| `/ha sync` | Broadcast current template to raid |
| `/ha options` | Toggle options |
| `/ha assign` | Toggle the assignment window |
| `/ha rl` | Toggle raid leader view |
| `/ha help` | Show all commands |

---

## Quick Start

1. Enter raid → open **Raid Roster**
2. Tag tanks **T**, healers **H**, viewers **V**
3. Assign targets to each healer using **Tank / Group / Custom** buttons
4. **Save** the template → **Sync** to broadcast to all

---

## Requirements

- WoW 1.12.1 or Turtle WoW
- All healers and viewers need the addon installed to receive synced assignments and alerts

---

## Changelog

### v2.0.5
- **Performance refactor** — widget pool system for all dynamic frames (viewer, healer assignment, druid assignment, innervate rows); eliminates per-frame creation on every update tick; UNIT_HEALTH event debounced (2 s per unit) to prevent raid-wide lag spikes
- **Adaptive window widths** — all assignment windows (viewer, healer, druid) now size dynamically to fit the longest name at the current font size; no more excess whitespace
- **Collapsible Rebirth section** — Rebirth block in the viewer window can be collapsed/expanded with a +/− toggle button
- **Options moved to minimap** — Options buttons removed from all windows; right-click the minimap icon to open Options (left-click still toggles the main window); Options are accessible at all times, including outside raid
- **Access control** — only Raid Leader or Assistant can open the main editor window; other players see a chat message explaining the restriction
- **Concurrent editor warning** — if a second RL/Assistant opens the editor while another player already has it open, both receive a warning in chat; lock auto-expires after 5 minutes in case of disconnect
- **Fixed:** Innervate cooldown was resetting for all druids when any one druid cast Innervate
- **Fixed:** Viewer window was showing players who had left the raid
- **Fixed:** Stale Innervate assignment remained visible in viewer after druid or healer left the raid
- **Fixed:** Innervate block was incorrectly hidden in the healer assignment window
- **Fixed:** Innervate cooldown showed "0:00" instead of disappearing when ready
- **Fixed:** Dead healer was incorrectly marked as alive ~15 seconds after death
- **Fixed:** [DEAD] and [!] text labels replaced with red name colouring throughout all windows
- **Fixed:** Healer name overlapped the Options button in the druid assignment frame
- **Fixed:** Window title overlapped the Options button in the healer assignment frame
- **Fixed:** Button font now scales correctly with the font size slider

### v2.0.4
- **Rebirth system** — all druids receive a window with a live list of dead T/H-tagged raid members; click a name to target, then cast Rebirth via the cast button; target status is synced across all druids in real time (green = free, yellow = your target, red = taken); 30-minute cooldown timer shown on the icon; healer-druids see Rebirth integrated into their assignment window
- **Minimap icon** — draggable icon on the minimap; left-click to toggle the main window; right-click to toggle options; drag to reposition
- **Hide in Battlegrounds** — new checkbox in Options; when enabled (default), the addon is hidden in battlegrounds

### v2.0.3
- **Innervate assignment system** — raid leader assigns each non-healer druid to a specific healer
- Druids receive a dedicated assignment window showing their assigned healer's name and current mana %
- Innervate cooldown timer shown on the icon in the druid window (reads from `GetSpellCooldown`)
- **Mana alert** — when assigned healer drops below 50% mana, druid receives a BigWigs-style green on-screen alert; resets when mana recovers above 60%
- Innervate cooldown also shown in the healer's own assignment window
- **Roster cleared on raid leave** — stale members from previous raid no longer appear in new raid
- Fixed: assignment window now hides automatically when leaving raid
- Fixed: druid assignment window restores last position after reload
- Fixed: `INN_BroadcastCast` forward declaration (nil error on healer side)
- Fixed: `Unknown addon chat type` error when assigning Innervate outside of a group
- Button order in main window: Raid Roster → Innervate → Sync → Options
- Assign button in Innervate window now uses standard `UIPanelButtonTemplate`

### v2.0.0
- Full rewrite: healer-centric layout (one column per healer)
- Roster tag system: T / H / V with mutual exclusion rules
- DBM-style death alerts with sound and fade animation
- Unattended target tracking with resurrection detection
- Viewer mode (target → healers, inverted display)
- Dynamic grid: 2 / 3 / 4 columns based on healer count
- Template system with save / load / delete and confirmation dialogs
- Tooltips on all buttons
- Custom targets support

### v1.x
- Target-centric layout, basic assignment and sync

---

## Credits

**Death alert sound:** "Metal Bucket Kicked" by [deathpunk](https://freesound.org/people/deathpunk/)
Source: https://freesound.org/s/795710/
License: [Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
