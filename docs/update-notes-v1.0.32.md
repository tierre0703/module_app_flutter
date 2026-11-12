# Soleux Device Manager — Update Notes v1.0.31 → v1.0.32

**From:** 1.0.31 (build 23)  
**To:** 1.0.32 (build 24)  
**Platforms:** iOS (TestFlight), Android (Internal testing)  
**Period:** Nov 6 – Nov 11, 2026

---

## Short version (store / release description)

### What's New

**TLS on the Control API (port 5008)** — Modules that advertise `API_TLS:1`
are now reached over TLS 1.2+ (ALPN `soleux-json`): the enrolled Modbus HUB's
command channel is encrypted end-to-end. Trust is anchored on the bundled
Soleux root CA (never fetched from the device); a TLS failure never falls
back to plaintext. Hostname verification is a code-level switch and is
disabled by default (chain + validity stay enforced, fail-closed).

**Hub sign-in (TLS login contract)** — The Hub requires authentication before
control commands on a TLS session. The app now signs in with the Hub's web
administrator account: credentials are stored per module in the OS secure
credential store (Android Keystore / iOS Keychain), a sign-in card appears
when the session is unauthenticated, and no control command is ever polled on
an unauthenticated session. Failed logins are never auto-retried (the Hub
locks accounts).

**UDP heartbeat for local devices** — A 30-second unicast heartbeat refreshes
each local module's identity (`api_port`, `api_version`, the `API_TLS` flag,
`last_seen_at`) and drives online/offline with the same policy as the 5008
API check: pong = online, one missed ping = unknown, three consecutive
misses = offline. Remote/cloud and hostname-addressed modules are excluded.

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

**Hub control screen stability** — Fixed a crash when the screen was torn
down or refreshed while socket data was still arriving (a race made worse by
the TLS handshake window), a dialog lifecycle crash after sign-in
(`_dependents.isEmpty`), and the sign-in dialog overflowing when the
keyboard was shown.

---

## Detailed changes

### v1.0.32 — Nov 9 (hub variables stream)

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

### v1.0.32 — Nov 10–11 (TLS / heartbeat / login stream)

**TLS transport (`doc/Soleux_Mobile_Control_API_TLS_Integration.md`):**
- Discovery parses the additive `API_TLS` and `DEVICE_ID` fields; an absent
  `API_TLS` resolves to the device default `0` (plaintext).
- Per-module TLS dialing (`lib/core/soleux/soleux_tls.dart`,
  `lib/services/module_host_resolver.dart`): `SecureSocket` with ALPN
  `soleux-json`, driven by the module's `API_TLS` flag unless the code-level
  `AppConfig.apiTlsEnabled` switch forces it.
- Trust anchor: the Soleux root CA bundled as
  `assets/certs/soleux_root_ca.pem` (installed from
  `creds/Soleux-Root-CA.pem`; SHA-256 fingerprint recorded in
  `assets/certs/README.md`). Only the self-signed root becomes an anchor; a
  chain file's intermediates are leaf-issuer candidates only.
- Fail-closed everywhere: an unusable CA asset, an unverifiable chain or a
  TLS failure breaks the connection instead of downgrading to plaintext.
- Hostname verification (`AppConfig.tlsVerifyHostname`, disabled by
  default): the app dials by IP and the device certificate carries a DNS SAN
  only, so the platform hostname check always fails; with the switch off, a
  dial that fails with a *hostname-only* verification error is retried
  accepting the leaf — the chain was already proven to the installed root by
  the TLS stack, so chain and validity stay enforced and every other failure
  reason (unknown CA, expired, ...) still fails closed.

**Online/offline over TLS (`lib/services/module_status/module_api_health_service.dart`):**
- TLS modules check on a fresh dial: the TLS handshake itself is the
  reachability evidence (handshake = online). A `hello` answered with
  `authentication_required` keeps the module online (reachable, hub
  login-only); a hello that stops answering degrades to unknown; a failed
  handshake reports offline. Plaintext modules keep the original
  persistent-unit / transient-hello behavior.

**Hub TLS login (`lib/services/hub_credential_store.dart`,
`lib/services/module_status/hub_api_protocol.dart`,
`lib/services/module_status/module_status_service.dart`):**
- `authenticate` protocol action with `authentication_required` tracking.
- Per-module credentials in the OS secure credential store
  (flutter_secure_storage); corrupt stored payloads degrade to re-login.
- The Hub control screen shows a **Hub sign-in required** card when the
  session is unauthenticated; the sign-in dialog authenticates inside itself
  and never auto-retries (the Hub locks accounts after the 3rd failed
  password). Mid-session `authentication_required` flips the screen back to
  the login card.
- The background probe treats an auth-required hub as reachable; scenario
  hub dispatches (`set_output` / `set_modbus_output` / `set_tag`) authenticate
  from the stored login on their short-lived TLS connections.

**UDP heartbeat (`lib/core/soleux/soleux_heartbeat.dart`,
`lib/services/module_status/module_heartbeat_service.dart`):**
- The pong now carries `api_tls`; the app-side service runs the 30 s unicast
  heartbeat for **local** devices only (literal-IP address, not
  remote/cloud), keeping targets in sync with the module store.
- A pong refreshes `last_seen_at`, `api_port`, `api_version` and `API_TLS` (a
  flag flip takes effect on the next 5008 dial); `device_id` (the TLS
  certificate's DNS SAN) is only filled when the module has none saved — a
  saved TLS identity is never rebound from an unauthenticated datagram.
- Online/offline follows the original tri-state policy: pong = online
  (recovery from unknown and offline), one missed ping = unknown (offline
  stays offline), three consecutive misses = offline.

**Hub control screen stability (`lib/screens/hub_control_screen.dart`):**
- Fixed the chunk-pump race that crashed with
  "Null check operator used on a null value" when the screen was disposed or
  re-connected while socket data was queued (the TLS handshake widened the
  window): the pump now captures its client, the subscription is tracked and
  cancelled, and concurrent connects are guarded.
- Fixed the sign-in dialog lifecycle crash after login
  (`_dependents.isEmpty is not true`): the dialog is a self-owned
  StatefulWidget whose text controllers live through the exit animation.
- The sign-in dialog content scrolls when the keyboard is shown and the
  username/password fields are visually separated.

---

## How to test

1. **TLS to the enrolled HUB**
   - Open a `API_TLS:1` hub's control screen: the app connects over TLS (log
     shows `connected ... over TLS`), signs in with the stored Hub admin
     login, and the dashboard loads.
   - First use: the **Hub sign-in required** card appears → sign in with the
     Hub web administrator account → dashboard loads and the login is
     remembered (per module).
   - A wrong password shows the rejection in the dialog and does not retry.

2. **Heartbeat status**
   - Bring a local module down (unplug): within ~90 s (3 missed pings) it
     flips offline; on power-up it flips back online on the first pong.
   - Flip the hub's `API_TLS` setting: the module's TLS flag updates from the
     pong and the next 5008 dial follows it.

3. **Hub variables information**
   - Open a Modbus HUB control screen → the **Virtual tags (vio)** card lists
     the variables with their values.
   - Write a tag from another client, then refresh: values update after the
     device-info pass.

4. **Vars actions in scenarios**
   - Edit a scenario → Add action → select the HUB, target **Vars**:
     the Output and State sections disappear, a Variable dropdown and a Value
     field (default `0`) appear.
   - Save and run the scenario from the Scenarios screen card or from a Home
     tile: the value is written (`set_tag`) and the success bar shows the
     written value.
   - Edit the Vars action again: the saved tag and value are pre-filled and
     the module stays the HUB even when other modules exist.

5. **Regression**
   - HUB outputs: ON / OFF / Pulse / Restart and the output banks still work
     both from the control screen and from scenarios.
   - Relay / dimmer / input action editing still pre-fills correctly.
   - Older HUB firmware: no "unknown action" errors in the logs; the module
     still reaches online status.
   - Plaintext (`API_TLS:0` / absent) modules behave exactly as before.

---

## Known issues

| ID | Description | Status |
|----|-------------|--------|
| — | HUB variables appear only after the module answers a device-info/status pass or a control-screen refresh ("No variables cached …" hint) | Expected, refresh loads them |
| — | The CA **active-status check** (certificate serial/fingerprint against the trusted CA service) is not yet part of the connect sequence; hostname verification is disabled by code-level config | Planned follow-up before hub credential submission in production |
| — | Hub sign-in strings are not yet localized (EN only) | Planned |

---

## Feedback

Report issues to **support@soleux.com** with:
- Build version (1.0.32 / 24)
- Platform (iOS / Android)
- Steps to reproduce
- Screenshots or logs
