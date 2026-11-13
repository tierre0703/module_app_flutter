# Soleux mobile Control API TLS integration

Status: developer handoff for the **current Modbus Hub implementation**, checked
against active source on 9 November 2026. The enrolled test Hub uses TLS on
port 5008. Other Soleux device families do not yet have this Hub TLS/login
contract; inspect their own firmware and API documents before enabling this
flow for them.

This guide covers a mobile app connecting to an already enrolled Hub. Device
enrollment and certificate renewal are performed by the Hub, not the mobile app.
For command parameters and response data, use
[Modbus_Hub_Control_API.md](Modbus_Hub_Control_API.md). For commissioning and CA
status, use
[Soleux_Certificate_Enrollment_API_v0.3.md](Soleux_Certificate_Enrollment_API_v0.3.md).
For UDP discovery and heartbeat framing, use
[Soleux-Network-Discovery-and-DCP.md](../Windows%20App/Soleux-Network-Discovery-and-DCP.md).

## What the app needs

| Item | Source | Purpose |
|---|---|---|
| Hub IP address | TCP peer address of its UDP discovery callback, or a saved address | Network route to the Hub |
| `API_PORT` | Discovery; currently `5008` on the Hub | TLS Control API endpoint |
| `API_TLS` | Discovery (`1` or `0`) | Select TLS or the temporary legacy plaintext mode |
| `DEVICE_ID` | Discovery, then confirmed against trusted device inventory | Expected certificate identity, `<ModelNumber>-<SerialNumber>` |
| Soleux root CA | Independently provisioned in the mobile app | Trust anchor for the Hub certificate and CA service |
| Device username/password | Entered by the user and stored in the mobile OS secure credential store | Hub Control API login; an existing Hub web account with `admin` or `superadmin` role |

Discovery and heartbeat are unauthenticated. Treat their `DEVICE_ID`,
`API_TLS`, and IP values as **untrusted hints** until the operator has confirmed
the device against trusted inventory and the TLS certificate has been checked.
Do not use the MAC address as certificate identity. Do not fetch a root CA from
the discovered Hub and trust it automatically. The development CA is not a
production trust anchor; provision the production Soleux root independently
when it is available.

An administrator can download the **Root CA (.pem)** from the CA portal's
**Certificates** page and share it with the mobile developer. The **CA chain
(.pem)** download contains the issuing intermediate followed by the root;
install only the independently verified root as a trust anchor. Confirm its
SHA-256 fingerprint through a separate trusted channel before use.
The development root was reissued on 9 November 2026 with the same CA key but
a new certificate fingerprint. Existing clients that pin the old root file
must be updated to the current public root for long-lived offline deployments.

## Recommended transport: HTTPS on port 5008

The Hub presents its *device identity certificate* on the Control API port.
This is separate from the certificate used by the Hub's normal web UI. Port
5008 accepts TLS 1.2 or newer and offers ALPN `http/1.1` for HTTPS and
`soleux-json` for raw JSON. Select `http/1.1` for the mobile HTTP client. The
current listener also recognizes an HTTP request from a TLS client that omits
ALPN; explicitly selecting `http/1.1` is more predictable.

The certificate has the permanent device ID as its **DNS SAN**, plus
`urn:soleux:device:<device-id>` as a URI SAN. It has **no IP SAN**. The IP can
change without replacing the certificate. To use normal hostname validation,
make the HTTPS URL host the expected device ID and have the mobile networking
layer resolve that name to the discovered/saved IP for this connection:

```text
Logical URL / TLS server name: https://<DEVICE_ID>:<API_PORT>
Connect address:                <discovered-or-saved-IP>:<API_PORT>
Expected DNS SAN:               <DEVICE_ID>
```

Keep certificate-chain and time validation enabled against the independently
installed Soleux CA. Require the DNS SAN to match the saved device ID (DNS
comparison is case-insensitive). Do not accept an arbitrary name merely
because the chain is valid, and do not use an “ignore certificate errors”
setting. If the platform cannot override name resolution, use its supported
custom trust evaluation to check the CA chain, validity period, and exact DNS
SAN while connecting to the IP. Do not disable chain validation to work around
the missing IP SAN. The Hub does not request a mobile client certificate;
authentication is by Hub username/password after TLS verification.

### Certificate status

The CA contract additionally requires an active-status check. Once the Hub
certificate's chain, dates, and identity are valid, extract its X.509 serial
number as a **decimal string** and SHA-256 fingerprint. Query the trusted CA
service (development base URL: `https://10.128.12.18`):

```http
POST /v1/certificate-status
Content-Type: application/json

{"certificate_serial":"<decimal certificate serial>"}
```

Accept only a response with `status:"active"`, `valid:true`, and matching
`device_id`, `certificate_serial`, and certificate fingerprint. The CA service
connection must also validate against its independently provisioned trust
anchor. A serial that is unknown, pending, expired, replaced, or revoked must
not be accepted. The current development service uses this JSON endpoint;
production CRL/OCSP distribution is still pending. The contract does not yet
define an offline status-cache lifetime, so do not silently treat a failed CA
status request as an active certificate. Decide any offline policy with the
product/security owner before shipping it.

A 10-year device certificate prevents expiration during a long offline
deployment, but it does not give an offline mobile app revocation information.
The current mobile acceptance sequence therefore still requires CA access for
the active-status check. An offline status distribution or explicitly approved
offline policy is needed before fully offline mobile control is released.

### Credential-free preflight

After TLS and certificate validation, send the Hub's unauthenticated preflight
request **without** an `Authorization` header:

```http
POST /api/v1/preflight HTTP/1.1
Content-Type: application/json; charset=utf-8

{}
```

Expected HTTP 200 body:

```json
{"protocol":1,"id":null,"ok":true,"result":{"tls_identity_ready":true}}
```

Preflight proves that the port is serving the Hub HTTPS facade; its JSON body
does not identify or authenticate the device. The certificate checks above do
that. The Windows client performs preflight before sending credentials.

### Login and commands

Use the **Hub's web administrator account**, not a Soleux CA portal account.
Only Hub accounts with `admin` or `superadmin` role may use this Control API.
Send HTTP Basic credentials on each command request so a mobile HTTP client can
open a new TLS connection without losing authentication:

```http
POST /api/v1/command HTTP/1.1
Content-Type: application/json; charset=utf-8
Accept: application/json
Authorization: Basic <base64 of UTF-8 username:password>

{"protocol":1,"id":"mobile-1","action":"hello","params":{}}
```

`hello` returns `result.protocol:1`, `result.device_type:"modbus_hub"`, and an
`actions` array. Use that array to determine supported commands. Then request
the dashboard, for example:

```json
{"protocol":1,"id":"mobile-2","action":"get_dashboard","params":{}}
```

The HTTPS response body is the Hub's protocol-1 command envelope:

```json
{"id":"mobile-2","ok":true,"result":{"settings":{},"status":{},"outputs":[],"modbus_outputs":[]}}
```

The object above illustrates the envelope and major dashboard sections; actual
fields and channel counts come from the device. Check both HTTP status and
JSON `ok`. A command can return HTTP 200 with `ok:false` and an `error`
string. Match replies using `id`. HTTP command requests are bounded to a
1 MiB body by the current listener. The Hub caches successful authentication
only for the lifetime of that TLS connection; a new connection must
authenticate again. Do not send credentials to port 5005/5006, the normal web
listener, or a plaintext `API_TLS:0` port 5008 session.

## Connection sequence

1. Discover the Hub through UDP, or use its saved address. Read `API_PORT`,
   `API_TLS`, and `DEVICE_ID`. Confirm a first-use identity against trusted
   inventory before saving it.
2. If `API_TLS:1`, connect to the advertised port using TLS. Never fall back to
   plaintext after a TLS failure. Validate the Soleux CA chain, validity time,
   and exact saved device ID from the certificate DNS SAN.
3. Check the certificate serial/fingerprint with the CA status endpoint. Do
   not send the Hub password until certificate checks have passed.
4. Send the credential-free `/api/v1/preflight` request. Require HTTP 200 and
   `ok:true`.
5. Send `/api/v1/command` with the Hub administrator credentials and a `hello`
   request. Read its advertised `actions`; then request `get_dashboard` and
   `get_io_configuration` as needed.
6. Keep device sessions independent. On saved-device credential or address
   changes, close the old connection and start a new validated connection.

For an unsaved TLS Hub, show a login-required state and collect identity and
credentials before opening control screens. Do not poll control commands on an
unauthenticated session. Store credentials in Android Keystore/iOS Keychain
backed app storage, never in plain SQLite or logs.

## Errors and retries

| Result | Mobile behavior |
|---|---|
| TLS handshake, CA, date, DNS identity, or CA status check fails | Stop; show a certificate/identity error. Do not downgrade or send credentials. |
| HTTP 401 on `/api/v1/command` | Stop automatic login retries; ask the user to correct the saved credentials. Includes invalid credentials, account lock, and disallowed roles. |
| HTTP 429 or `retry_after_seconds` / `Retry-After` | Respect the delay and stop rapid retries. |
| HTTP 403 `access_denied` | Check the Hub Security-page TCP IP/MAC allow list and network route. |
| HTTP 400/404/405 | Check body, path, method, and protocol framing; do not retry in a tight loop. |
| HTTP 200 with `ok:false` | Show or handle the command error; this is not a transport success for the action. |
| Network disconnect or Hub reboot | Reconnect with backoff, repeat certificate checks, and authenticate again. |

The Hub locks a web account for 10 minutes after the third failed password, 30
minutes after the fourth, and 24 hours after the fifth or later failure. It
also temporarily rate limits bursts from one source IP. Passwords must not be
retried every discovery or heartbeat cycle.

## Alternative: raw TLS JSON

Use this only if the mobile app needs the Hub's asynchronous TCP events or a
persistent command stream. Connect to `API_PORT` using the same certificate and
CA-status checks, with ALPN `soleux-json`. The server sends a plain-text line
`Soleux JSON API Ready`; discard it. Then send exactly one UTF-8 JSON object
per LF-terminated line. The **first** request must be:

```json
{"protocol":1,"id":"auth-1","action":"authenticate","params":{"username":"<Hub admin username>","password":"<Hub password>"}}
```

Success has `ok:true` and `result.authenticated:true`. A command before login
returns `authentication_required` and closes the connection. A failed login
also closes it. After login, send `hello`, `get_dashboard`, etc. Match replies
by `id`; events have `id:null` and an `event` field and may use `protocol:2`
even though commands use protocol 1. Each raw JSON request line is limited to
1 MiB. See the Hub command specification for event and channel-index details.

## Compatibility boundaries

- `API_TLS:0` is the temporary plaintext migration mode, with no Control API
  authentication. The mobile app must not send credentials in that mode.
- An absent `API_TLS` field is legacy/unknown, not proof that TLS is off.
- The Hub's JSON API is **protocol 1** and its Control API port is currently
  fixed at `5008`. Relay/Dimmer/PDU protocol-2 commands are different.
- The Hub's normal web HTTP/HTTPS port does not expose this full command set.
- Hub output **commands** use one-based channels; asynchronous output events
  use zero-based channel indices. Read counts and capabilities from the Hub.
- The Hub test device and current CA are development infrastructure. Recheck
  trust roots, CA URL, and device rollout status before a production mobile
  release.

## Mobile acceptance checks

1. A trusted, active Hub certificate with the saved device ID connects and
   `hello` plus `get_dashboard` succeed with a valid Hub admin account.
2. Wrong device ID, untrusted/expired/revoked certificate, and unreachable CA
   status service block credential submission.
3. Wrong password, locked account, and TCP allow-list rejection show distinct
   states and do not trigger rapid retries.
4. A Hub IP change works with the **same** certificate identity once discovery
   supplies the new address; a changed identity requires operator review.
5. Reconnection after certificate renewal checks the replacement serial and
   fingerprint again.

Implementation references: active
`Device Firmware/ModBusHub/VirtualTCPListener.py`,
`Device Firmware/ModBusHub/soleux_enrollment_client.py`,
`Device Firmware/ModBusHub/soleux_hub_discovery.py`,
`Infrastructure/SoleuxCA/enrollment_service/soleux_enrollment/app.py`, and
`Windows App/SoleuxControlHTTPS.pas`.

## Mobile app implementation status (this repository)

The Dart/Flutter app implements steps 2–5 of the "Connection sequence" as
follows (status as of 10 November 2026):

| Concern | Implementation |
|---|---|
| `API_TLS` discovery field | Parsed by `lib/core/discovery/module_discovery.dart` into `DiscoveredModule.apiTls` / `DEVICE_ID` into `DiscoveredModule.deviceId`; persisted on `DeviceModule.apiTls` / `DeviceModule.deviceId`. An absent `API_TLS` field applies the device default `0` (plaintext) |
| `API_TLS` heartbeat field | Parsed from the heartbeat pong (`api_tls`, `lib/core/soleux/soleux_heartbeat.dart`) and applied to the stored module by `lib/services/module_status/module_heartbeat_service.dart`, which runs the 30 s UDP heartbeat for **local** devices (foreground lifecycle; remote/cloud and hostname-addressed modules excluded). A pong refreshes `last_seen_at`, `api_port`, `api_version` and the TLS flag; `device_id` is only filled when the module has none saved (the pong is unauthenticated - a saved TLS identity is never rebound). Online/offline follows the same tri-state policy as the 5008 API check (`ModuleApiHealthService.checkOne`): pong = recovery to online, one missed ping = unknown (offline stays offline), three consecutive misses = offline |
| TLS on/off decision | `lib/core/soleux/soleux_tls.dart` (`moduleWantsTls`): code-level override `AppConfig.apiTlsEnabled` wins, then the explicit TLS toggle from the module configuration screen (`DeviceModule.tlsEnabled`, remote connection type only), then a remote (port-forwarding) module defaults to TLS, then the module's advertised `API_TLS`; an absent `API_TLS` field resolves to `0` (plaintext) |
| TLS dial | `lib/services/module_host_resolver.dart` (`connectModuleSocket`): `SecureSocket` with ALPN `soleux-json`, no downgrade to plaintext after a TLS failure - the transport is chosen explicitly per module (configuration-screen TLS toggle / remote default) |
| Trust anchor | `assets/certs/soleux_root_ca.pem` (the Soleux Development root installed from `creds/Soleux-Root-CA.pem`); sole anchor of a dedicated `SecurityContext` (`assets/certs/README.md` explains provisioning). The asset may carry the full CA chain: only the root is anchored, its intermediates become leaf-issuer candidates |
| Hostname validation | Connecting by IP intentionally fails the standard check; `SoleuxTlsOptions.accept` re-judges the hostname mismatch manually: leaf issuer DER byte-identical to the installed root's subject (or an intermediate of the installed chain) and a holding validity window, plus the DNS-SAN == saved-device-ID check when `AppConfig.tlsVerifyHostname` is enabled. With hostname verification **disabled (default)**, a dial that fails with a *hostname-only* verification error is retried accepting the leaf - the chain was already proven to the installed root by the platform (a hostname mismatch is only reported after chain validation succeeds), so chain and validity stay enforced and every other failure reason still fails closed. This also covers device leaves issued via an intermediate CA the app has not shipped |
| 5008 TCP command channel | `ModuleTcpConnection` (`tls:` option) drives the persistent `SoleuxJsonService`, the Hub probe/command paths (`HubJsonProtocol`), the reachability polls and the API health monitor; the raw TLS JSON greeting line is discarded by the existing greeting handling |
| Hub TLS login | Implemented: on a raw TLS JSON session the first request is `authenticate` with the Hub admin credentials (`HubJsonProtocol.authenticate`). Credentials live per module in the OS secure credential store (`lib/services/hub_credential_store.dart`, flutter_secure_storage). The hub control screen shows a sign-in card when the session is unauthenticated and never polls control commands on it; the status probe treats an auth-required hub as reachable, and scenario dispatches authenticate from the stored login. No auto-retry on a rejected login (the Hub locks accounts) |
| Known follow-ups | CA active-status check (§"Certificate status": serial/fingerprint against the trusted CA service) is not yet wired into the connect sequence; hub login strings are not yet localized |

Tests: `test/core/soleux/soleux_x509_test.dart` and
`test/core/soleux/soleux_tls_test.dart` (fixtures:
`test/core/soleux/fixtures/`).
