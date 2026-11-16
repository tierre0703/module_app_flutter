# Changelog

All notable changes to the Soleux Device Manager app are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); versions
match `pubspec.yaml` (`version: x.y.z+build`).

## [Unreleased]

### Changed - explicit TLS toggle for remote modules

The transport for a module's Control API port (5008) is chosen explicitly
with a TLS toggle button in the module configuration screens:

- The toggle ("TLS (secure) connection") is shown **only for modules with
  the `remote` connection type** (hostname / port-forwarding address) - in
  the edit-module-info dialog and in the manual-add form.
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
