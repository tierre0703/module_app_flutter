"""Small desktop client for exercising Soleux device Control APIs.

Uses only the Python standard library.  The same JSON request can be sent over
the newline-JSON TCP service or POST /api/v1/command over HTTP(S).  Protocol-2
Relay Modules, Dimmers and PDU families are supported together with the
protocol-1 Modbus Hub, without using legacy AT or J-prefixed commands.
"""

from __future__ import annotations

import json
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

try:
    import tkinter as tk
    from tkinter import messagebox, scrolledtext, ttk
except ImportError:  # The protocol client and its tests do not require Tk.
    tk = None
    messagebox = None
    scrolledtext = None
    ttk = None


PROTOCOL_VERSION = 2
MODBUS_HUB_PROTOCOL_VERSION = 1
CONTROL_API_PORT_OFFSET = 3
MAX_MESSAGE_BYTES = 1024 * 1024
TCP_GREETING_LINES = {"Soleux JSON API Ready", "TCP Server Ready"}


COMMAND_PRESETS: dict[str, dict[str, Any]] = {
    "hello": {},
    "get_relay_configuration": {},
    "get_device_info": {},
    "get_device_state": {},
    "set_input_state": {"channel": 0, "state": True, "source": "API Tester"},
    "set_virtual_input_state": {"channel": 0, "state": True, "source": "API Tester"},
    "set_output_state": {"channel": 0, "state": True, "source": "API Tester"},
    "restart_output": {"channel": 0, "source": "API Tester"},
    "set_dimmer_level": {"channel": 0, "value": 50},
    "set_dimmer_frequency": {"value": 1},
    "get_output_groups": {},
    "save_output_group": {
        "group": {
            "name": "Example group", "master_channel": 0,
            "local_slaves": [1], "remote_slaves": []
        }
    },
    "delete_output_group": {"group_id": 1},
    "rewrite_output_groups": {},
    "get_energy_state": {},
    "get_energy_history": {
        "parameter": 0, "start_date": "2026-09-01", "end_date": "2026-09-04"
    },
    "write_hardware": {},
    "get_page_configuration": {"page": "system", "log_page": 1, "log_page_size": 10},
    "set_page_configuration": {"page": "settings", "section": "general", "values": {}},
    "execute_page_action": {"page_action": "test_ntp_server", "server": "pool.ntp.org"},
    "mutate_page_row": {"page": "", "section": "", "operation": "update", "id": 0, "values": {}},
    "transfer_upload_begin": {
        "transfer_id": "replace-me", "kind": "settings_backup", "role": "database",
        "filename": "device_settings.db", "size": 1, "sha256": ""
    },
    "transfer_upload_chunk": {
        "transfer_id": "replace-me", "role": "database", "offset": 0, "data": "AA=="
    },
    "transfer_upload_finish": {"transfer_id": "replace-me", "role": "database"},
    "transfer_commit": {"transfer_id": "replace-me"},
    "settings_backup_download_begin": {},
    "transfer_download_chunk": {"transfer_id": "replace-me", "offset": 0, "length": 49152},
    "transfer_download_finish": {"transfer_id": "replace-me"},
    "set_input_configuration": {"channel": 0, "name": "Input 1", "enabled": True},
    "set_output_configuration": {
        "channel": 0, "name": "Output 1", "on_delay": 0, "off_delay": 0,
        "on_runtime": 0, "off_runtime": 0, "start_delay": 0, "initial_state": 0
    },
    "set_mapping": {"input": 0, "output": 0, "code": 1},
    "get_dashboard": {},
    "set_output": {"channel": 1, "state": True},
    "pulse_output": {"channel": 1},
    "set_modbus_output": {"channel": 1, "state": True},
    "restart_modbus_output": {"channel": 1},
    "set_tag": {"tag_name": "example_tag", "value": "1"},
    "get_tag": {"tag_name": "example_tag"},
    "get_system": {"page": 1, "page_size": 10},
    "clear_system_logs": {"page_size": 10},
    "get_settings": {},
    "save_settings": {
        "section": "general", "values": {"app_name": "Modbus Hub"}
    },
    "settings_action": {
        "settings_action": "test_ntp_server",
        "values": {"server": "pool.ntp.org"},
    },
    "get_security": {},
    "save_security": {
        "section": "https", "values": {"ssl_enabled": False}
    },
    "security_action": {
        "security_action": "generate_self_signed", "values": {}
    },
    "get_users": {},
    "save_user": {
        "operation": "add",
        "values": {
            "username": "api_test_user", "password": "replace-me",
            "password_confirmation": "replace-me",
        },
    },
    "get_user_permissions": {"user_id": 1},
    "save_user_permissions": {"user_id": 1, "permissions": {}},
    "get_io_configuration": {},
    "save_io_channel": {
        "kind": "normal", "id": 1,
        "values": {
            "output_name": "Output 1", "tag_name": "",
            "output_on_delay": 0, "output_off_delay": 0,
            "on_runtime": 0, "off_runtime": 0, "start_delay": 0,
            "initial_state": 0, "turn_off_disable": False,
            "restart_disable": False,
        },
    },
    "rewrite_io_hardware": {},
}


PROFILE_AUTO = "Auto detect / all"
PROFILE_RELAY = "Relay Module"
PROFILE_DIMMER = "AC/DC Dimmer"
PROFILE_ENERGY = "PDU Energy Meter"
PROFILE_HIGH_POWER = "High Power PDU"
PROFILE_PDU_V1 = "PDU 1.0"
PROFILE_MODBUS_HUB = "Modbus Hub"

COMMON_ACTIONS = (
    "hello", "get_device_info", "get_device_state", "get_relay_configuration",
    "set_output_state", "restart_output", "set_output_configuration",
    "get_page_configuration", "set_page_configuration", "execute_page_action",
    "mutate_page_row", "transfer_upload_begin", "transfer_upload_chunk",
    "transfer_upload_finish", "transfer_commit", "settings_backup_download_begin",
    "transfer_download_chunk", "transfer_download_finish",
)

INPUT_MAPPING_ACTIONS = (
    "set_input_state", "set_virtual_input_state", "set_input_configuration",
    "set_mapping", "write_hardware",
)

TRANSFER_ACTIONS = (
    "transfer_upload_begin", "transfer_upload_chunk", "transfer_upload_finish",
    "transfer_commit", "settings_backup_download_begin",
    "transfer_download_chunk", "transfer_download_finish",
)

MODBUS_HUB_ACTIONS = (
    "hello", "get_dashboard", "set_output", "pulse_output",
    "set_modbus_output", "restart_modbus_output", "set_tag", "get_tag",
    "get_device_info", "get_system", "clear_system_logs", "get_settings",
    "save_settings", "settings_action", *TRANSFER_ACTIONS,
    "get_security", "save_security", "security_action", "get_users",
    "save_user", "get_user_permissions", "save_user_permissions",
    "get_io_configuration", "save_io_channel", "rewrite_io_hardware",
)

DEVICE_PROFILES: dict[str, tuple[str, ...]] = {
    PROFILE_AUTO: tuple(COMMAND_PRESETS),
    PROFILE_RELAY: COMMON_ACTIONS + INPUT_MAPPING_ACTIONS,
    PROFILE_DIMMER: COMMON_ACTIONS + INPUT_MAPPING_ACTIONS + (
        "set_dimmer_level", "set_dimmer_frequency", "get_output_groups",
        "save_output_group", "delete_output_group", "rewrite_output_groups",
    ),
    PROFILE_ENERGY: COMMON_ACTIONS + INPUT_MAPPING_ACTIONS + (
        "get_energy_state", "get_energy_history",
    ),
    PROFILE_HIGH_POWER: COMMON_ACTIONS + INPUT_MAPPING_ACTIONS,
    PROFILE_PDU_V1: COMMON_ACTIONS,
    PROFILE_MODBUS_HUB: MODBUS_HUB_ACTIONS,
}

DEVICE_TYPE_TO_PROFILE = {
    "relay_module": PROFILE_RELAY,
    "dimmer": PROFILE_DIMMER,
    "pdu_energy_meter": PROFILE_ENERGY,
    "pdu_10kw": PROFILE_HIGH_POWER,
    "pdu_v1": PROFILE_PDU_V1,
    "modbus_hub": PROFILE_MODBUS_HUB,
}

PROFILE_PRESET_OVERRIDES: dict[str, dict[str, dict[str, Any]]] = {
    PROFILE_DIMMER: {
        "set_output_configuration": {
            "channel": 0, "name": "Dimmer 1", "on_delay": 0, "off_delay": 5,
            "on_runtime": 0, "off_runtime": 100, "initial_state": 0, "pwm": 50,
        },
    },
    PROFILE_PDU_V1: {
        "set_output_configuration": {
            "channel": 0, "name": "Output 1",
            "turn_off_disable": False, "restart_disable": False,
        },
    },
}

ACTION_DESCRIPTIONS = {
    "hello": "Detect the device family, protocol and advertised capabilities.",
    "get_device_info": "Read model, serial number, firmware and MAC addresses.",
    "get_device_state": "Read one live zero-based state snapshot.",
    "set_input_state": "Inject one physical/input state using a zero-based channel.",
    "set_virtual_input_state": "Compatibility alias for input-state injection.",
    "set_output_state": "Turn one zero-based output on or off.",
    "restart_output": "Run the device's restart operation on one output.",
    "set_dimmer_level": "Set a Dimmer output to an integer PWM value from 0 to 100.",
    "set_dimmer_frequency": "Set the Dimmer frequency mode; value 1 is valid for AC and DC.",
    "get_output_groups": "Read all local and remote Dimmer output groups.",
    "save_output_group": "Create or update one Dimmer output group.",
    "delete_output_group": "Delete one Dimmer output group by ID.",
    "rewrite_output_groups": "Rewrite local group masks and wait for the MCU acknowledgement.",
    "get_energy_state": "Read current Energy Meter values.",
    "get_energy_history": "Read Energy Meter history for a parameter and date range.",
    "get_page_configuration": "Read a configuration page; system supports log pagination.",
    "execute_page_action": "Run a page action such as NTP test, reboot or log deletion.",
    "get_dashboard": "Read Modbus Hub status plus normal and Modbus output states.",
    "set_output": "Set one Modbus Hub normal output using a one-based channel.",
    "pulse_output": "Pulse one Modbus Hub normal output using a one-based channel.",
    "set_modbus_output": "Set one Modbus Hub power output using a one-based channel.",
    "restart_modbus_output": "Restart one Modbus Hub power output using a one-based channel.",
    "set_tag": "Set an existing Modbus Hub virtual tag by tag name.",
    "get_tag": "Read an existing Modbus Hub virtual tag by tag name.",
    "get_system": "Read Modbus Hub identity, runtime status and paginated logs.",
    "clear_system_logs": "Delete all Modbus Hub system logs.",
    "get_settings": "Read Modbus Hub general, time and network settings.",
    "get_security": "Read Modbus Hub HTTPS, TCP and HTTP API access settings.",
    "get_users": "Read Modbus Hub non-superadmin users.",
    "get_io_configuration": "Read Modbus Hub normal and Modbus output configuration.",
}


READ_ONLY_ACTIONS = {
    "hello",
    "get_relay_configuration",
    "get_device_info",
    "get_device_state",
    "get_energy_state",
    "get_energy_history",
    "get_page_configuration",
    "get_output_groups",
    "get_dashboard",
    "get_tag",
    "get_system",
    "get_settings",
    "get_security",
    "get_users",
    "get_user_permissions",
    "get_io_configuration",
    "settings_backup_download_begin",
    "transfer_download_chunk",
    "transfer_download_finish",
}


def actions_for_profile(profile: str) -> tuple[str, ...]:
    """Return actions in stable preset order for one UI device profile."""
    if profile not in DEVICE_PROFILES:
        raise ValueError("Unknown device profile: " + str(profile))
    return tuple(
        action for action in DEVICE_PROFILES[profile]
        if action in COMMAND_PRESETS)


def preset_for_action(profile: str, action: str) -> dict[str, Any]:
    """Return a detached preset so editing the UI cannot mutate constants."""
    if action not in COMMAND_PRESETS:
        raise ValueError("Unknown command preset: " + str(action))
    preset = PROFILE_PRESET_OVERRIDES.get(profile, {}).get(
        action, COMMAND_PRESETS[action])
    return json.loads(json.dumps(preset))


def protocol_for_profile(profile: str) -> int:
    """Return the request protocol used by one UI device profile."""
    if profile not in DEVICE_PROFILES:
        raise ValueError("Unknown device profile: " + str(profile))
    if profile == PROFILE_MODBUS_HUB:
        return MODBUS_HUB_PROTOCOL_VERSION
    return PROTOCOL_VERSION


def profile_from_hello_response(response: Any) -> str | None:
    """Map a successful hello result to a UI profile."""
    if not isinstance(response, dict) or response.get("ok") is not True:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    device_type = result.get("device") or result.get("device_type", "")
    return DEVICE_TYPE_TO_PROFILE.get(str(device_type).lower())


class ControlApiError(RuntimeError):
    """A network, framing or response error raised by ControlApiClient."""


@dataclass
class ApiResult:
    endpoint: str
    transport: str
    elapsed_ms: int
    request: dict[str, Any]
    response: Any
    raw_response: str
    status_code: int | None = None


def control_api_port(legacy_port: int) -> int:
    port = int(legacy_port) + CONTROL_API_PORT_OFFSET
    if port < 1 or port > 65535:
        raise ValueError("Calculated Control API port is outside 1-65535")
    return port


def build_request(
    action: str,
    params: dict[str, Any],
    request_id: str,
    protocol_version: int = PROTOCOL_VERSION,
) -> dict[str, Any]:
    action = str(action).strip()
    if not action:
        raise ValueError("An action is required")
    if not isinstance(params, dict):
        raise ValueError("Parameters must be one JSON object")
    protocol_version = int(protocol_version)
    if protocol_version < 1:
        raise ValueError("Protocol version must be a positive integer")
    return {
        "protocol": protocol_version,
        "id": request_id,
        "action": action,
        "params": params,
    }


def decode_json_response(raw_response: str) -> Any:
    try:
        return json.loads(raw_response)
    except json.JSONDecodeError as error:
        preview = raw_response[:500].replace("\r", "\\r").replace("\n", "\\n")
        raise ControlApiError("Device returned invalid JSON: " + preview) from error


class ControlApiClient:
    def __init__(
        self,
        host: str,
        legacy_port: int = 5005,
        timeout: float = 5.0,
        verify_tls: bool = True,
        http_port: int = 80,
        https_port: int = 443,
    ) -> None:
        host = host.strip()
        if not host:
            raise ValueError("A device IP address or host name is required")
        self.host = host
        self.legacy_port = int(legacy_port)
        self.timeout = float(timeout)
        self.verify_tls = bool(verify_tls)
        self.http_port = int(http_port)
        self.https_port = int(https_port)
        if self.timeout <= 0:
            raise ValueError("Timeout must be greater than zero")

    @property
    def tcp_port(self) -> int:
        return control_api_port(self.legacy_port)

    def send(self, transport: str, request_data: dict[str, Any]) -> ApiResult:
        transport = transport.strip().upper()
        if transport == "TCP":
            return self.send_tcp(request_data)
        if transport in ("HTTP", "HTTPS"):
            return self.send_http(request_data, use_tls=(transport == "HTTPS"))
        raise ValueError("Transport must be TCP, HTTP or HTTPS")

    def send_tcp(self, request_data: dict[str, Any]) -> ApiResult:
        payload = json.dumps(request_data, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(payload) > MAX_MESSAGE_BYTES:
            raise ControlApiError("Request exceeds the 1 MiB Control API limit")
        endpoint = "%s:%d" % (self.host, self.tcp_port)
        started = time.perf_counter()
        pending = bytearray()
        bytes_received = 0
        raw_response = ""
        decoded_response: Any = None
        try:
            with socket.create_connection((self.host, self.tcp_port), self.timeout) as connection:
                connection.settimeout(self.timeout)
                connection.sendall(payload)
                while decoded_response is None:
                    block = connection.recv(4096)
                    if not block:
                        break
                    bytes_received += len(block)
                    if bytes_received > MAX_MESSAGE_BYTES:
                        raise ControlApiError("TCP response exceeds the 1 MiB limit")
                    pending.extend(block)
                    while b"\n" in pending:
                        raw_line, unused_separator, remainder = pending.partition(b"\n")
                        pending = bytearray(remainder)
                        line = raw_line.rstrip(b"\r").decode(
                            "utf-8", errors="replace").strip()
                        if not line or line in TCP_GREETING_LINES:
                            continue
                        candidate = decode_json_response(line)
                        if (isinstance(candidate, dict) and
                                candidate.get("id") is None and
                                "event" in candidate):
                            # A device event may race with the requested reply.
                            continue
                        raw_response = line
                        decoded_response = candidate
                        break
        except (OSError, socket.timeout) as error:
            raise ControlApiError("TCP connection to %s failed: %s" % (endpoint, error)) from error
        elapsed_ms = round((time.perf_counter() - started) * 1000)
        if decoded_response is None and pending:
            line = bytes(pending).rstrip(b"\r").decode(
                "utf-8", errors="replace").strip()
            if line and line not in TCP_GREETING_LINES:
                raw_response = line
                decoded_response = decode_json_response(line)
        if decoded_response is None:
            raise ControlApiError("TCP connection closed without a JSON response")
        return ApiResult(
            endpoint=endpoint,
            transport="TCP",
            elapsed_ms=elapsed_ms,
            request=request_data,
            response=decoded_response,
            raw_response=raw_response,
        )

    def send_http(self, request_data: dict[str, Any], use_tls: bool = False) -> ApiResult:
        scheme = "https" if use_tls else "http"
        port = self.https_port if use_tls else self.http_port
        default_port = 443 if use_tls else 80
        port_text = "" if port == default_port else ":%d" % port
        endpoint = "%s://%s%s/api/v1/command" % (scheme, self.host, port_text)
        payload = json.dumps(request_data, separators=(",", ":")).encode("utf-8")
        if len(payload) > MAX_MESSAGE_BYTES:
            raise ControlApiError("Request exceeds the 1 MiB Control API limit")
        http_request = urllib.request.Request(
            endpoint,
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        context = None
        if not self.verify_tls:
            # This context also applies if an HTTP request receives the device's
            # expected 307 redirect to an HTTPS endpoint with a self-signed cert.
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(http_request, timeout=self.timeout, context=context) as response:
                status_code = response.status
                raw_bytes = response.read(MAX_MESSAGE_BYTES + 1)
        except urllib.error.HTTPError as error:
            status_code = error.code
            raw_bytes = error.read(MAX_MESSAGE_BYTES + 1)
        except (urllib.error.URLError, OSError, TimeoutError) as error:
            raise ControlApiError("%s request failed: %s" % (scheme.upper(), error)) from error
        elapsed_ms = round((time.perf_counter() - started) * 1000)
        if len(raw_bytes) > MAX_MESSAGE_BYTES:
            raise ControlApiError("HTTP response exceeds the 1 MiB limit")
        raw_response = raw_bytes.decode("utf-8", errors="replace").strip()
        if not raw_response:
            raise ControlApiError("HTTP %d returned an empty response" % status_code)
        return ApiResult(
            endpoint=endpoint,
            transport=scheme.upper(),
            status_code=status_code,
            elapsed_ms=elapsed_ms,
            request=request_data,
            response=decode_json_response(raw_response),
            raw_response=raw_response,
        )


class SoleuxApiTestApp:
    def __init__(self, root: Any) -> None:
        self.root = root
        self.root.title("Soleux API Test App")
        self.root.geometry("1040x820")
        self.root.minsize(880, 690)
        self.request_counter = 0
        self.last_output = ""

        self.host_var = tk.StringVar(value="192.168.1.184")
        self.legacy_port_var = tk.StringVar(value="5005")
        self.control_port_var = tk.StringVar(value="5008")
        self.transport_var = tk.StringVar(value="TCP")
        self.timeout_var = tk.StringVar(value="5")
        self.verify_tls_var = tk.BooleanVar(value=False)
        self.confirm_writes_var = tk.BooleanVar(value=True)
        self.device_profile_var = tk.StringVar(value=PROFILE_AUTO)
        self.detected_device_var = tk.StringVar(value="Not detected")
        self.command_hint_var = tk.StringVar(value=ACTION_DESCRIPTIONS.get("hello", ""))
        self.action_var = tk.StringVar(value="hello")
        self.status_var = tk.StringVar(value="Ready")

        self._build_ui()
        self.legacy_port_var.trace_add("write", self._update_control_port)
        self._load_preset()

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.root, padding=12)
        outer.grid(row=0, column=0, sticky="nsew")
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(3, weight=1)

        connection = ttk.LabelFrame(outer, text="Device connection", padding=10)
        connection.grid(row=0, column=0, sticky="ew")
        for column in range(8):
            connection.columnconfigure(column, weight=1 if column in (1, 5) else 0)

        ttk.Label(connection, text="Device IP / host").grid(row=0, column=0, sticky="w")
        ttk.Entry(connection, textvariable=self.host_var, width=22).grid(row=0, column=1, sticky="ew", padx=(6, 14))
        ttk.Label(connection, text="Base / AT port").grid(row=0, column=2, sticky="w")
        ttk.Entry(connection, textvariable=self.legacy_port_var, width=8).grid(row=0, column=3, padx=(6, 14))
        ttk.Label(connection, text="Control port").grid(row=0, column=4, sticky="w")
        ttk.Label(connection, textvariable=self.control_port_var).grid(row=0, column=5, sticky="w", padx=(6, 14))
        ttk.Label(connection, text="Timeout (s)").grid(row=0, column=6, sticky="w")
        ttk.Entry(connection, textvariable=self.timeout_var, width=7).grid(row=0, column=7, padx=(6, 0))

        ttk.Label(connection, text="Device profile").grid(row=1, column=0, sticky="w", pady=(10, 0))
        profile = ttk.Combobox(
            connection, textvariable=self.device_profile_var,
            values=tuple(DEVICE_PROFILES), state="readonly", width=20)
        profile.grid(row=1, column=1, sticky="ew", padx=(6, 14), pady=(10, 0))
        profile.bind("<<ComboboxSelected>>", lambda unused_event: self._profile_changed())
        ttk.Label(connection, text="Detected").grid(row=1, column=2, sticky="w", pady=(10, 0))
        ttk.Label(connection, textvariable=self.detected_device_var).grid(
            row=1, column=3, columnspan=2, sticky="w", padx=(6, 14), pady=(10, 0))

        ttk.Label(connection, text="Transport").grid(row=2, column=0, sticky="w", pady=(10, 0))
        transport = ttk.Combobox(
            connection, textvariable=self.transport_var, values=("TCP", "HTTP", "HTTPS"),
            state="readonly", width=10)
        transport.grid(row=2, column=1, sticky="w", padx=(6, 14), pady=(10, 0))
        ttk.Checkbutton(
            connection, text="Verify HTTPS certificate", variable=self.verify_tls_var
        ).grid(row=2, column=2, columnspan=3, sticky="w", pady=(10, 0))
        ttk.Checkbutton(
            connection, text="Confirm state-changing commands", variable=self.confirm_writes_var
        ).grid(row=2, column=5, columnspan=3, sticky="w", pady=(10, 0))

        command = ttk.LabelFrame(outer, text="Command", padding=10)
        command.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        command.columnconfigure(1, weight=1)
        ttk.Label(command, text="Action").grid(row=0, column=0, sticky="w")
        self.action_combo = ttk.Combobox(
            command, textvariable=self.action_var,
            values=actions_for_profile(PROFILE_AUTO), state="readonly")
        self.action_combo.grid(row=0, column=1, sticky="ew", padx=(6, 8))
        self.action_combo.bind("<<ComboboxSelected>>", lambda unused_event: self._load_preset())
        ttk.Button(command, text="Hello", command=lambda: self._select_action("hello")).grid(row=0, column=2, padx=3)
        ttk.Button(command, text="Device info", command=lambda: self._select_action("get_device_info")).grid(row=0, column=3, padx=3)
        ttk.Button(command, text="Device state", command=lambda: self._select_action("get_device_state")).grid(row=0, column=4, padx=3)

        ttk.Label(command, textvariable=self.command_hint_var).grid(
            row=1, column=0, columnspan=5, sticky="w", pady=(8, 0))
        ttk.Label(command, text="Parameters (JSON object)").grid(
            row=2, column=0, columnspan=5, sticky="w", pady=(8, 4))
        self.params_text = scrolledtext.ScrolledText(command, height=8, wrap=tk.NONE, font=("Consolas", 10))
        self.params_text.grid(row=3, column=0, columnspan=5, sticky="ew")

        buttons = ttk.Frame(outer)
        buttons.grid(row=2, column=0, sticky="ew", pady=10)
        self.send_button = ttk.Button(buttons, text="Send command", command=self._send_selected)
        self.send_button.pack(side=tk.LEFT)
        ttk.Button(buttons, text="Clear response", command=self._clear_response).pack(side=tk.LEFT, padx=6)
        ttk.Button(buttons, text="Copy response", command=self._copy_response).pack(side=tk.LEFT)
        ttk.Label(buttons, textvariable=self.status_var).pack(side=tk.RIGHT)

        response_frame = ttk.LabelFrame(outer, text="Request and response", padding=8)
        response_frame.grid(row=3, column=0, sticky="nsew")
        response_frame.rowconfigure(0, weight=1)
        response_frame.columnconfigure(0, weight=1)
        self.response_text = scrolledtext.ScrolledText(
            response_frame, wrap=tk.NONE, font=("Consolas", 10), state=tk.DISABLED)
        self.response_text.grid(row=0, column=0, sticky="nsew")

    def _update_control_port(self, *unused_args: Any) -> None:
        try:
            self.control_port_var.set(str(control_api_port(int(self.legacy_port_var.get()))))
        except (TypeError, ValueError):
            self.control_port_var.set("-")

    def _select_action(self, action: str) -> None:
        if action not in actions_for_profile(self.device_profile_var.get()):
            self.device_profile_var.set(PROFILE_AUTO)
            self._profile_changed(select_first=False)
        self.action_var.set(action)
        self._load_preset()

    def _profile_changed(self, select_first: bool = True) -> None:
        actions = actions_for_profile(self.device_profile_var.get())
        self.action_combo.configure(values=actions)
        if self.action_var.get() not in actions:
            self.action_var.set(actions[0] if select_first and actions else "hello")
        self._load_preset()

    def _load_preset(self) -> None:
        action = self.action_var.get()
        params = preset_for_action(self.device_profile_var.get(), action)
        self.params_text.delete("1.0", tk.END)
        self.params_text.insert("1.0", json.dumps(params, indent=2))
        self.command_hint_var.set(ACTION_DESCRIPTIONS.get(
            action, "Edit the JSON parameters, then send this Control API command."))

    def _send_selected(self) -> None:
        try:
            params = json.loads(self.params_text.get("1.0", tk.END).strip() or "{}")
            if not isinstance(params, dict):
                raise ValueError("Parameters must be a JSON object")
            action = self.action_var.get()
            legacy_port = int(self.legacy_port_var.get())
            timeout = float(self.timeout_var.get())
            client = ControlApiClient(
                host=self.host_var.get(), legacy_port=legacy_port, timeout=timeout,
                verify_tls=self.verify_tls_var.get())
            self.request_counter += 1
            request_data = build_request(
                action, params, "tester-%d-%d" % (int(time.time()), self.request_counter),
                protocol_for_profile(self.device_profile_var.get()))
        except (ValueError, json.JSONDecodeError) as error:
            messagebox.showerror("Invalid request", str(error), parent=self.root)
            return

        if (self.confirm_writes_var.get() and action not in READ_ONLY_ACTIONS and
                not messagebox.askyesno(
                    "Confirm command",
                    "%s may change device configuration or physical state. Send it?" % action,
                    parent=self.root)):
            return

        self.send_button.configure(state=tk.DISABLED)
        self.status_var.set("Sending...")
        transport = self.transport_var.get()

        def worker() -> None:
            try:
                result = client.send(transport, request_data)
            except Exception as error:
                self.root.after(
                    0, lambda caught=error: self._show_error(
                        caught, request_data, transport))
            else:
                self.root.after(0, lambda: self._show_result(result))

        threading.Thread(target=worker, daemon=True).start()

    def _show_result(self, result: ApiResult) -> None:
        detected_profile = profile_from_hello_response(result.response)
        if detected_profile:
            self.detected_device_var.set(detected_profile)
            if self.device_profile_var.get() == PROFILE_AUTO:
                self.device_profile_var.set(detected_profile)
                self._profile_changed(select_first=False)
        status = "" if result.status_code is None else "\nHTTP status: %d" % result.status_code
        output = (
            "Endpoint: %s\nTransport: %s%s\nElapsed: %d ms\n\nREQUEST\n%s\n\nRESPONSE\n%s\n"
            % (
                result.endpoint,
                result.transport,
                status,
                result.elapsed_ms,
                json.dumps(result.request, indent=2),
                json.dumps(result.response, indent=2),
            )
        )
        self._set_response(output)
        ok = isinstance(result.response, dict) and result.response.get("ok") is True
        if ok and detected_profile:
            self.status_var.set("Connected to " + detected_profile)
        else:
            self.status_var.set("Success" if ok else "Device returned an error")
        self.send_button.configure(state=tk.NORMAL)

    def _show_error(self, error: Exception, request_data: dict[str, Any], transport: str) -> None:
        output = (
            "Transport: %s\n\nREQUEST\n%s\n\nCLIENT ERROR\n%s\n"
            % (transport, json.dumps(request_data, indent=2), error)
        )
        self._set_response(output)
        self.status_var.set("Connection/test failed")
        self.send_button.configure(state=tk.NORMAL)

    def _set_response(self, output: str) -> None:
        self.last_output = output
        self.response_text.configure(state=tk.NORMAL)
        self.response_text.delete("1.0", tk.END)
        self.response_text.insert("1.0", output)
        self.response_text.configure(state=tk.DISABLED)

    def _clear_response(self) -> None:
        self._set_response("")
        self.status_var.set("Ready")

    def _copy_response(self) -> None:
        if self.last_output:
            self.root.clipboard_clear()
            self.root.clipboard_append(self.last_output)
            self.status_var.set("Copied")


def main() -> None:
    if tk is None:
        raise SystemExit("Tkinter is not installed. Install the standard Python Tcl/Tk component.")
    root = tk.Tk()
    SoleuxApiTestApp(root)
    root.mainloop()


# Backward-compatible imports for scripts that used the original Relay names.
RelayApiError = ControlApiError
RelayApiClient = ControlApiClient
SoleuxApiTesterApp = SoleuxApiTestApp
RelayApiTesterApp = SoleuxApiTestApp


if __name__ == "__main__":
    main()
