# Soleux Device Manager — Update Notes v1.0.31 → v1.0.32

**From:** 1.0.31 (build 23)  
**To:** 1.0.32 (build 24)  
**Platforms:** iOS (TestFlight), Android (Internal testing)  
**Period:** Nov 6 – Nov 9, 2026

---

## Short version (store / release description)

### What's New

**Hub Variables in scenarios & automations** — The Add/Edit Action dialog now
also targets the HUB's virtual variables (`vio` tags): pick **Vars**, choose a
variable and type the value to write. Scenario and automation runs (Home tiles,
scenario cards, automation triggers) execute the write with the Hub `set_tag`
command using the fully-qualified `vio.<name>` reference.

**Hub virtual-tag information** — The HUB's device info/status pass now also
reads the read-only tag catalogue (`get_tag_groups` + `get_tag_group`) and
caches the `vio` variables on the module. They are shown in a **Virtual tags**
card on the control screen and stay available offline in the scenario editor.

**Fixed background HUB status** — The background device-info/status pass for
Modbus HUB modules could time out and mark the module offline; the socket
wiring bug is fixed and commands are now guarded against older HUB firmware
through the advertised `hello` action list.

**Polished action editing** — Editing an action keeps the correct target
module (a bug could switch the dialog to another module when editing Vars
actions), pre-fills all saved values, defaults the Vars value to `0`, hides
the State section for Vars, and every new string is translated (EN/RO), with
compact target labels (Output / Modbus / Vars).

---

## Detailed changes

### v1.0.32 — Nov 9

**Modbus HUB protocol support (`lib/services/module_status/hub_api_protocol.dart`):**
- New command wrappers for the tag catalogue: `get_tag_groups`,
  `get_tag_group`, `get_tag_details` (read-only, protocol 1, TCP 5008).
- Result parsers tolerant to the deployed shape (group metadata nested in
  `group`) and the documented flat shape; fully-qualified `tag` values are
  stored without the `vio.` prefix in the app's cache.

**Modbus HUB information (`lib/services/module_status/module_status_service.dart`
and the Hub control screen):**
- Background status probe (`_probeHub`): fixed the missing
  connection-data→protocol wiring that made every command time out; the probe
  no longer falsely reports hubs offline.
- `get_device_info` and the new tag commands are gated by the advertised
  `hello.action` list, so older firmware (pre-tag-catalogue) is never hit with
  an "unknown action" error and never breaks the status pass.
- The `vio` tag catalogue is cached on the module (`DeviceModule.virtualTags`)
  and persisted; a successful scenario write refreshes the cached value
  immediately.
- The control screen shows the cached variables in a **Virtual tags (vio)**
  card and re-fetches the catalogue on connect/refresh.

**Scenarios & automations (`lib/models/models.dart`,
`lib/widgets/action_picker.dart`, `lib/services/scenario_runner.dart`):**
- `ScenarioAction` gains `hubOutputBank: variables` plus `hubVariableTag` and
  `hubVariableValue`, serialized with the existing hub fields (backward
  compatible).
- Add/Edit Action dialog:
  - Hub target segments: **Output · Modbus · Vars** (localized, compact).
  - Vars: Variable dropdown (from the cached tag catalogue) + Value field
    (default `0`); Output dropdown and State section hidden.
  - Editing pre-fills the saved module/target/state; Vars edits no longer
    switch to another module.
- Scenario/Automation run paths dispatch Vars actions through `set_tag`
  (`vio.<tag>`); failures surface as normal per-action results in the
  snackbars and event log.
- Action constants added to the shared JSON protocol catalogue.

**Localization:**
- New EN/RO keys: Modbus / Vars targets, Variable, Value, no-variables hint,
  Virtual-tags card title; previously hardcoded `Pulse` labels localized too.

**Test app (`doc/Soleux API Test App`):**
- The standalone API tester and its documentation gained the new tag-catalogue
  commands, refs updated to the current Modbus HUB API doc.

---

## How to test

1. **Hub variables information**
   - Open a Modbus HUB control screen → the **Virtual tags (vio)** card lists
     the variables with their values.
   - Write a tag from another client, then refresh: values update after the
     device-info pass.

2. **Vars actions in scenarios**
   - Edit a scenario → Add action → select the HUB, target **Vars**:
     the Output and State sections disappear, a Variable dropdown and a Value
     field (default `0`) appear.
   - Save and run the scenario from the Scenarios screen card or from a Home
     tile: the value is written (`set_tag`) and the success bar shows the
     written value.
   - Edit the Vars action again: the saved tag and value are pre-filled and
     the module stays the HUB even when other modules exist.

3. **Regression**
   - HUB outputs: ON / OFF / Pulse / Restart and the output banks still work
     both from the control screen and from scenarios.
   - Relay / dimmer / input action editing still pre-fills correctly.
   - Older HUB firmware: no "unknown action" errors in the logs; the module
     still reaches online status.

---

## Known issues

| ID | Description | Status |
|----|-------------|--------|
| — | HUB variables appear only after the module answers a device-info/status pass or a control-screen refresh ("No variables cached …" hint) | Expected, refresh loads them |

---

## Feedback

Report issues to **support@soleux.com** with:
- Build version (1.0.32 / 24)
- Platform (iOS / Android)
- Steps to reproduce
- Screenshots or logs
