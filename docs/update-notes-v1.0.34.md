# Soleux Device Manager — Update Notes v1.0.32 → v1.0.34

**From:** 1.0.32 (build 24)  
**To:** 1.0.34 (build 26)  
**Platforms:** iOS (TestFlight), Android (Internal testing)  
**Period:** Nov 12 – Nov 16, 2026

---

## Short version (store / release description)

### What's New

**Editable Hub variables** — The HUB's **Virtual tags (vio)** card is now a
full **Virtual tags** section at the bottom of the Hub control screen. Every
variable card shows its Name, tag name and current Value with an edit
button. The edit dialog offers Name / Tag name / Value with Save and
Cancel; Save writes the value to the HUB with the `set_tag` command
(`vio.<tag_name>` over the authenticated session) and the section updates
immediately.

**Explicit TLS toggle, done right** — Remote modules (hostname /
port-forwarding address) carry a **TLS (secure)** toggle in the
module-info dialog and the manual-add form: enabled = TLS, disabled =
plaintext, no automatic fallback in either direction. Saving the dialog
with a toggled transport now **closes every socket opened for the module
and reconnects with the new transport** — previously a TLS ↔ plaintext
switch could keep dialing the old transport.

**Auto type re-detection** — A module record typed `hub` that actually
fronts another Control API family (e.g. a SLX DC Dimmer behind a port
forward) no longer gets stuck: when the Hub's protocol-1 hello is rejected,
the app re-asks the device for its identity with a protocol-2 `hello` and
corrects the stored module type, after which the module is driven with its
real protocol.

**Clearer errors & reachability** — The Hub's `{code, message}` error
objects are no longer dropped (commands report the structured error
instead of looking like a timeout), and any id-echoed Control API response
proves a dimmer endpoint alive (a `ping` answered with `unknown_action` no
longer reports a reachable device as unreachable).

**Shorter TLS labels** — The toggle text is compact ("TLS (secure)" /
"Uses encrypted TLS") in both the module-info dialog and manual add form.

---

## Detailed changes

### Virtual tags editing (`lib/screens/hub_control_screen.dart`)

- The read-only "Virtual tags (vio)" card between Device Info and System
  Status is removed.
- A **Virtual tags (vio)** section is added at the bottom of the screen
  (below the Modbus Power Outputs section), reusing the shared
  `SectionHeader` and the output-row card style.
- Each tag card shows the display name as the title (falls back to the tag
  name when no name is set), the tag name as the subtitle, the current
  value, and an edit (pencil) button.
- The edit dialog (`_VirtualTagEditDialog`) pre-fills Name / Tag name /
  Value, validates that tag name and value are non-empty, and pops the
  edited values on Save (Cancel pops nothing).
- Save path (`_saveVirtualTag`): sends `set_tag` with the tag's stored
  `tag_name` as the `vio.`-prefixed wire reference over the live
  authenticated Hub session; on success the cached tag
  (`DeviceModule.virtualTags`) is updated with the edited name / tag name /
  value and a "Tag saved" toast is shown; failures (including a mid-session
  `authentication_required`) surface as toasts / the sign-in card.

### TLS toggle follow-through (`lib/widgets/common_widgets.dart`,
`lib/services/module_status/module_status_service.dart`,
`lib/screens/hub_control_screen.dart`)

- `showEditModuleInfoDialog` captures the module's transport
  (`moduleWantsTls`) before applying the edit. After saving, a changed
  transport calls the new `ModuleStatusService.restartModuleSockets`
  instead of the plain `refreshOne`.
- `ModuleStatusService.restartModuleSockets(module)`: disposes the module's
  persistent command/status unit (stopping its auto-reconnect timers) and
  its JSON/HTTP unit, then re-probes so the units are recreated with the
  module's current endpoint and transport settings.
- Root-cause fix in `_ensureJsonUnit`: the unit-reuse check compared only
  the CA asset and the expected device ID — identical whether the dial is
  TLS or plaintext — so a transport toggle could silently reuse a socket
  dialing the old transport. The check now also requires the transport
  itself (`tls != null`) to match.
- The Hub control screen owns its own Hub session outside the status
  service: after a saved edit with a changed transport it tears the session
  down and reconnects (`_connectAndRefresh`); the login state resets
  naturally with the dropped session.
- Shorter toggle strings (`tlsConnection` / `tlsConnectionHelp`) in EN and
  RO; both the module-info dialog and the manual add form pick them up
  from the shared l10n keys.

### Mis-typed module auto-correction
(`lib/services/module_status/module_status_service.dart`,
`lib/services/module_status/hub_api_protocol.dart`)

- When the protocol-1 `hello` of a hub probe is rejected (not an auth
  issue), the probe asks the device for its identity with a protocol-2
  `hello` and corrects the stored module type when it differs; the next
  refresh drives the module with its real protocol. The device answering a
  protocol-2 hello marks it reachable.
- `HubCommandResponse` preserves the `{code, message}` error objects some
  firmware answers with: the command completes with `code: message` text
  and an `errorCode` field, and the `authentication_required` detection
  covers both shapes.
- The JSON ping treats any id-echoed Control API response as proof of
  reachability, so a dimmer's `unknown_action` answer to `ping` no longer
  reports the device offline.

### Explicit TLS toggle (remote modules)
(`lib/models/models.dart`, `lib/core/soleux/soleux_tls.dart`,
`lib/widgets/common_widgets.dart`, `lib/screens/add_module_screen.dart`)

- The toggle is shown only for the `remote` connection type; enabled = TLS,
  disabled = plaintext; no automatic fallback in either direction after a
  failed connect.
- Before the user toggles anything the module keeps its natural transport
  (advertised `API_TLS` flag / device default plaintext); the stored choice
  (`DeviceModule.tlsEnabled`) overrides the flag once made. Saving a
  non-remote connection type clears the stored choice.
- The code-level `AppConfig.apiTlsEnabled` switch still wins when set.

---

## How to test

1. **Virtual tags editing**
   - Open a Modbus HUB control screen → the **Virtual tags (vio)** section
     sits at the bottom and lists every variable card with Name, tag name,
     Value and an edit button.
   - Tap edit → change the Value (and optionally Name / Tag name) → Save:
     the app writes the value with `set_tag` and shows "Tag saved"; the
     card immediately reflects the new value/name. Verify the written value
     from another client (or the device's web UI).
   - Cancel closes the dialog without writing.
   - Saving with an empty tag name or value shows a validation error and
     stays in the dialog.

2. **TLS toggle socket restart**
   - On a remote module: open the module-info dialog, toggle the TLS
     switch, save → the module's status re-probes over the new transport
     (log shows the old session closed and a fresh dial; a TLS hub drops
     back to the sign-in card).
   - Toggle back and save again → the module reconnects over plaintext and
     reaches online without an app restart.
   - Regression: a name-only save does not reconnect sockets.

3. **Mis-typed module**
   - Point a module record typed `hub` at a port-forwarded SLX DC Dimmer:
     after a refresh the stored type corrects itself and the dimmer works
     (brightness / events) instead of failing with "unsupported protocol
     version".

4. **Regression**
   - HUB outputs: ON / OFF / Pulse / Restart still work from the control
     screen and from scenarios.
   - Vars actions in scenarios still write through `set_tag`.
   - Local (non-remote) modules ignore the TLS toggle and keep the
     automatic decision chain.
   - Older HUB firmware: no "unknown action" errors in the logs.

---

## Known issues

| ID | Description | Status |
|----|-------------|--------|
| — | Name / Tag name edits in the virtual-tag dialog are local: the Hub's `set_tag` API only writes the value (the tag catalogue is read-only), so the device-side name resets after the next catalogue refresh | Device API limitation |
| — | HUB variables appear only after the module answers a device-info/status pass or a control-screen refresh | Expected, refresh loads them |
| — | The CA **active-status check** (certificate serial/fingerprint against the trusted CA service) is not yet part of the connect sequence; hostname verification is disabled by code-level config | Planned follow-up |
| — | Hub sign-in strings are not yet localized (EN only) | Planned |

---

## Feedback

Report issues to **support@soleux.com** with:
- Build version (1.0.34 / 26)
- Platform (iOS / Android)
- Steps to reproduce
- Screenshots or logs
