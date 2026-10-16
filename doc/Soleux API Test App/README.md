# Soleux API Test App

A dependency-free Python desktop application for testing the Soleux JSON Control API on:

- Relay Module
- AC/DC Dimmer
- PDU Energy Meter
- High Power PDU / PDU 10 kW
- PDU 1.0
- Modbus Hub

The five Relay/Dimmer/PDU profiles use protocol 2. Modbus Hub uses its implemented protocol 1 command catalogue. The tester supports unprefixed JSON over TCP and the identical command envelope over HTTP or HTTPS. It never sends legacy `AT+` or `J:` commands.

## Start the tester

Double-click `run_soleux_api_test_app.bat`, or run:

```powershell
python "Tools\Soleux API Test App\soleux_api_test_app.py"
```

Python 3.10 or newer with the standard Tkinter component is required.

## Connection fields

- **Device IP / host:** Address of the real device, for example `192.168.1.184`.
- **Base / AT port:** Configured base port, normally `5005`. The tester calculates the TCP Control API as this value plus 3.
- **Device profile:** Choose a family to show only its supported commands and protocol version, or leave **Auto detect / all** selected.
- **Transport:** `TCP`, `HTTP`, or `HTTPS`.
- **Verify HTTPS certificate:** Leave disabled for a local self-signed certificate. Enable it when the certificate is trusted and matches the host name.

TCP connects to `device:(base port + 3)`, normally port `5008`. HTTP and HTTPS use `POST /api/v1/command` on web ports 80 and 443.

## Recommended first test

1. Enter the device IP.
2. Leave the base port at `5005` unless the device uses another configured port.
3. Leave **Auto detect / all** selected.
4. Select `TCP` or `HTTP`.
5. Select `hello` and click **Send command**.

When `hello` succeeds, the tester recognizes either the protocol-2 `device` field or the Modbus Hub `device_type` field, displays the detected family, and automatically switches the command list and protocol version to that profile. The raw request and complete response remain visible for copying.

## Device-specific commands

The common profiles include identity, live state, I/O control, configuration pages, log pagination/deletion, and supported backup/transfer commands.

- **Dimmer:** adds `set_dimmer_level`, `set_dimmer_frequency`, and the
  `get_output_groups`, `save_output_group`, `delete_output_group`, and
  `rewrite_output_groups` commands. PWM values are integers from 0 through 100.
- **PDU Energy Meter:** adds `get_energy_state` and `get_energy_history`.
- **High Power PDU:** excludes Energy Meter-only commands.
- **PDU 1.0:** excludes input, mapping, Dimmer, energy, and hardware-write commands that its firmware does not support.
- **Modbus Hub:** uses protocol 1 and adds dashboard, normal/Modbus output control, virtual tags, system logs, settings, security, users, permissions, I/O configuration, and backup/restore commands. Its output channels are one-based.

Relay, Dimmer, and PDU Control API input/output channels begin at `0`. Modbus Hub normal and Modbus power-output channels begin at `1`. Commands that can change configuration or physical state display a confirmation dialog by default.

## System logs

Read a paginated system page with:

```json
{"page":"system","log_page":1,"log_page_size":10}
```

Select `execute_page_action` and use the following parameters to delete logs:

```json
{"page":"system","page_action":"delete_system_logs","log_page_size":10}
```

Deletion is a state-changing command and requires confirmation.

## Troubleshooting

- **TCP failure:** verify that **Enable TCP** (`tcp_enabled`) is on in the device Security page, that the device listens on the calculated Control API port, and that the network permits it. When disabled, base, base + 1, and base + 3 are all closed even though discovery/heartbeat may still work.
- **HTTP 403:** add the PC address to the device HTTP API IP/MAC allow list, or disable filtering only on a controlled test network.
- **HTTP 503 / `api_disabled`:** turn on **Enable API** (`api_enabled`) in the device Security page. This switch affects HTTP/HTTPS commands but does not close raw Control API TCP.
- **HTTPS certificate error:** use the device's trusted host name/certificate or temporarily clear certificate verification for a local self-signed test.
- **HTTP 307:** expected when SSL is enabled and HTTP redirects to HTTPS.
- **Unknown action:** confirm the correct device profile and deploy matching updated firmware.

## Automated tests

From this directory:

```powershell
python -m unittest -v test_soleux_api_test_app.py
```

The test suite uses local mock TCP/HTTP servers and does not connect to or change a real device.
