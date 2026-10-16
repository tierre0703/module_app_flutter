# Soleux Modbus Hub Control API

Implementation status: documented from the active Modbus Hub source as of
15 October 2026.

This document describes the JSON API implemented by
`Device Firmware/ModBusHub/VirtualTCPListener.py`. The Hub is intentionally
different from the Relay Module, Dimmer, and PDU protocol-2 profiles:

- the complete Hub command catalogue uses protocol 1 over raw TCP;
- the JSON listener is currently fixed to TCP port `5008`;
- output command channels are one-based;
- the server sends a plain-text greeting before the first JSON message; and
- the full command catalogue is not exposed through HTTP/HTTPS.

## Ports and interfaces

| Interface | Address | Behavior |
|---|---|---|
| Legacy TCP | Port `5005` | Existing `AT+SETTAG` / `AT+GETTAG` and other legacy commands |
| TCP-lite | Port `5006` | Existing reduced legacy service |
| UDP heartbeat | Port `5007` | Reachability and API metadata |
| Hub JSON API | Port `5008` | Protocol-1, unprefixed, newline-delimited JSON |
| UDP discovery | Port `8000` | Discovery request and callback response |
| HTTP/HTTPS | Web listener, if supplied by the installed build | Optional tag-only API; not the full Hub command catalogue |

The current `VirtualTCPListener.py` defines `PORT = 5005`, `LITE_PORT = 5006`,
and `JSON_PORT = 5008`. Unlike the other Soleux device families, the Hub JSON
port is not calculated dynamically from the `tcp_port` database setting.
Discovery advertises `API_PORT:5008` and `API_VER:1`; clients should use the
advertised API port when available.

Raw TCP is not encrypted. Keep it on a trusted management network and use the
Hub TCP IP/MAC access rules where appropriate.

## TCP greeting and framing

Immediately after a connection to port `5008`, the Hub sends:

```text
Soleux JSON API Ready

```

This is a greeting, not JSON and not a command response. A client must discard
that line, then continue reading. Requests and responses are UTF-8 JSON objects,
one per LF/CRLF-terminated line. Persistent connections and multiple sequential
commands are supported. A `J:` request prefix remains accepted for transition
compatibility, but new clients should send unprefixed JSON.

The maximum line accepted by the current listener is 1 MiB. TCP is a byte
stream: one `recv` call is not guaranteed to contain one complete line.

## Request and response envelope

Recommended request:

```json
{"protocol":1,"id":"hello-1","action":"hello","params":{}}
```

The current TCP dispatcher reads `id`, `action`, and `params`. It tolerates an
omitted `protocol` field, but new integrations should send `protocol:1` to make
the intended contract explicit. `params` defaults to an empty object and must
be an object when supplied. Action names are normalized to lowercase.

Successful response:

```json
{"id":"hello-1","ok":true,"result":{"protocol":1,"device_type":"modbus_hub","actions":[]}}
```

Failed response:

```json
{"id":"hello-1","ok":false,"error":"unknown action: example"}
```

TCP responses echo the request `id`. The outer response currently does not
include a `protocol` field, and TCP errors are strings rather than the
protocol-2 `{code,message}` objects used by Relay/Dimmer/PDU firmware. Clients
should accept both error forms when they support multiple device families.

Send `hello` first. Its `actions` array is the authoritative command list for
the installed firmware.

## Channel and state rules

- Normal-output and Modbus-power-output **command channels are one-based**.
- `channel` accepts integers from 1 through 256, but the row must exist in the
  selected output bank. Use `get_dashboard` or `get_io_configuration` rather
  than assuming a channel count.
- `state` should be a JSON boolean. The current implementation also accepts
  `0`, `1`, `"0"`, and `"1"` for compatibility.
- `turn_off_disable` blocks an OFF request and any timed operation that must
  turn the output off.
- `restart_disable` additionally blocks `restart_modbus_output`.
- Database row `id` values used by `save_io_channel` are not channel numbers.
- Asynchronous event `channel` values are zero-based within their output bank;
  this differs from the one-based command and dashboard channel values. Events
  also include `hardware_pin` and `output_type` to disambiguate them.

## Complete command list

### Identity, dashboard, output control, and tags

| Action | Parameters | Result or behavior |
|---|---|---|
| `hello` | `{}` | `protocol:1`, `device_type:"modbus_hub"`, and the advertised `actions` array |
| `get_device_info` | `{}` | Name, model, application firmware, MCU firmware/hardware, serial, and Ethernet MAC |
| `get_dashboard` | `{}` | Configured counts, live system status, normal outputs, and Modbus power outputs |
| `set_output` | `channel`, `state` | Set one normal output and return its refreshed output record |
| `pulse_output` | `channel` | Turn one normal output on, then off after one second |
| `set_modbus_output` | `channel`, `state` | Set one Modbus power output and return its refreshed output record |
| `restart_modbus_output` | `channel` | Turn one Modbus power output off, then on after ten seconds |
| `get_tag` | `tag_name` | Existing virtual-tag ID, name, tag name, and value |
| `set_tag` | `tag_name`, `value` | Update an existing virtual tag and return ID, tag name, and string value |

`get_dashboard` returns this general shape:

```json
{
  "settings": {
    "output_count": 8,
    "modbus_power_output_count": 4
  },
  "status": {
    "date": "2026-10-15",
    "time": "12:30:00",
    "internal_temp": 31.2,
    "cpu_temp": 48.0,
    "memory_usage": 20.0,
    "cpu_usage": 12.0
  },
  "outputs": [
    {
      "id": 1,
      "channel": 1,
      "name": "Output 1",
      "state": false,
      "turn_off_disable": false,
      "restart_disable": false
    }
  ],
  "modbus_outputs": []
}
```

Output examples:

```json
{"protocol":1,"id":2,"action":"set_output","params":{"channel":1,"state":true}}
{"protocol":1,"id":3,"action":"pulse_output","params":{"channel":1}}
{"protocol":1,"id":4,"action":"set_modbus_output","params":{"channel":1,"state":false}}
{"protocol":1,"id":5,"action":"restart_modbus_output","params":{"channel":1}}
```

Timed operations run in a background thread. A second timed action for the same
output is rejected until the first completes. An accepted response reports
`accepted:true`, `duration_seconds`, and the initial output record. Confirm the
final state through `get_dashboard` or a confirmed hardware event.

Virtual tags must already exist. `tag_name` and the string-converted `value`
are limited to 255 characters.

```json
{"protocol":1,"id":6,"action":"get_tag","params":{"tag_name":"tag_1"}}
{"protocol":1,"id":7,"action":"set_tag","params":{"tag_name":"tag_1","value":"100"}}
```

### System information and logs

| Action | Parameters | Result |
|---|---|---|
| `get_system` | Optional `page` and `page_size` | Identity, versions, runtime information, and one page of logs |
| `clear_system_logs` | Optional `page_size` | Deletes all logs and returns refreshed page 1 |

Pages start at 1. `page_size` defaults to 10 and must be from 1 through 100.
Requests beyond the last page return the last page. Each log item includes
`id`, `date_time`, `tag`, `state`, and `note`.

```json
{"protocol":1,"id":10,"action":"get_system","params":{"page":2,"page_size":25}}
```

The following command is destructive: it deletes every Hub output log, not
only the current page.

```json
{"protocol":1,"id":11,"action":"clear_system_logs","params":{"page_size":25}}
```

### Settings

| Action | Parameters | Result |
|---|---|---|
| `get_settings` | `{}` | Saved general/time/network/DNS settings plus live network state and admin username |
| `save_settings` | `section`, `values` | Saves a section, applies its system operation, and returns refreshed settings |
| `settings_action` | `settings_action`, `values` | Runs a time, NTP, reboot, or factory-reset operation |

Supported `save_settings` sections:

| Section | Fields and validation |
|---|---|
| `general` | `app_name`, required, 1..63 characters; also updates the Linux hostname |
| `time` | `timezone` required (max 100), `time_sync_interval` 1..1440 minutes, `ntp_server` required (max 253), `time_sync_auto` boolean |
| `network` | `ip_setting` = `dynamic` or `static`; `ip_address`, `subnetmask`, and `default_gateway` are required valid IP values in static mode |
| `dns` | `dns_server_1`, `dns_server_2`; each may be empty or a valid IP address |
| `account` | `username` required (max 50), optional `password` and matching `password_confirmation` (max 128) |

Examples:

```json
{"protocol":1,"id":20,"action":"save_settings","params":{"section":"general","values":{"app_name":"Plant Hub"}}}
{"protocol":1,"id":21,"action":"save_settings","params":{"section":"network","values":{"ip_setting":"static","ip_address":"192.168.1.50","subnetmask":"255.255.255.0","default_gateway":"192.168.1.1"}}}
{"protocol":1,"id":22,"action":"save_settings","params":{"section":"dns","values":{"dns_server_1":"1.1.1.1","dns_server_2":"8.8.8.8"}}}
```

Supported `settings_action` values:

| Value | Required values | Effect |
|---|---|---|
| `sync_computer_time` | `datetime` as `YYYY-MM-DD HH:MM:SS` | Sets system time and writes the RTC |
| `set_manual_time` | Same as above | Sets system time and writes the RTC |
| `test_ntp_server` | `ntp_server` | Runs a one-time NTP query |
| `reboot` | `{}` | Schedules a forced reboot after the response |
| `factory_reset` | `confirmation:"FACTORY RESET"` | Resets Hub configuration and schedules a reboot |

```json
{"protocol":1,"id":23,"action":"settings_action","params":{"settings_action":"test_ntp_server","values":{"ntp_server":"time.google.com"}}}
{"protocol":1,"id":24,"action":"settings_action","params":{"settings_action":"factory_reset","values":{"confirmation":"FACTORY RESET"}}}
```

Network, account, HTTPS, reboot, and factory-reset operations can disconnect
clients or make the Hub unreachable. Require explicit operator confirmation.

### Security and certificates

| Action | Parameters | Result |
|---|---|---|
| `get_security` | `{}` | HTTPS state, TCP/API filter state, configured port, allow lists, and certificate information |
| `save_security` | `section`, `values` | Saves one security section and returns refreshed security data |
| `security_action` | `security_action`, `values` | Installs or creates an HTTPS certificate |

Supported `save_security` sections:

- `https`: `ssl_enabled` boolean. Changing it writes the SSL state and schedules
  a Hub reboot.
- `tcp_access`: `filter_enabled`, `tcp_port` (1..65535), `ip_addresses`, and
  `mac_addresses` arrays.
- `api_access`: `filter_enabled`, `ip_addresses`, and `mac_addresses` arrays.

Each allow-list contains at most 256 entries. IP entries accept a single IP,
CIDR range, full range, or abbreviated final-octet range. MAC addresses are
normalized to uppercase colon notation.

The current raw TCP listeners remain fixed at 5005/5006/5008 even though
`tcp_access.tcp_port` is stored and returned. Do not assume changing that field
rebinds `VirtualTCPListener.py`.

`security_action:"update_certificate"` values:

- `key_data`: required Base64 private-key file;
- `certificate_data`: required Base64 certificate file; and
- `chain_data`: optional Base64 certificate chain.

Each decoded file is limited to 2 MiB. The Hub validates the key, certificate,
and public-key match before installation.

`security_action:"generate_self_signed"` values:

- `country`: required two-letter country code;
- `state`: optional;
- `locality`, `organization`, `org_unit`, and `common_name`: required; and
- `email`: optional.

Both certificate actions return certificate information and
`reboot_required:true`.

### Users and permissions

| Action | Parameters | Result |
|---|---|---|
| `get_users` | `{}` | Admin and regular-user records; superadmin is hidden |
| `save_user` | `operation`, optional `user_id`, `values` | Adds, updates, or deletes a regular user and returns the refreshed list |
| `get_user_permissions` | `user_id` | One regular user's permission values |
| `save_user_permissions` | `user_id`, `permissions` object | Saves and returns that regular user's permissions |

`save_user` operations:

- `add`: `values.username`, `values.password`, and matching
  `values.password_confirmation` are required.
- `update`: top-level `user_id`, `values.username`, and optional matching
  password fields. An empty password retains the existing password.
- `delete`: top-level `user_id`; only regular users can be deleted.

Regular-user permission names are:

```text
Dashboard
Settings
Security
System
Configuration
User Management
Help
I/O Configuration
Programming
ModbusScan
Virtual Tag
```

`save_user_permissions.permissions` is an object mapping those exact names to
booleans. Unspecified permissions are saved as false. Admin and superadmin
permissions cannot be edited through these commands.

```json
{"protocol":1,"id":30,"action":"save_user","params":{"operation":"add","values":{"username":"viewer","password":"replace-me","password_confirmation":"replace-me"}}}
{"protocol":1,"id":31,"action":"save_user_permissions","params":{"user_id":2,"permissions":{"Dashboard":true,"System":true}}}
```

### I/O configuration

| Action | Parameters | Result |
|---|---|---|
| `get_io_configuration` | `{}` | Normal and Modbus-power output configuration arrays |
| `save_io_channel` | `kind`, row `id`, `values` | Saves one row and publishes its hardware configuration |
| `rewrite_io_hardware` | `{}` | Publishes every visible output configuration to hardware |

`save_io_channel.kind` is `normal` or `modbus`. `id` is the positive database
row ID returned by `get_io_configuration`, not the channel number.

The `values` object contains:

| Field | Rule |
|---|---|
| `output_name` | Required, maximum 50 characters |
| `tag_name` | Optional, maximum 100 characters, unique when non-empty |
| `output_on_delay` | Integer 0..2147483647 |
| `output_off_delay` | Integer 0..2147483647 |
| `on_runtime` | Integer 0..2147483647 |
| `off_runtime` | Integer 0..2147483647 |
| `start_delay` | Integer 0..2147483647 |
| `initial_state` | 0, 1, or 2 |
| `turn_off_disable` | Boolean |
| `restart_disable` | Boolean |

On/off delay and runtime values are saved in the existing Hub tenths-of-a-second
units; the listener divides them by 10 when publishing to the MCU. `start_delay`
is published without that conversion.

```json
{"protocol":1,"id":40,"action":"save_io_channel","params":{"kind":"normal","id":1,"values":{"output_name":"Main output","tag_name":"main_output","output_on_delay":0,"output_off_delay":0,"on_runtime":0,"off_runtime":0,"start_delay":0,"initial_state":0,"turn_off_disable":false,"restart_disable":false}}}
```

## Settings backup and restore

Hub backups are ZIP archives containing a MySQL dump and the `programming/`
directory. The maximum archive size is 64 MiB and each decoded chunk is at most
6144 bytes.

| Action | Parameters | Result |
|---|---|---|
| `settings_backup_download_begin` | `{}` | Transfer ID, generated filename, size, SHA-256, and chunk size |
| `transfer_download_chunk` | `transfer_id`, `offset`, optional `length` | Base64 data, total size, SHA-256, and `eof` |
| `transfer_download_finish` | `transfer_id` | Cleans up the download session |
| `transfer_upload_begin` | Optional `transfer_id`; `kind`, `role`, `filename`, `size`, optional `sha256` | Starts a restore upload and enters maintenance mode |
| `transfer_upload_chunk` | `transfer_id`, `offset`, Base64 `data` | Updated received byte count |
| `transfer_upload_finish` | `transfer_id` | Verifies size, digest, ZIP structure, SQL dump, and programming data |
| `transfer_commit` | `transfer_id` | Starts detached restore and reports `reboot_required:true` |

Download:

```json
{"protocol":1,"id":50,"action":"settings_backup_download_begin","params":{}}
{"protocol":1,"id":51,"action":"transfer_download_chunk","params":{"transfer_id":"returned-id","offset":0,"length":6144}}
{"protocol":1,"id":52,"action":"transfer_download_finish","params":{"transfer_id":"returned-id"}}
```

Restore requires `kind:"settings_backup"`, `role:"archive"`, and a `.zip`
filename. Upload offsets must equal the number of decoded bytes already received.
When supplied, `transfer_id` must contain 8..80 letters, digits, underscores, or
hyphens. `sha256` is optional but recommended and must contain 64 lowercase or
uppercase hexadecimal characters.

```json
{"protocol":1,"id":60,"action":"transfer_upload_begin","params":{"transfer_id":"client-upload-1","kind":"settings_backup","role":"archive","filename":"hub_settings.zip","size":12345,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}
{"protocol":1,"id":61,"action":"transfer_upload_chunk","params":{"transfer_id":"client-upload-1","offset":0,"data":"BASE64-DATA"}}
{"protocol":1,"id":62,"action":"transfer_upload_finish","params":{"transfer_id":"client-upload-1"}}
{"protocol":1,"id":63,"action":"transfer_commit","params":{"transfer_id":"client-upload-1"}}
```

Restore replaces Hub configuration and programming data and then reboots the
device. Never use a backup from a different device family.

## Asynchronous TCP events

Connected JSON clients can receive events between command responses. Match
responses by `id`; an event has `id:null` and an `event` field.

```json
{"protocol":2,"id":null,"ok":true,"event":"output_state_changed","result":{"channel":0,"hardware_pin":0,"output_type":"local","state":true,"confirmed":true,"revision":1792012345678}}
```

Current events:

| Event | Important result fields |
|---|---|
| `input_state_changed` | `channel`, `state`, `confirmed`, `revision` |
| `output_state_changed` | Zero-based bank `channel`, `hardware_pin`, `output_type`, `state`, `confirmed`, `revision` |
| `system_status` | `captured_at`, sensors, uptime, memory/CPU usage, MCU versions, and LAN IP |

`confirmed:false` means the event represents an API request before hardware
feedback. A later hardware event can report `confirmed:true`. System status is
broadcast approximately every five seconds while JSON clients are connected.

The current event broadcaster uses `protocol:2` even though the Hub request/
response command catalogue identifies itself as protocol 1. Clients should
classify events by `id:null` plus `event`, not by the protocol number alone.

## Optional HTTP tag API

The complete Hub catalogue above is TCP-only. The active
`Device Firmware/ModBusHub/app/routes.py` source does not currently register a
general Control API HTTP route.

Some packaged builds contain `TagAPIController`. In those builds only
`get_tag` and `set_tag` are exposed over HTTP, using protocol 2:

```http
POST /api/v1/command
Content-Type: application/json

{"protocol":2,"id":70,"action":"get_tag","params":{"tag_name":"tag_1"}}
```

The same optional build can expose:

```text
POST /api/set-tag
GET  /api/get-tag?tag_name=tag_1
POST /api/get-tag
```

Those HTTP routes use the HTTP API IP/MAC allow list. Commands such as
`get_dashboard`, `save_settings`, output control, user management, and transfers
must not be assumed to work through `/api/v1/command`; use TCP port `5008`.

## Discovery metadata

The Hub discovery GUID is:

```text
199865F4-45A9-489F-BE72-9D6F75A92B4C
```

Representative UDP callback fields:

```text
GUID:199865F4-45A9-489F-BE72-9D6F75A92B4C
VER:7.21
PORT:5005
SN:0000000012345678
NAME:Plant Modbus Hub
API_PORT:5008
API_VER:1
CAPS:modbus_gateway,heartbeat,l2
```

Layer-2 discovery and heartbeat expose the same identity and API-port metadata.

## Recommended client sequence

1. Discover the Hub or obtain its IP address.
2. Connect to advertised `API_PORT`, currently `5008`.
3. Start a continuous line reader.
4. Discard the `Soleux JSON API Ready` greeting.
5. Send `hello` and inspect its `actions` array.
6. Read `get_dashboard` and `get_io_configuration` before enabling controls.
7. Match command replies by `id` and process `id:null` events separately.
8. Reconnect with backoff after network changes, restore, factory reset, or reboot.

The desktop test tool is available at
`Tools/Soleux API Test App/soleux_api_test_app.py`. Select **Modbus Hub**, use
TCP, and send `hello` first.

## Safety notes

- Output commands can switch mains-powered equipment. Confirm potentially
  hazardous operations with the operator.
- Respect `turn_off_disable` and `restart_disable` from dashboard/configuration
  responses.
- Treat network, account, security, certificate, user, restore, factory-reset,
  and reboot actions as privileged operations.
- Do not expose unauthenticated raw TCP control to the Internet.
- A successful command response can precede physical hardware confirmation;
  use a confirmed event or a refreshed dashboard snapshot.

## Automated verification

Run the standalone API tester tests:

```powershell
python -m unittest -v "Tools\Soleux API Test App\test_soleux_api_test_app.py"
```

The deployed Hub protocol contracts can be checked with:

```powershell
python -m unittest -v `
  "Device Firmware\Deployment\V7.20\ModbusHub\ModBusHub\tests\test_hub_json_protocol.py" `
  "Device Firmware\Deployment\V7.20\ModbusHub\ModBusHub\tests\test_broadcast_contract.py" `
  "Device Firmware\Deployment\V7.20\ModbusHub\ModBusHub\tests\test_tag_http_api.py"
```

These tests use fake databases, Redis, sockets, and HTTP objects. They do not
connect to or operate a physical Hub.
