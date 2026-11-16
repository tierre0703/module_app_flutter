# Changelog

All notable changes to the Soleux Device Manager app are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); versions
match `pubspec.yaml` (`version: x.y.z+build`).

## [Unreleased]

## [1.0.34] - 2026-11-16

### Added - editable Hub virtual tags

- The Hub control screen's read-only **Virtual tags** card is replaced by a
  **Virtual tags (vio)** section at the bottom of the screen. Every tag card
  shows the tag's **Name**, **tag name** and **Value** with an edit button.
- The edit dialog offers Name / Tag name / Value fields with Save and
  Cancel. Save writes the value to the Hub through the `set_tag` command
  (`vio.<tag_name>` over the live authenticated session) and caches the
  edited name / tag name on the module so the section reflects them until
  the next catalogue refresh.

### Changed

- The TLS toggle labels are shortened ("TLS (secure)" / "Uses encrypted
  TLS"; RO: "TLS (securizat)" / "Folosește TLS criptat") in the
  edit-module-info dialog and the manual add-module form.

### Fixed

- Saving the edit-module-info dialog with a toggled TLS transport now
  **closes every socket opened for the module** and reconnects: the
  persistent status units are disposed (auto-reconnect timers stopped) and
  the module is re-probed, and the Hub control screen closes and re-opens
  its own Hub session with the new transport. Previously a TLS → plaintext
  (or plaintext → TLS) switch could keep dialing the old transport.
- Root cause on the unit layer: the persistent-unit reuse check compared
  only the CA asset and expected device ID, which are identical whether the
  dial is TLS or plaintext. It now also requires the transport itself
  (`tls != null`) to match.

### Fixed - "events arrive, no command works" on a mis-typed module

A module record typed `hub` that actually fronts another Control API family
(e.g. a SLX DC Dimmer behind a port forward) speaks the Hub's protocol 1 -
which the firmware rejects (`unsupported protocol version`) - while its
protocol-2 broadcasts keep flowing. Diagnosed against the live device and
the repo's dummy server (the app's transport/framing/id-matching verified
correct in both framings). Fixes:

- **Auto type re-detection** (`ModuleStatusService._probeHub`): when the
  protocol-1 hello of a hub probe is rejected (not an auth issue), the
  probe asks the device for its identity with a protocol-2 `hello`
  (`device` field) and corrects the stored module type when it differs
  (`SoleuxDeviceFamilies.moduleTypeFromHelloResult`); the next refresh then
  drives the module with its real protocol. The device answering a
  protocol-2 hello marks it reachable.
- **Structured errors on the Hub protocol** (`HubCommandResponse`): the
  `{code, message}` error objects some firmware answers with are no longer
  dropped - the command completes with `code: message` text and an
  `errorCode` field (the `authentication_required` detection covers both
  shapes), instead of looking like a timeout.
- **Ping-based reachability vs dimmers** (`_pollJsonPing`): any
  id-echoed Control API response now proves the endpoint alive; previously
  a dimmer's `unknown_action` answer to `ping` (`ok:false`) reported the
  reachable device as unreachable.

### Changed - explicit TLS toggle for remote modules

The transport for a module's Control API port (5008) is chosen explicitly
with a TLS toggle button in the module configuration screens:

- The toggle ("TLS (secure)" / "Uses encrypted TLS") is shown **only for
  modules with the `remote` connection type** (hostname / port-forwarding
  address) - in the edit-module-info dialog and in the manual-add form.
- **Enabled = TLS, disabled = plaintext (non-TLS).** There is no automatic
  fallback in either direction after a failed connect
  (doc/Soleux_Mobile_Control_API_TLS_Integration.md §"Connection sequence").
- Before the user toggles anything, the module keeps its natural transport
  (the discovery-advertised `API_TLS` flag / device default plaintext) -
  a remote module is never forced to TLS on its own; the stored choice
  (`DeviceModule.tlsEnabled`) overrides the flag once made. Saving a
  non-remote connection type clears the stored choice.
- The code-level `AppConfig.apiTlsEnabled` switch (null in every shipped
  environment) still wins over everything when set.
- The choice is persisted as `DeviceModule.tlsEnabled` (`null` = never
  chosen).

Implementation:

- `lib/models/models.dart`: new `tlsEnabled` field (JSON
  round-trips; `null` degrades to the automatic decision).
- `lib/core/soleux/soleux_tls.dart`: `moduleWantsTls` precedence =
  code-level switch → explicit toggle (enabled = TLS / disabled =
  plaintext) → advertised `API_TLS` → device default plaintext;
  `SoleuxTlsOptions.allowPlaintextFallback` removed.
- `lib/services/module_host_resolver.dart`: `_dialSingle` fails closed
  again after a TLS failure. The TLS handshake deadline
  (`_tlsDialWithDeadline`) stays: dart:io's connect `timeout` does not
  bound the handshake, so a plaintext endpoint silently discarding the
  ClientHello would hang forever - with the deadline a TLS module dialled
  against a plaintext endpoint fails fast and can simply be switched to
  plaintext via the toggle.
- `lib/widgets/common_widgets.dart` (edit dialog) and
  `lib/screens/add_module_screen.dart` (manual add): the remote-only
  `SwitchListTile`.
- `l10n.yaml`: removed the deprecated `synthetic-package` key (rejected by
  the current Flutter); `flutter gen-l10n` regenerated
  `lib/l10n/gen`.

Tests: toggle precedence in `test/core/soleux/soleux_tls_test.dart`;
remote health-check modules dialling plaintext choose it explicitly via
`tlsEnabled: false`
(`test/services/module_status/module_api_health_service_test.dart`); the
fake device tolerates binary TLS ClientHello bytes.
