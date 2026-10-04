#!/usr/bin/env python3
"""
Soleux Module Dummy Server

A single-process simulator for one Soleux device. Implements the wire
contracts from:

  * doc/Soleux-Network-Discovery-and-DCP.md
  * doc/Soleux-Mobile-TCP-Protocol.md

and mirrors the constants in lib/core/soleux/*.dart and the command surfaces
of lib/services/module_status/*.dart. It is a development/test substitute for
the physical hardware (Stage 3 of doc/description.md).

Implemented services:

  1. UDP broadcast discovery on port 8000 with a TCP callback response
     (section 1 of the discovery doc). Advertises the Control API port.
  2. Soleux DCP / Layer-2 commissioning over raw Ethernet frames with
     EtherType 0x88B5 (section 2). Raw sockets require Linux with
     root/CAP_NET_RAW; the server disables DCP gracefully elsewhere.
  3. Unicast UDP heartbeat on the fixed well-known port 5007 (section 3).
  4. A persistent TCP command server (default 5008) on the shared command
     HostPort that answers the legacy `AT+...` protocol, the legacy `J:`
     JSON framing AND the plain-JSON Control API envelope on the same socket.
  5. The Control API catalogue actions (ping, set_output_state, toggle_output,
     restart_output, set_dimmer_level, get_outputs, get_inputs,
     get_device_state, get_capabilities, get_mappings) plus the implemented
     protocol 2 subset (relay/page/transfer actions).

Usage:

    python doc/module_dummy_server.py                          # relay module
    python doc/module_dummy_server.py --device dimmer
    python doc/module_dummy_server.py --device pdu_energy_meter
    python doc/module_dummy_server.py --device pdu_10kw
    python doc/module_dummy_server.py --device pdu_v1
    python doc/module_dummy_server.py --device dimmer --name "Lobby Lights"

Device families (GUID + JSON `hello` device value):

    relay_module      579E6EA1-2F64-4CDE-8190-1CD3646EFAA1
    dimmer            C47A5A88-03E8-4EC0-9F2D-67A6C43F0D91
    pdu_energy_meter  56EC974B-1C9F-48C3-B438-BFE976593072
    pdu_10kw          A728DD7D-0DEB-49B9-9B8B-A4556771815F
    pdu_v1            B4A6B160-0CBA-4BD8-873D-EDC9DF895C26
"""

import argparse
import base64
import ipaddress
import json
import socket
import struct
import threading
import time
from datetime import datetime, timedelta, timezone

# ─── Well-known protocol constants (doc / lib/core/soleux) ───────────────────

DISCOVERY_REQUEST_GUID = "8C93472D-2EF0-4B82-BE96-4FBBED57783F"
DISCOVERY_PROTOCOL_VERSION = "2.0"
DISCOVERY_PORT = 8000
DEFAULT_TCP_PORT = 5008
CONTROL_API_PORT = DEFAULT_TCP_PORT  # the command HostPort IS the Control API port
CONTROL_API_VERSION = 3              # target catalogue version
HEARTBEAT_PORT = 5007                # fixed well-known UDP heartbeat port
ETHER_TYPE_L2 = 0x88B5
ETH_MIN_FRAME = 60  # without FCS

MAPPING_CODES = {"NONE": 0, "ON": 1, "OFF": 2, "TOGGLE": 3,
                 "CONTINUEON": 4, "CONTINUEOFF": 5}
ENERGY_PARAMS = {0: ("V", 229.7), 1: ("A", 1.25), 2: ("W", 274.2),
                 3: ("", 0.955), 4: ("VA", 287.1), 5: ("kWh", 18.42)}

# JSON actions (SoleuxJsonActions). Full "relay-style" set.
COMMON_ACTIONS = {
    "hello", "get_relay_configuration", "get_page_configuration",
    "set_page_configuration", "mutate_page_row", "execute_page_action",
}
RELAY_ACTIONS = COMMON_ACTIONS | {
    "set_input_configuration", "set_output_configuration", "set_mapping",
    "set_virtual_input_state", "trigger_virtual_input",
    "write_hardware", "settings_backup_download_begin", "transfer_upload_begin",
    "transfer_upload_chunk", "transfer_upload_finish", "transfer_download_chunk",
    "transfer_download_finish", "transfer_commit",
}

PAGES = ("automation", "schedule", "settings", "security", "system")

# ─── Device family registry ──────────────────────────────────────────────────


def _profile(key, guid, json_device, label, name, serial,
             input_count, virtual_input_count, output_count,
             is_dimmer=False, has_energy=False, has_energy_history=False,
             json_actions=RELAY_ACTIONS, omit_protocol=False):
    return {
        "key": key, "guid": guid.upper(), "json_device": json_device,
        "label": label, "name": name, "serial": serial,
        "input_count": input_count, "virtual_input_count": virtual_input_count,
        "output_count": output_count, "is_dimmer": is_dimmer,
        "has_energy": has_energy, "has_energy_history": has_energy_history,
        "json_actions": frozenset(json_actions),
        "omit_protocol": omit_protocol,
    }


DEVICE_PROFILES = {
    "relay_module": _profile(
        "relay_module", "579E6EA1-2F64-4CDE-8190-1CD3646EFAA1",
        "relay_module", "Relay Module", "Plant Room Relays",
        "0000000012345678", 8, 2, 8),
    "dimmer": _profile(
        "dimmer", "C47A5A88-03E8-4EC0-9F2D-67A6C43F0D91",
        "dimmer", "AC/DC Dimmer", "Lobby Dimmer",
        "0000000012349999", 4, 0, 4,
        is_dimmer=True,
        json_actions=RELAY_ACTIONS | {"set_dimmer_frequency"}),
    "pdu_energy_meter": _profile(
        "pdu_energy_meter", "56EC974B-1C9F-48C3-B438-BFE976593072",
        "pdu_energy_meter", "PDU Energy Meter", "Rack PDU",
        "0000000012340001", 2, 1, 8,
        has_energy=True, has_energy_history=True,
        json_actions=RELAY_ACTIONS | {"get_energy_history"}),
    "pdu_10kw": _profile(
        "pdu_10kw", "A728DD7D-0DEB-49B9-9B8B-A4556771815F",
        "pdu_10kw", "PDU 10 kW", "Main Distribution PDU",
        "0000000012340002", 2, 0, 4, has_energy=True),
    "pdu_v1": _profile(
        "pdu_v1", "B4A6B160-0CBA-4BD8-873D-EDC9DF895C26",
        "pdu_v1", "PDU V1.0", "Legacy Rack PDU",
        "0000000012340003", 0, 0, 7,
        has_energy=True, json_actions=COMMON_ACTIONS, omit_protocol=True),
}

# ─── Small helpers ───────────────────────────────────────────────────────────


def now_str():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def uptime_str(start):
    delta = timedelta(seconds=int(time.time() - start))
    days = delta.days
    hours, remainder = divmod(delta.seconds, 3600)
    minutes, _ = divmod(remainder, 60)
    return f"{days} days, {hours} hours" if days else f"{hours} hours, {minutes} minutes"


def parse_mac(text):
    """Normalise `02:81:F9:30:81:F9` / `02-81-...` to bytes."""
    cleaned = text.strip().replace("-", ":").replace(" ", "")
    return bytes.fromhex(cleaned.replace(":", ""))


def mac_text(mac_bytes):
    return ":".join(f"{b:02X}" for b in mac_bytes)


def is_contiguous_mask(mask_str):
    try:
        mask = ipaddress.IPv4Address(mask_str)
    except ipaddress.AddressValueError:
        return False
    if int(mask) == 0:
        return False
    bits = f"{int(mask):032b}"
    return "01" not in bits


# ─── Device state ────────────────────────────────────────────────────────────


class ModuleState:
    """Mutable simulated hardware state for one device."""

    def __init__(self, profile, name, serial, ip, mask, gateway, mac,
                 firmware="7.10"):
        self.profile = profile
        self.name = name or profile["name"]
        self.serial = serial or profile["serial"]
        self.firmware = firmware
        self.ip = ip
        self.mask = mask
        self.gateway = gateway
        self.mac = parse_mac(mac)

        self.inputs = [
            {"name": f"Switch {i + 1}", "state": False, "enabled": 1,
             "mode": "momentary"}
            for i in range(profile["input_count"])
        ]
        self.virtual_inputs = [
            {"name": f"Virtual {i + 1}", "state": False, "enabled": 1,
             "mode": "momentary"}
            for i in range(profile["virtual_input_count"])
        ]
        self.outputs = []
        for ch in range(profile["output_count"]):
            out = {
                "name": f"Output {ch + 1}",
                "state": (ch % 2 == 0),
                "on_delay": 0, "off_delay": 0,
                "on_run_time": 0, "off_run_time": 0,
                "start_delay": 0, "initial_state": 0,
                "turn_off_disable": False, "restart_disable": False,
            }
            if profile["is_dimmer"]:
                out["state"] = True
                out["pwm"] = 60 if ch == 0 else 0
            self.outputs.append(out)

        self.mapping = {}          # (input, output) -> code
        self.schedules = []
        self.override = False      # PDU manual override
        self.dimmer_frequency = 50.0

    @property
    def heartbeat_port(self):
        return HEARTBEAT_PORT


# ─── JSON protocol helpers ───────────────────────────────────────────────────


def json_response(state, req_id, result=None, ok=True, error=None):
    body = {}
    if not state.profile["omit_protocol"]:
        body["protocol"] = 2
    body["id"] = req_id
    body["ok"] = ok
    if ok:
        body["result"] = result if result is not None else {}
    else:
        body["error"] = error if error is not None else {"code": "error"}
    return "J:" + json.dumps(body, ensure_ascii=False) + "\r\n"


def hello_result(state):
    p = state.profile
    return {
        "protocol": 2, "device": p["json_device"], "name": state.name,
        "input_count": p["input_count"],
        "virtual_input_count": p["virtual_input_count"],
        "output_count": p["output_count"],
    }


def relay_config_result(state):
    p = state.profile
    inputs = []
    for ch, inp in enumerate(state.inputs):
        inputs.append({
            "channel": ch, "input_name": inp["name"],
            "input_state": inp["state"], "input_enabled": inp["enabled"],
        })
    outputs = []
    for ch, out in enumerate(state.outputs):
        entry = {
            "channel": ch, "output_name": out["name"],
            "output_state": out["state"], "output_on_delay": out["on_delay"],
            "output_off_delay": out["off_delay"],
            "output_on_run_time": out["on_run_time"],
            "output_off_run_time": out["off_run_time"],
            "start_delay": out["start_delay"],
            "initial_state": out["initial_state"],
            "turn_off_disable": out["turn_off_disable"],
            "restart_disable": out["restart_disable"],
        }
        if p["is_dimmer"]:
            entry["pwm"] = out.get("pwm", 0)
        outputs.append(entry)
    return {
        "input_count": p["input_count"],
        "virtual_input_count": p["virtual_input_count"],
        "output_count": p["output_count"],
        "inputs": inputs,
        "outputs": outputs,
        "mapping": [
            {"input": i, "output": o, "code": c}
            for (i, o), c in sorted(state.mapping.items())
        ],
    }


def uptime_ms():
    return int((time.time() - start_time) * 1000)


# Control API response envelope (plain JSON line, no J: prefix), echoing the
# negotiated protocol version from the request.
def ctrl_json(state, req_id, protocol, result=None, ok=True, error=None):
    body = {"protocol": protocol, "id": req_id, "ok": ok}
    if ok:
        body["result"] = result if result is not None else {}
    else:
        body["error"] = error if error is not None else {"code": "error"}
    return json.dumps(body, ensure_ascii=False) + "\r\n"


def control_api_hello(state, req_id):
    p = state.profile
    return {
        "protocol": 2, "device": p["json_device"], "name": state.name,
        "input_count": p["input_count"],
        "virtual_input_count": p["virtual_input_count"],
        "output_count": p["output_count"],
        "api_port": CONTROL_API_PORT, "session_id": f"session-{req_id}",
        "authentication_required": False,
    }


def outputs_payload(state):
    p = state.profile
    outs = []
    for ch, out in enumerate(state.outputs):
        entry = {
            "channel": ch, "name": out["name"], "enabled": True,
            "state": out["state"], "pending": False,
            "changed_at": now_str(),
        }
        if p["is_dimmer"]:
            entry["set_pwm"] = float(out.get("pwm", 0))
            entry["actual_pwm"] = float(out.get("pwm", 0))
            # Legacy field aliases, kept for older clients.
            entry["requested_level"] = float(out.get("pwm", 0))
            entry["actual_level"] = float(out.get("pwm", 0))
        outs.append(entry)
    return outs


def inputs_payload(state):
    physical = [
        {"kind": "physical", "channel": ch, "name": inp["name"],
         "enabled": bool(inp["enabled"]), "state": inp["state"],
         "mode": inp["mode"]}
        for ch, inp in enumerate(state.inputs)
    ]
    virtual = [
        {"kind": "virtual", "channel": ch, "name": vin["name"],
         "enabled": bool(vin["enabled"]), "state": vin["state"],
         "mode": vin["mode"]}
        for ch, vin in enumerate(state.virtual_inputs)
    ]
    return physical, virtual


# Legacy numeric mapping-code -> control behaviour name (spec §5.1).
CODE_TO_BEHAVIOR = {0: "none", 1: "on", 2: "off", 3: "toggle",
                    4: "continuous_on", 5: "continuous_off"}


def _release_virtual(state, channel):
    if 0 <= channel < len(state.virtual_inputs):
        state.virtual_inputs[channel]["state"] = False
        broadcast_input_change(
            state, state.profile["input_count"] + channel, False)


def build_page(state, page, log_page=1, log_page_size=10,
               log_from=None, log_to=None, log_tag=None):
    p = state.profile
    common = {
        "device": p["json_device"], "name": state.name,
        "serial": state.serial, "firmware": state.firmware,
        "guid": p["guid"], "ip": state.ip, "mask": state.mask,
        "gateway": state.gateway,
    }
    sections = [{"section": "info", "fields": common}]
    if page == "schedule":
        sections.append({"section": "schedule", "rows": state.schedules})
    if page == "security":
        sections.append({"section": "acl", "rows": []})
    if page == "settings":
        sections.append({"section": "network",
                         "fields": {"ip": state.ip, "mask": state.mask,
                                    "gateway": state.gateway, "dhcp": False}})
    if page == "system":
        sections.append({"section": "actions", "fields": {"reboot": True,
                                                          "sync_time": True}})
        sections.append(system_logs_section(state, log_page, log_page_size,
                                            log_from, log_to, log_tag))
    return {"page": page, "device": p["json_device"], "sections": sections}


SYSTEM_LOG_COLUMNS = [
    {"key": "date_time", "label": "Date / Time"},
    {"key": "tag", "label": "Tag"},
    {"key": "state", "label": "Status"},
    {"key": "note", "label": "Note"},
]

SYSTEM_LOG_NOTES = [
    "Duty Set", "Request from Web", "Request from App",
    "Output changed", "Firmware updated", "Reboot scheduled", "OFF",
]


def _system_log_pool():
    base = datetime.now().replace(second=0, microsecond=0)
    rows = []
    for i in range(3661):
        rows.append({
            "note": SYSTEM_LOG_NOTES[i % len(SYSTEM_LOG_NOTES)],
            "date_time": (base - timedelta(minutes=i)).strftime(
                "%Y/%m/%d %H:%M:%S"),
            "state": "ON" if i % 3 else "OFF",
            "tag": f"Out-{(i % 4) + 1}",
        })
    return rows


def system_logs_section(state, page, page_size, log_from=None, log_to=None,
                        log_tag=None):
    pool = _system_log_pool()
    if log_from or log_to:
        def _parse(v):
            return datetime.strptime(v, "%Y-%m-%d %H:%M:%S")
        frm = _parse(log_from) if log_from else datetime.min
        to = _parse(log_to) if log_to else datetime.max
        pool = [r for r in pool
                if frm <= datetime.strptime(r["date_time"],
                                            "%Y/%m/%d %H:%M:%S") <= to]
    if log_tag:
        pool = [r for r in pool if r["tag"] == log_tag]
    total = len(pool)
    total_pages = max(1, (total + page_size - 1) // page_size)
    page = max(1, min(page, total_pages))
    start = (page - 1) * page_size
    rows = pool[start: start + page_size]
    return {
        "key": "system_logs",
        "title": "System Logs",
        "description": f"Most recent device events ({total} total).",
        "can_delete": True,
        "page": page,
        "page_size": page_size,
        "total_pages": total_pages,
        "total_count": total,
        "rows": rows,
        "fields": [],
        "columns": SYSTEM_LOG_COLUMNS,
    }


def _output_config_result(out, channel):
    return {
        "channel": channel, "output_name": out["name"],
        "output_on_delay": out["on_delay"], "output_off_delay": out["off_delay"],
        "output_on_run_time": out["on_run_time"],
        "output_off_run_time": out["off_run_time"],
        "start_delay": out["start_delay"],
        "initial_state": out["initial_state"],
        "turn_off_disable": out["turn_off_disable"],
        "restart_disable": out["restart_disable"],
    }


# ─── JSON action handlers ────────────────────────────────────────────────────


class RequestError(Exception):
    def __init__(self, message, code="internal_error"):
        super().__init__(message)
        self.code = code
        self.message = message


def _validate_delay_runtime(params):
    for key in ("on_delay", "off_delay", "on_runtime", "off_runtime",
                "start_delay"):
        if key in params and not (0 <= int(params[key]) <= 65000):
            raise RequestError("delay and runtime values must be between "
                               "0 and 65000")


def _channel_output(state, channel):
    if not (0 <= channel < state.profile["output_count"]):
        raise RequestError(f"channel {channel} out of range",
                           "invalid_channel")
    return state.outputs[channel]


def handle_json_action(state, action, params, req_id):
    p = state.profile

    if action == "hello":
        return hello_result(state)

    if action == "get_relay_configuration":
        return relay_config_result(state)

    if action == "get_page_configuration":
        page = params.get("page")
        if page not in PAGES:
            raise RequestError(f"unknown page '{page}'")
        return build_page(state, page,
                          log_page=int(params.get("log_page", 1) or 1),
                          log_page_size=int(params.get("log_page_size", 10) or 10),
                          log_from=params.get("log_from"),
                          log_to=params.get("log_to"),
                          log_tag=params.get("log_tag"))

    if action == "set_page_configuration":
        page = params.get("page", "")
        section = params.get("section", "")
        if page not in PAGES:
            raise RequestError(f"unknown page '{page}'")
        result = {"page": page, "section": section, "saved": True}
        result["configuration"] = build_page(state, page)
        return result

    if action == "mutate_page_row":
        page = params.get("page", "")
        section = params.get("section", "")
        operation = params.get("operation", "")
        row_id = params.get("id", req_id)
        if page not in PAGES:
            raise RequestError(f"unknown page '{page}'")
        if operation not in ("add", "update", "delete"):
            raise RequestError(f"invalid operation '{operation}'")
        return {
            "page": page, "section": section, "operation": operation,
            "id": row_id, "saved": True,
            "values": {k: v for k, v in params.get("values", {}).items()},
        }

    if action == "execute_page_action":
        page_action = params.get("page_action", "")
        result = {"page_action": page_action, "status": "ok"}

        def _reboot_later():
            time.sleep(2)
            broadcast_close_all()
        if page_action == "reboot":
            threading.Thread(target=_reboot_later, daemon=True).start()
        return result

    if action == "set_input_configuration":
        channel = int(params.get("channel", -1))
        if not (0 <= channel < p["input_count"]):
            raise RequestError(f"input {channel} out of range")
        inp = state.inputs[channel]
        if "name" in params:
            inp["name"] = str(params["name"])
        if "enabled" in params:
            inp["enabled"] = 1 if params["enabled"] else 0
        if "mode" in params:
            mode = str(params["mode"])
            if mode not in ("momentary", "maintained", "pulse"):
                raise RequestError(f"invalid mode '{mode}'",
                                   "invalid_configuration")
            inp["mode"] = mode
        return {"channel": channel, "saved": True}

    if action == "set_output_configuration":
        channel = int(params.get("channel", -1))
        out = _channel_output(state, channel)
        _validate_delay_runtime(params)
        mapping = {
            "name": "name", "on_delay": "on_delay", "off_delay": "off_delay",
            "on_runtime": "on_run_time", "off_runtime": "off_run_time",
            "start_delay": "start_delay", "initial_state": "initial_state",
            "turn_off_disable": "turn_off_disable",
            "restart_disable": "restart_disable",
        }
        for src, dst in mapping.items():
            if src in params:
                out[dst] = params[src]
        if p["is_dimmer"] and "pwm" in params:
            pwm = int(params["pwm"])
            out["pwm"] = max(0, min(100, pwm))
            out["state"] = out["pwm"] > 0
        if p["is_dimmer"]:
            return {"channel": channel, "saved": True}
        return _output_config_result(out, channel)

    if action == "set_mapping":
        input_ch = int(params.get("input", -1))
        output_ch = int(params.get("output", -1))
        code = int(params.get("code", -1))
        if not (0 <= input_ch < p["input_count"]):
            raise RequestError(f"input {input_ch} out of range")
        if not (0 <= output_ch < p["output_count"]):
            raise RequestError(f"output {output_ch} out of range")
        if code not in MAPPING_CODES.values():
            raise RequestError(f"invalid mapping code {code}")
        state.mapping[(input_ch, output_ch)] = code
        return {"input": input_ch, "output": output_ch, "code": code}

    if action == "set_dimmer_frequency":
        value = params.get("frequency", params.get("value"))
        if value is None:
            raise RequestError("missing 'frequency' parameter")
        state.dimmer_frequency = float(value)
        return {"frequency": state.dimmer_frequency, "saved": True}

    if action == "write_hardware":
        return {"saved": True}

    if action == "settings_backup_download_begin":
        return {"settings_backup": True, "size": 0, "accepted": True}

    if action in ("transfer_upload_begin", "transfer_upload_chunk",
                  "transfer_upload_finish", "transfer_download_chunk",
                  "transfer_download_finish", "transfer_commit"):
        return {"accepted": True, "size": 0}

    if action == "get_energy_history":
        try:
            parameter = int(params.get("parameter", -1))
            start = datetime.strptime(params["start_date"], "%Y-%m-%d")
            end = datetime.strptime(params["end_date"], "%Y-%m-%d")
        except (KeyError, ValueError):
            raise RequestError("start_date/end_date must be YYYY-MM-DD")
        if parameter not in ENERGY_PARAMS:
            raise RequestError(f"invalid energy parameter {parameter}")
        if end < start:
            raise RequestError("end_date precedes start_date")
        if (end - start).days > 365:
            raise RequestError("date range must not exceed 365 days")
        unit, base = ENERGY_PARAMS[parameter]
        points = []
        day = start
        idx = 0
        while day <= end:
            ts = day.strftime("%Y-%m-%d 12:00:00")
            value = round(base + (idx % 5) * 0.1, 3)
            points.append({"timestamp": ts, "value": value})
            day += timedelta(days=1)
            idx += 1
            if len(points) > 366:
                break
        return {
            "energy_history": True, "parameter": parameter, "unit": unit,
            "start_date": params["start_date"], "end_date": params["end_date"],
            "points": points,
        }

    raise RequestError(f"action '{action}' not supported")


# ─── Control API actions (spec v0.2 catalogue + implemented subset) ──────────

# Implemented protocol 2 subset also served on the Control API port
# (relay state/configuration operations, page configuration and actions,
# file-transfer operations).
CONTROL_API_IMPLEMENTED_SUBSET = (RELAY_ACTIONS | COMMON_ACTIONS |
                                  {"set_dimmer_frequency", "get_energy_history"})

# Catalogue actions replacing the legacy AT+ control commands.
CONTROL_API_CATALOGUE = {
    "ping", "set_output_state", "toggle_output", "restart_output",
    "set_dimmer_level", "get_outputs", "get_inputs", "get_device_state",
    "get_capabilities", "get_mappings",
}

CONTROL_API_ACTIONS = CONTROL_API_IMPLEMENTED_SUBSET | CONTROL_API_CATALOGUE


def handle_control_api_action(state, action, params, req_id):
    p = state.profile

    if action == "ping":
        return {"server_time": now_str(), "uptime_ms": uptime_ms()}

    if action == "set_output_state":
        ch = int(params.get("channel", -1))
        out = _channel_output(state, ch)
        st = params.get("state")
        if not isinstance(st, bool):
            raise RequestError("missing/invalid 'state'", "invalid_parameter")
        out["state"] = st
        if p["is_dimmer"]:
            out["pwm"] = 100 if st else 0
        broadcast_output_change(state, ch)
        return {"channel": ch, "requested_state": st,
                "actual_state": out["state"], "pending": False, "revision": 1}

    if action == "toggle_output":
        ch = int(params.get("channel", -1))
        out = _channel_output(state, ch)
        out["state"] = not out["state"]
        if p["is_dimmer"]:
            out["pwm"] = 100 if out["state"] else 0
        broadcast_output_change(state, ch)
        return {"channel": ch, "actual_state": out["state"],
                "pending": False, "revision": 1}

    if action == "restart_output":
        ch = int(params.get("channel", -1))
        _channel_output(state, ch)
        out = state.outputs[ch]
        if out["restart_disable"]:
            raise RequestError("restart disabled", "output_disabled")
        out["state"] = False
        if p["is_dimmer"]:
            out["pwm"] = 0
        broadcast_output_change(state, ch)
        return {"channel": ch, "accepted": True, "off_time_ms": 100,
                "operation_id": f"restart-{req_id}"}

    if action == "set_dimmer_level":
        if not p["is_dimmer"]:
            raise RequestError("dimmer level not supported",
                               "unsupported_command")
        ch = int(params.get("channel", -1))
        out = _channel_output(state, ch)
        level = float(params.get("level", -1))
        if not (0.0 <= level <= 100.0):
            raise RequestError("level must be between 0 and 100",
                               "invalid_level")
        out["pwm"] = int(round(level))
        out["state"] = out["pwm"] > 0
        broadcast_output_change(state, ch)
        return {"channel": ch, "requested_level": level,
                "actual_level": float(out["pwm"]), "transitioning": False,
                "operation_id": None}

    if action == "get_outputs":
        return {"outputs": outputs_payload(state), "revision": 1}

    if action == "get_inputs":
        physical, virtual = inputs_payload(state)
        return {"inputs": physical, "virtual_inputs": virtual, "revision": 1}

    if action == "set_virtual_input_state":
        channel = int(params.get("channel", -1))
        if not (0 <= channel < len(state.virtual_inputs)):
            raise RequestError(f"virtual input {channel} out of range")
        vin = state.virtual_inputs[channel]
        if not vin["enabled"]:
            raise RequestError("virtual input disabled", "input_disabled")
        new_state = bool(params.get("state", False))
        changed = vin["state"] != new_state
        vin["state"] = new_state
        if changed:
            broadcast_input_change(state,
                                   p["input_count"] + channel, new_state)
        return {"channel": channel, "state": new_state, "changed": changed}

    if action == "trigger_virtual_input":
        channel = int(params.get("channel", -1))
        if not (0 <= channel < len(state.virtual_inputs)):
            raise RequestError(f"virtual input {channel} out of range")
        vin = state.virtual_inputs[channel]
        if not vin["enabled"]:
            raise RequestError("virtual input disabled", "input_disabled")
        duration = int(params.get("duration_ms", 100))
        vin["state"] = True
        broadcast_input_change(state, p["input_count"] + channel, True)
        threading.Timer(duration / 1000.0,
                        lambda: _release_virtual(state, channel)).start()
        return {"channel": channel, "triggered": True,
                "release_in_ms": duration}

    if action == "get_device_state":
        physical, virtual = inputs_payload(state)
        return {"revision": 1, "captured_at": now_str(),
                "inputs": physical, "virtual_inputs": virtual,
                "outputs": outputs_payload(state),
                "sensors": [], "faults": []}

    if action == "get_capabilities":
        return {
            "commands": [
                {"action": a, "permission": "control" if a in
                 ("set_output_state", "toggle_output", "restart_output",
                  "set_dimmer_level") else "read"}
                for a in sorted(CONTROL_API_ACTIONS)
            ],
            "events": [], "features": ["dimmer"] if p["is_dimmer"] else [],
            "transports": {"tcp": True, "http": True, "https": False},
            "limits": {"max_request_bytes": 1048576, "max_batch": 16},
        }

    if action == "get_mappings":
        return {
            "inputs": p["input_count"], "outputs": p["output_count"],
            "mappings": [
                {"input": i, "output": o,
                 "behavior": CODE_TO_BEHAVIOR.get(c, "none"), "legacy_code": c}
                for (i, o), c in sorted(state.mapping.items())
            ],
            "behavior_codes": dict(CODE_TO_BEHAVIOR),
        }

    if action == "hello":
        return control_api_hello(state, req_id)

    # Implemented protocol 2 subset (relay/page/transfer actions).
    return handle_json_action(state, action, params, req_id)


# ─── TCP client registry + broadcast ─────────────────────────────────────────

tcp_clients = {}
tcp_clients_lock = threading.Lock()

# Clients on the shared 5008 command port. Control API clients get the
# protocol-2 JSON broadcast events (Soleux-Mobile-TCP-Protocol.md); AT-only
# clients get the legacy `OUT:`/`IN:` status lines.
tcp_api_clients = set()


def send_tcp(sock, text):
    try:
        sock.sendall(text.encode("utf-8"))
    except Exception:
        pass


def broadcast(text):
    """Sends a legacy text line to the AT-only legacy clients."""
    with tcp_clients_lock:
        for client_id, sock in list(tcp_clients.items()):
            if client_id in tcp_api_clients:
                continue
            send_tcp(sock, text)


def broadcast_api(line):
    """Sends a protocol-2 JSON broadcast line to the Control API clients."""
    with tcp_clients_lock:
        for client_id, sock in list(tcp_clients.items()):
            if client_id in tcp_api_clients:
                send_tcp(sock, line)


def broadcast_event(event, result):
    """Protocol-2 broadcast envelope: id null, ok true, payload under result."""
    return json.dumps({"protocol": 2, "id": None, "ok": True,
                       "event": event, "result": result},
                      ensure_ascii=False) + "\r\n"


def broadcast_close_all():
    with tcp_clients_lock:
        for sock in list(tcp_clients.values()):
            try:
                sock.close()
            except Exception:
                pass
        tcp_clients.clear()
        tcp_api_clients.clear()


def broadcast_output_change(state, ch):
    out = state.outputs[ch]
    line_out = f"OUT:{ch}:{'ON' if out['state'] else 'OFF'}\r\n"
    if state.profile["is_dimmer"]:
        line_out += f"PWM:{ch}:{out.get('pwm', 0)}\r\n"
    broadcast(line_out)
    broadcast_api(broadcast_event("output_state_changed", {
        "channel": ch, "state": out["state"],
        "revision": int(time.time() * 1000),
    }))


def broadcast_input_change(state, ch, value):
    """Protocol-2 `input_state_changed` broadcast for a physical/virtual
    input. `ch` is the zero-based input number from the Control API's point of
    view (virtual inputs are offset by `input_count` so they land after the
    physical inputs the app lists)."""
    if value is None:
        return
    broadcast_api(broadcast_event("input_state_changed", {
        "channel": ch, "state": bool(value),
        "revision": int(time.time() * 1000),
    }))


def system_status_payload(state):
    cpu = 12.5
    return {
        "revision": int(time.time() * 1000),
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "sensors": [{"sensor_id": "external", "value_c": 25.4},
                    {"sensor_id": "cpu", "value_c": 47.0}],
        "system": {
            "time": now_str(),
            "uptime": uptime_str(start_time),
            "external_temp_c": 25.4,
            "cpu_temp_c": 47.0,
            "free_memory_mb": 184,
            "total_memory_mb": 512,
            "used_memory_mb": 328,
            "memory_usage_percent": 64.06,
            "cpu_usage_percent": cpu,
        },
        "network": {
            "lan_ip": state.ip,
            "wifi_ip": "192.168.1.51",
            "wifi_ssid": "Office WiFi",
        },
    }


def broadcast_system_status(state):
    broadcast_api(broadcast_event("system_status", system_status_payload(state)))


def system_status_sender(state):
    while True:
        time.sleep(5)
        broadcast_system_status(state)


def broadcast_energy_line(state):
    if state.profile["has_energy"]:
        v, i, pw, ap, pf, e = (229.7, 1.25, 274.2, 287.1, 0.955, 18.42)
        broadcast(f"GETENERGY:{v}:{i}:{pw}:{ap}:{pf}:{e}:E\r\n")


# ─── Legacy AT+ command handler ──────────────────────────────────────────────


def at_ok(sock, lines=()):
    text = "".join(f"{ln}\r\n" for ln in lines) + "OK\r\n"
    send_tcp(sock, text)


def at_error(sock, message="Error : Function Disabled"):
    send_tcp(sock, f"{message}\r\n")


def apply_at_control(state, sock, ch, mode):
    """ON / OFF / TOGGLE / RESTART. Returns False when disabled."""
    if not (0 <= ch < len(state.outputs)):
        at_error(sock, "ERROR")
        return False
    out = state.outputs[ch]
    if mode == "ON":
        if state.profile["is_dimmer"]:
            out["pwm"] = 100 if out.get("pwm", 0) == 0 else out["pwm"]
            out["state"] = out["pwm"] > 0
        else:
            out["state"] = True
    elif mode == "OFF":
        if out["turn_off_disable"]:
            at_error(sock)
            return False
        if state.profile["is_dimmer"]:
            out["pwm"] = 0
            out["state"] = False
        else:
            out["state"] = False
    elif mode == "TOGGLE":
        if out["state"] and out["turn_off_disable"]:
            at_error(sock)
            return False
        out["state"] = not out["state"]
        if state.profile["is_dimmer"]:
            out["pwm"] = 0 if out["state"] else 100
    elif mode == "RESTART":
        if out["restart_disable"]:
            at_error(sock)
            return False
        out["state"] = False
        if state.profile["is_dimmer"]:
            out["pwm"] = 0
        broadcast_output_change(state, ch)

        def _restart_later(c):
            time.sleep(5)
            state.outputs[c]["state"] = True
            if state.profile["is_dimmer"]:
                state.outputs[c]["pwm"] = 60
            broadcast_output_change(state, c)
        threading.Thread(target=_restart_later, args=(ch,), daemon=True).start()
        at_ok(sock)
        return True
    broadcast_output_change(state, ch)
    at_ok(sock)
    return True


def handle_at_command(state, sock, line):
    cmd = line.strip()
    up = cmd.upper()
    p = state.profile
    parts = up.split(":")
    head = parts[0]

    if up == "AT":
        return at_ok(sock)

    if up == "AT+VER":
        return at_ok(sock, [
            f"DEVICE:{p['label']}", f"VER:{state.firmware}",
            f"SN:{state.serial}", f"GUID:{p['guid']}",
            f"RELAY_COUNT:{p['output_count']}",
        ])

    if up == "AT+TIME":
        return at_ok(sock, [f"SYSTIME:{now_str()}", f"UPTIME:{uptime_str(start_time)}"])

    if up == "AT+NET":
        return at_ok(sock, [f"LANIP:{state.ip}", f"LANMAC:{mac_text(state.mac)}"])

    if up == "AT+TEMP":
        return at_ok(sock, [f"SYSTEMP:35.5", f"CPUTEMP:42.1"])

    if up == "AT+GETSYSDATA":
        return at_ok(sock, [
            f"GETSYSDATA:TimeStamp:{now_str()}",
            f"GETSYSDATA:UpTime:{uptime_str(start_time)}",
            f"GETSYSDATA:MemUsage:20.16",
            f"GETSYSDATA:CPUUsage:25.9",
        ])

    if up == "AT+CHNAMES":
        lines = []
        for ch, inp in enumerate(state.inputs):
            lines.append(f"CHNAME_IN:{ch}:{inp['name']}")
        for ch, out in enumerate(state.outputs):
            lines.append(f"CHNAME_OUT:{ch}:{out['name']}")
        return at_ok(sock, lines)

    if up == "AT+SCHEDULE":
        lines = ["SCHEDULE_START:0"]
        for s in state.schedules:
            lines.append(f"SCHEDULE_ITEM:ID:{s}")
        lines.append("SCHEDULE_END:0")
        return at_ok(sock, lines)

    if up == "AT+INSTAT":
        lines = [f"IN:{ch}:{'ON' if inp['state'] else 'OFF'}"
                 for ch, inp in enumerate(state.inputs)]
        return at_ok(sock, lines)

    if up == "AT+OUTSTAT":
        lines = [f"OUT:{ch}:{'ON' if out['state'] else 'OFF'}"
                 for ch, out in enumerate(state.outputs)]
        if p["is_dimmer"]:
            lines += [f"PWM:{ch}:{out.get('pwm', 0)}"
                      for ch, out in enumerate(state.outputs)]
        return at_ok(sock, lines)

    if up.startswith("AT+INSTAT:") and len(parts) == 2:
        try:
            ch = int(parts[1])
            state_line = f"IN:{ch}:{'ON' if state.inputs[ch]['state'] else 'OFF'}"
            return at_ok(sock, [state_line]) if ch < len(state.inputs) else at_error(sock, "ERROR")
        except (IndexError, ValueError):
            return at_error(sock, "ERROR")

    if up.startswith("AT+OUTSTAT:") and len(parts) == 2:
        try:
            ch = int(parts[1])
            if ch >= len(state.outputs):
                return at_error(sock, "ERROR")
            out = state.outputs[ch]
            lines = [f"OUT:{ch}:{'ON' if out['state'] else 'OFF'}"]
            if p["is_dimmer"]:
                lines.append(f"PWM:{ch}:{out.get('pwm', 0)}")
            return at_ok(sock, lines)
        except ValueError:
            return at_error(sock, "ERROR")

    if up.startswith("AT+GETOUTCONFIG:") and len(parts) >= 2:
        try:
            ch = int(parts[1])
            out = state.outputs[ch]
            return at_ok(sock, [
                f"OUTCONFIG:{ch}:{out['name']}:{out['on_delay']}:{out['off_delay']}:"
                f"{out['on_run_time']}:{out['off_run_time']}:{out['start_delay']}:"
                f"{out['initial_state']}:{int(out['turn_off_disable'])}:"
                f"{int(out['restart_disable'])}",
            ])
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up.startswith("AT+SETOUTCONFIG:") and len(parts) >= 3:
        try:
            ch = int(parts[1])
            out = state.outputs[ch]
            if len(parts) >= 4:
                key = parts[2].lower()
                value = ":".join(parts[3:])
                if key in ("name",):
                    out["name"] = value
                elif key == "on_delay":
                    out["on_delay"] = int(value)
                elif key == "off_delay":
                    out["off_delay"] = int(value)
            return at_ok(sock, [f"OUTCFG_SAVED:{ch}"])
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up.startswith("AT+SETINPUT:") and len(parts) >= 3:
        try:
            ch = int(parts[1])
            inp = state.inputs[ch]
            if len(parts) >= 4 and parts[2].lower() == "name":
                inp["name"] = ":".join(parts[3:])
            return at_ok(sock, [f"INCFG_SAVED:{ch}"])
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up == "AT+GETOVERRIDE":
        return at_ok(sock, [f"OVERRIDE:{'ON' if state.override else 'OFF'}"])

    if up == "AT+GETENERGY":
        if not p["has_energy"]:
            return at_error(sock, "ERROR")
        v, i, pw, ap, pf, e = (229.7, 1.25, 274.2, 287.1, 0.955, 18.42)
        return at_ok(sock, [f"GETENERGY:{v}:{i}:{pw}:{ap}:{pf}:{e}:E"])

    if up.startswith("AT+SETOUTCFG:") and len(parts) >= 5:
        try:
            ch = int(parts[1])
            off_disabled = parts[2].lower() == "true"
            restart_disabled = parts[3].lower() == "true"
            b64 = ":".join(parts[4:])
            name = base64.b64decode(b64).decode("utf-8", errors="replace")
            out = state.outputs[ch]
            out["name"] = name
            out["turn_off_disable"] = off_disabled
            out["restart_disable"] = restart_disabled
            return at_ok(sock, [f"OUTCFG_SAVED:{ch}"])
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up.startswith("AT+MASKED"):
        mask = parts[1] if len(parts) > 1 else ""
        mode = head.replace("AT+MASKED", "")
        for i, flag in enumerate(mask):
            if flag != "X" or i >= len(state.outputs):
                continue
            apply_at_control(state, sock, i, mode)
        if not any(f == "X" for f in mask):
            at_ok(sock)
        return

    if up == "AT+SETPWM" or up.startswith("AT+SETPWM:"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        try:
            ch = int(parts[1])
            value = int(parts[2]) if len(parts) > 2 else 100
            out = state.outputs[ch]
            out["pwm"] = max(0, min(100, value))
            out["state"] = out["pwm"] > 0
            broadcast_output_change(state, ch)
            return at_ok(sock)
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up.startswith("AT+GETOUTSTATAPWM"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        ch = int(parts[1]) if len(parts) > 1 and parts[1] != "" else None
        if ch is not None:
            lines = [f"PWM:{ch}:{state.outputs[ch].get('pwm', 0)}"]
        else:
            lines = [f"PWM:{i}:{o.get('pwm', 0)}"
                     for i, o in enumerate(state.outputs)]
        return at_ok(sock, lines)

    if up.startswith("AT+GETOUTSTATSPWM"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        ch = int(parts[1]) if len(parts) > 1 and parts[1] != "" else None
        if ch is not None:
            lines = [f"PWM:{ch}:{state.outputs[ch].get('pwm', 0)}"]
        else:
            lines = [f"PWM:{i}:{o.get('pwm', 0)}"
                     for i, o in enumerate(state.outputs)]
        return at_ok(sock, lines)

    if up == "AT+GETMAP" or up.startswith("AT+GETMAP:"):
        try:
            ch = int(parts[1]) if len(parts) > 1 else None
            rows = [(i, o, c) for (i, o), c in state.mapping.items()
                    if ch is None or i == ch]
            lines = [f"MAP:{i}:{o}:{c}" for i, o, c in sorted(rows)]
            return at_ok(sock, lines)
        except ValueError:
            return at_error(sock, "ERROR")

    if up.startswith("AT+SETMAP:") and len(parts) == 4:
        try:
            i, o, c = int(parts[1]), int(parts[2]), int(parts[3])
            if c not in MAPPING_CODES.values():
                return at_error(sock, "ERROR")
            state.mapping[(i, o)] = c
            return at_ok(sock, [f"MAP:{i}:{o}:{c}"])
        except ValueError:
            return at_error(sock, "ERROR")

    if up == "AT+PWMON" or up.startswith("AT+PWMON:"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        try:
            ch = int(parts[1])
            state.outputs[ch]["pwm"] = 100
            state.outputs[ch]["state"] = True
            broadcast_output_change(state, ch)
            return at_ok(sock)
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up == "AT+PWMOFF" or up.startswith("AT+PWMOFF:"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        try:
            ch = int(parts[1])
            state.outputs[ch]["pwm"] = 0
            state.outputs[ch]["state"] = False
            broadcast_output_change(state, ch)
            return at_ok(sock)
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up == "AT+PWMTOGGLE" or up.startswith("AT+PWMTOGGLE:"):
        if not p["is_dimmer"]:
            return at_error(sock, "ERROR")
        try:
            ch = int(parts[1])
            cur = state.outputs[ch].get("pwm", 0)
            state.outputs[ch]["pwm"] = 0 if cur > 0 else 100
            state.outputs[ch]["state"] = state.outputs[ch]["pwm"] > 0
            broadcast_output_change(state, ch)
            return at_ok(sock)
        except (ValueError, IndexError):
            return at_error(sock, "ERROR")

    if up == "AT+REBOOT":
        at_ok(sock)

        def _reboot_later():
            time.sleep(2)
            broadcast_close_all()
        threading.Thread(target=_reboot_later, daemon=True).start()
        return

    # AT+ON / AT+OFF / AT+TOGGLE / AT+RESTART take a channel.
    for mode, prefix in (("RESTART", "AT+RESTART"), ("TOGGLE", "AT+TOGGLE"),
                         ("OFF", "AT+OFF"), ("ON", "AT+ON")):
        if head == prefix:
            try:
                ch = int(parts[1]) if len(parts) > 1 else -1
            except ValueError:
                ch = -1
            return apply_at_control(state, sock, ch, mode)

    if up == "EXIT":
        send_tcp(sock, "Exiting Terminal\r\n")
        return "EXIT"

    at_error(sock, "ERROR")


# ─── TCP command servers (legacy AT-only + Control API) ─────────────────────


def handle_line(state, sock, line):
    if line.startswith("J:"):
        # Kept for the legacy framing path; the shared command port accepts
        # J: (and plain JSON) through handle_line_ctrl instead.
        send_tcp(sock, "ERROR: J: prefix not accepted on the AT path\r\n")
        return
    result = handle_at_command(state, sock, line)
    if result == "EXIT":
        return result


def handle_line_ctrl(state, sock, line):
    text = line
    if text.startswith("J:"):
        # The single 5008 command port is shared: accept the legacy `J:`
        # framing here too (the old separate legacy port is gone).
        text = text[2:]
    try:
        req = json.loads(text)
        if not isinstance(req, dict):
            raise ValueError("request is not an object")
    except (ValueError, UnicodeDecodeError):
        # Not JSON - a legacy `AT+...` command on the shared command port.
        return handle_at_command(state, sock, line)
    protocol = req.get("protocol")
    if not isinstance(protocol, int) or not (1 <= protocol <= 3):
        send_tcp(sock, ctrl_json(state, req.get("id"), 2, ok=False,
                                 error={"code": "unsupported_protocol",
                                        "message": "protocol not supported"}))
        return
    req_id = req.get("id")
    action = req.get("action")
    params = req.get("params") or {}
    if not isinstance(params, dict):
        params = {}
    if action not in CONTROL_API_ACTIONS:
        send_tcp(sock, ctrl_json(state, req_id, protocol, ok=False,
                                 error={"code": "unknown_action",
                                        "message":
                                            f"action '{action}' not supported"}))
        return
    try:
        result = handle_control_api_action(state, action, params, req_id)
        send_tcp(sock, ctrl_json(state, req_id, protocol, result=result))
    except RequestError as exc:
        send_tcp(sock, ctrl_json(state, req_id, protocol, ok=False,
                                 error={"code": exc.code,
                                        "message": exc.message}))
    except Exception as exc:  # defensive: never drop the connection
        send_tcp(sock, ctrl_json(
            state, req_id, protocol, ok=False,
            error={"code": "internal_error", "message": str(exc)}))


def tcp_client_handler(state, client_sock, addr, control_api=False):
    client_id = f"{addr[0]}:{addr[1]}"
    print(f"[TCP] connection from {addr}"
          + (" (Control API)" if control_api else ""))
    # Shared command-port greeting (the AT-only status dump). JSON clients
    # ignore the non-JSON greeting lines; AT clients use them.
    try:
        greeting = [f"DEVICE:{state.profile['label']}",
                    f"VER:{state.firmware}", f"SN:{state.serial}"]
        for ch, out in enumerate(state.outputs):
            greeting.append(f"OUT:{ch}:{'ON' if out['state'] else 'OFF'}")
        send_tcp(client_sock, "\r\n".join(greeting) + "\r\n")
    except Exception:
        pass

    with tcp_clients_lock:
        old = tcp_clients.pop(client_id, None)
        if old:
            try:
                old.close()
            except Exception:
                pass
        tcp_clients[client_id] = client_sock
        if control_api:
            tcp_api_clients.add(client_id)

    buf = ""
    try:
        while True:
            data = client_sock.recv(1024)
            if not data:
                break
            buf += data.decode("utf-8", errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.rstrip("\r")
                if not line.strip():
                    continue
                print(f"[TCP] < {line}")
                if handle_line_ctrl(state, client_sock, line) == "EXIT":
                    return
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        with tcp_clients_lock:
            tcp_clients.pop(client_id, None)
            tcp_api_clients.discard(client_id)
        client_sock.close()
        print(f"[TCP] disconnected {addr}")


def tcp_server(state, host, port, control_api=False):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(8)
    label = "Control API" if control_api else "AT-only legacy"
    print(f"[TCP ] {label} HostPort {host}:{port}")
    while True:
        client_sock, addr = server.accept()
        threading.Thread(target=tcp_client_handler,
                         args=(state, client_sock, addr, control_api),
                         daemon=True).start()


# ─── UDP discovery server (section 1) ────────────────────────────────────────


def udp_discovery_server(state, host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind((host, port))
    print(f"[UDP ] discovery broadcast port {host}:{port}")
    while True:
        try:
            data, addr = sock.recvfrom(2048)
            try:
                msg = json.loads(data.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(msg, dict):
                continue
            if str(msg.get("GUID", "")).upper() != DISCOVERY_REQUEST_GUID:
                continue
            port_val = msg.get("PORT", msg.get("Port"))
            try:
                callback_port = int(port_val)
            except (TypeError, ValueError):
                print("[UDP ] discovery request without a usable PORT; ignored")
                continue
            print(f"[UDP ] discovery request from {addr[0]}:{callback_port}")

            def _callback(ip, cb_port):
                try:
                    s = socket.create_connection((ip, cb_port), timeout=5)
                    s.sendall((
                        f"GUID:{state.profile['guid']}\r\n"
                        f"VER:{state.firmware}\r\n"
                        f"PORT:{DEFAULT_TCP_PORT}\r\n"
                        f"SN:{state.serial}\r\n"
                        f"NAME:{state.name}\r\n"
                        f"MAC:{mac_text(state.mac)}\r\n"
                        f"API_PORT:{CONTROL_API_PORT}\r\n"
                        f"HEARTBEAT_PORT:{HEARTBEAT_PORT}\r\n"
                        f"API_VER:{CONTROL_API_VERSION}\r\n"
                        f"CAPS:control_api_v3,heartbeat,l2\r\n"
                    ).encode("utf-8"))
                    s.close()
                    print(f"[UDP ] discovery response -> {ip}:{cb_port}")
                except Exception as exc:
                    print(f"[UDP ] discovery callback failed: {exc}")

            threading.Thread(target=_callback,
                             args=(addr[0], callback_port), daemon=True).start()
        except OSError:
            continue


# ─── UDP heartbeat server (section 3) ────────────────────────────────────────


def udp_heartbeat_server(state, host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    print(f"[UDP ] heartbeat port {host}:{port}")
    while True:
        try:
            data, addr = sock.recvfrom(2048)
            try:
                msg = json.loads(data.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(msg, dict):
                continue
            if msg.get("soleux_heartbeat") != 1 or msg.get("op") != "ping":
                continue
            nonce = msg.get("nonce")
            if not nonce or not isinstance(nonce, str) or len(nonce) > 64:
                continue
            pong = {
                "soleux_heartbeat": 1, "op": "pong", "nonce": nonce,
                "tcp_port": DEFAULT_TCP_PORT, "name": state.name,
                "api_port": CONTROL_API_PORT,
                "api_version": CONTROL_API_VERSION,
                "device_id": state.serial,
            }
            sock.sendto(json.dumps(pong).encode("utf-8"), addr)
            print(f"[UDP ] heartbeat pong -> {addr[0]}:{addr[1]}")
        except OSError:
            continue


# ─── Soleux DCP / Layer-2 (section 2) ────────────────────────────────────────


def build_l2_frame(dst_mac, src_mac, payload):
    frame = dst_mac + src_mac + struct.pack("!H", ETHER_TYPE_L2) + payload
    if len(frame) < ETH_MIN_FRAME:
        frame += b"\x00" * (ETH_MIN_FRAME - len(frame))
    return frame


def send_l2(sock, dst_mac, src_mac, msg):
    payload = json.dumps(msg, ensure_ascii=False).encode("utf-8")
    sock.send(build_l2_frame(dst_mac, src_mac, payload))


def l2_identity(state, nonce, requester_mac):
    return {
        "soleux_l2": 1, "op": "identity", "nonce": nonce,
        "guid": state.profile["guid"], "mac": mac_text(state.mac),
        "name": state.name, "serial": state.serial,
        "firmware": state.firmware, "port": DEFAULT_TCP_PORT,
        "ip": state.ip, "mask": state.mask, "gateway": state.gateway,
        "api_port": CONTROL_API_PORT, "heartbeat_port": HEARTBEAT_PORT,
        "api_version": CONTROL_API_VERSION,
    }


def l2_set_ipv4(state, msg):
    """Validates and applies set_ipv4; returns the set_result message."""
    ip_str = str(msg.get("ip", ""))
    mask_str = str(msg.get("mask", ""))
    gateway_str = str(msg.get("gateway", ""))
    try:
        ip = ipaddress.IPv4Address(ip_str)
    except ipaddress.AddressValueError:
        return {"soleux_l2": 1, "op": "set_result", "status": "error",
                "message": "invalid ip address"}
    if ip.is_unspecified or ip.is_multicast or ip.is_reserved \
            or ip == ipaddress.IPv4Address("255.255.255.255"):
        return {"soleux_l2": 1, "op": "set_result", "status": "error",
                "message": "invalid ip address"}
    if not is_contiguous_mask(mask_str):
        return {"soleux_l2": 1, "op": "set_result", "status": "error",
                "message": "invalid subnet mask"}
    try:
        gateway = ipaddress.IPv4Address(gateway_str)
    except ipaddress.AddressValueError:
        return {"soleux_l2": 1, "op": "set_result", "status": "error",
                "message": "invalid gateway"}
    state.ip = ip_str
    state.mask = mask_str
    state.gateway = gateway_str
    print(f"[DCP ] static IPv4 saved: ip={ip_str} mask={mask_str} "
          f"gateway={gateway_str}")
    return {"soleux_l2": 1, "op": "set_result", "status": "ok",
            "message": "static IPv4 settings saved"}


def dcp_server(state, host, iface):
    if not hasattr(socket, "AF_PACKET"):
        print("[DCP ] raw Ethernet (AF_PACKET) unavailable on this OS; DCP "
              "disabled (use UDP discovery + enable DCP on Linux with "
              "root/CAP_NET_RAW)")
        return
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                             socket.htons(ETHER_TYPE_L2))
        sock.bind((iface, 0))
        sock.settimeout(1)
    except OSError as exc:
        print(f"[DCP ] cannot open raw socket on '{iface}': {exc} "
              "(requires root/CAP_NET_RAW); DCP disabled")
        return
    print(f"[DCP ] listening on {iface} for EtherType 0x{ETHER_TYPE_L2:04X}")
    while True:
        try:
            frame, _addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(frame) < 14:
            continue
        ethertype = struct.unpack("!H", frame[12:14])[0]
        if ethertype != ETHER_TYPE_L2:
            continue
        requester_mac = frame[6:12]
        payload = frame[14:].rstrip(b"\x00")
        if not payload:
            continue
        try:
            msg = json.loads(payload.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(msg, dict) or msg.get("soleux_l2") != 1:
            continue
        op = msg.get("op")
        print(f"[DCP ] op '{op}' from {mac_text(requester_mac)}")
        if op == "identify":
            nonce = msg.get("nonce")
            if isinstance(nonce, str) and nonce and len(nonce) <= 64:
                send_l2(sock, requester_mac, state.mac,
                        l2_identity(state, nonce, requester_mac))
        elif op in ("set_ipv4", "reboot"):
            target = str(msg.get("target", "")).strip().replace("-", ":")
            if target.upper() != mac_text(state.mac):
                continue
            if op == "set_ipv4":
                response = l2_set_ipv4(state, msg)
                send_l2(sock, requester_mac, state.mac, response)
            else:
                send_l2(sock, requester_mac, state.mac, {
                    "soleux_l2": 1, "op": "reboot_result", "status": "ok",
                    "message": "reboot accepted"})
                print("[DCP ] reboot accepted; simulating device restart")
                time.sleep(2)
                broadcast_close_all()


# ─── Main ────────────────────────────────────────────────────────────────────

start_time = time.time()


def parse_args():
    parser = argparse.ArgumentParser(description="Soleux module dummy server")
    parser.add_argument("--device", choices=sorted(DEVICE_PROFILES),
                        default="relay_module", help="device family to emulate")
    parser.add_argument("--tcp-port", type=int, default=DEFAULT_TCP_PORT,
                        help="TCP command HostPort (default 5008)")
    parser.add_argument("--discover-port", type=int, default=DISCOVERY_PORT,
                        help="UDP discovery broadcast port (default 8000)")
    parser.add_argument("--bind", default="0.0.0.0",
                        help="bind address for all TCP/UDP services")
    parser.add_argument("--name", default=None,
                        help="override device display name")
    parser.add_argument("--serial", default=None,
                        help="override device serial number")
    parser.add_argument("--firmware", default="7.10",
                        help="firmware version reported to clients")
    parser.add_argument("--ip", default="10.100.20.42",
                        help="device IPv4 address (identity/heartbeat/DCP)")
    parser.add_argument("--mask", default="255.255.255.0")
    parser.add_argument("--gateway", default="10.100.20.1")
    parser.add_argument("--mac", default="02:81:F9:30:81:F9",
                        help="Ethernet MAC reported via DCP/UDP")
    parser.add_argument("--iface", default="eth0",
                        help="raw-socket interface for DCP (Linux only)")
    parser.add_argument("--no-dcp", action="store_true",
                        help="disable the Layer-2 DCP server")
    return parser.parse_args()


def main():
    args = parse_args()
    profile = DEVICE_PROFILES[args.device]
    state = ModuleState(profile,
                        name=args.name, serial=args.serial,
                        ip=args.ip, mask=args.mask, gateway=args.gateway,
                        mac=args.mac, firmware=args.firmware)

    if args.tcp_port != DEFAULT_TCP_PORT:
        raise SystemExit("the dummy serves one fixed HostPort 5008 for "
                         "discovery/heartbeat; use --tcp-port only to move "
                         "the TCP service and adjust the code accordingly")

    print("=" * 62)
    print(f"  Soleux {profile['label']} dummy server")
    print(f"  JSON device  : {profile['json_device']}")
    print(f"  GUID         : {profile['guid']}")
    print(f"  NAME         : {state.name}")
    print(f"  SN           : {state.serial}")
    print(f"  IP/MAC       : {state.ip} / {mac_text(state.mac)}")
    print(f"  Command/Control API HostPort : {args.tcp_port}")
    print(f"  UDP discover : {args.discover_port}")
    print(f"  UDP heartbeat: {state.heartbeat_port}")
    print("=" * 62)

    threads = [
        threading.Thread(target=tcp_server,
                         args=(state, args.bind, args.tcp_port, True),
                         daemon=True),
        threading.Thread(target=udp_discovery_server,
                         args=(state, args.bind, args.discover_port),
                         daemon=True),
        threading.Thread(target=udp_heartbeat_server,
                         args=(state, args.bind, state.heartbeat_port),
                         daemon=True),
        # Protocol-2 broadcast contract: push system_status every ~5 s while a
        # Control API client is connected.
        threading.Thread(target=system_status_sender, args=(state,),
                         daemon=True),
    ]
    if not args.no_dcp:
        threads.append(threading.Thread(
            target=dcp_server, args=(state, args.bind, args.iface),
            daemon=True))

    for thread in threads:
        thread.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nShutting down...")


if __name__ == "__main__":
    main()