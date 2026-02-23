# HealAssign v2.0.0

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

### Options
- Font size for the assignment window (8–24)
- Window opacity
- Show assignment window outside raid
- Custom assignment targets (e.g. "Main Tank", "OT", "Skull")

---

## Installation

1. Place the `HealAssign` folder in:
   ```
   World of Warcraft/Interface/AddOns/HealAssign/
   ```
2. The folder must contain `HealAssign.lua` and `HealAssign.toc`
3. Enable the addon in the AddOns menu on the character select screen

---

## Commands

| Command | Description |
|---|---|
| `/ha` | Open the main window |
| `/ha sync` | Broadcast current template to raid |
| `/ha options` | Open options |
| `/ha assign` | Toggle the assignment window |

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
