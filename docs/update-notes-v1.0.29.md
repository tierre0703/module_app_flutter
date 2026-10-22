# Soleux Device Manager — Update Notes v1.0.20 → v1.0.29

**From:** 1.0.20  
**To:** 1.0.29 (build 21)  
**Platforms:** iOS (TestFlight), Android (Internal testing)  
**Period:** Oct 12 – Oct 22, 2026

---

## Short version (store / release description)

### What's New

**Modbus HUB support** — Connect, monitor and control Soleux Modbus HUB modules
directly from the app: device info, live system status, regular outputs
(ON / OFF / Pulse) and Modbus power outputs (ON / OFF / Restart), with
instant updates when another client changes an output.

**Rebuilt Home quick scenarios** — Scenario cards on the Home screen are now
a responsive tile grid: 2 columns on phones, 4 columns on tablets, with
drag-and-drop reordering from a drag handle on each tile.

**Better control screens** — Module actions (refresh, system log, edit) moved
into the screen body, long module names no longer break the layout, and every
action now confirms with a toast.

**Smarter scenarios & automations** — Actions can target HUB outputs,
including Modbus power outputs and Pulse actions; device-state triggers can
watch Modbus outputs.

**App Store readiness** — Reviewed iOS purpose strings, launch screen,
privacy policy (EN/RO) and submission documentation.

---

## Detailed changes by release

### v1.0.21 — Oct 12
- Fixed the iOS/TestFlight build (CocoaPods configuration).
- Replaced the iOS launch image.

### v1.0.23 – v1.0.24 — Oct 14
- Reworked the iOS `Info.plist` purpose strings so App Store validation passes:
  - Local network (module discovery and control)
  - Location (declared as unused — required by a bundled library)
  - Photo library / camera (declared for the bundled file picker)
  - File sharing for backup export/import
- Version bumps only otherwise.

### v1.0.25 — Oct 18
- **Home screen:** tapping a scenario card no longer fires the scenario.
- **Configuration:** added bottom spacing so the last module is not hidden
  behind the navigation bar.
- **Feedback:** snackbar/toast confirmation when a module action is applied
  (relay, Hub, scenarios).
- **Module control screens** (relay, blind, dimmer AC/DC, temperature):
  refresh / system-log / edit actions moved from the AppBar into a
  right-aligned action row inside the screen body.
- Dark-mode background alpha experiment reverted; background color corrected.

### v1.0.26 — Oct 19
- **New module type: Modbus HUB.**
  - Hub-specific JSON protocol (`get_device_info`, `get_dashboard`,
    `set_output`, `pulse_output`, `restart_modbus_output`, event stream).
  - Hub control screen: device info card, live system status (CPU/temperature/
    memory/network), normal output rows with ON / OFF / Pulse, and Modbus power
    output rows with ON / OFF / Restart.
  - Hub reachability probing and channel sync (`isModbusPower` flag) merged into
    the module status service.
- **Real-time events:** `output_state_changed` now updates both output banks
  immediately (no polling delay), plus `input_state_changed` and periodic
  `system_status` snapshots.
- **Scenarios & automations:** HUB targets supported in the action picker
  (Output vs Modbus bank), Pulse actions, and devices-state triggers that can
  watch Modbus outputs.
- Pulse action can be disabled.
- Added `PRIVACY.md`, `PRIVACY.ro.md` and Apple submission documentation.

### v1.0.27 — Oct 20
- Long module names now truncate with an ellipsis instead of breaking the
  layout on every module control screen.
- Automation/scenario editors updated for Modbus HUB targets.
- Build fixes.

### v1.0.28 — Oct 20
- Scenario/automation screens: action buttons right-aligned, plus extra spacing
  so the new-scenario button does not overlap content.
- Modbus/HUB UI fixes and build fixes.

### v1.0.29 — Oct 22
- **Home quick scenarios rebuilt as a reorderable tile grid:**
  - 2 columns on phones, 4 columns on tablets (width-based breakpoint at 600 dp).
  - Each tile has a drag handle in its top-left corner: dragging starts
    immediately from the handle (no long press needed).
  - Tiles show icon, scenario name and room tag; the scenario runs only when the
    icon is tapped — tapping the card body does nothing.
  - Tiles fill the full column width (no right-side gap); content is centered.
- HUB addition issues fixed (module registration and hub status probing).

---

## How to test

1. **Home tile grid**
   - Phone: scenarios appear in 2 columns; tablet/landscape: 4 columns.
   - Drag a tile by its top-left handle — order persists after restart.
   - Tap the icon: scenario runs or the slider opens. Tap elsewhere: nothing.
   - Tiles and cards fill the full column width with even spacing.

2. **Modbus HUB**
   - Add a HUB module, open it, confirm device info and system status load.
   - Toggle a normal output, send Pulse, toggle a Modbus output, send Restart.
   - Change an output from another client and confirm the UI updates without
     refreshing.

3. **Scenarios / Automations with HUB**
   - Create a scenario action targeting a HUB output (Output and Modbus).
   - Create an automation triggered by a Modbus output change.

4. **Regression**
   - Relay, blind, dimmer AC/DC and temperature screens: refresh, system log and
     edit buttons work from the body action row.
   - Toasts appear on module actions.
   - Module lists scroll clear of the bottom navigation bar.

---

## Known issues

| ID | Description | Status |
|----|-------------|--------|
| — | No new known issues in this range | — |

---

## Feedback

Report issues to **support@soleux.com** with:
- Build version (1.0.29 / 21)
- Platform (iOS / Android)
- Steps to reproduce
- Screenshots or logs
