#!/usr/bin/env python3
"""
Soleux Module Client / command-test service.

A pure-stdlib Python client that talks to a Soleux device (physical firmware
or the local simulator in ``mock/module_dummy_server.py``). It implements the
three network behaviours and a command surface so it can act as a harness for
"command test":

  1. Discovery  - UDP broadcast on port 8000 with a temporary TCP callback
                  listener (Soleux-Network-Discovery-and-DCP.md, and the
                  additive fields of
                  Soleux_Network_Discovery_and_Heartbeat_Specification_v0.1).
  2. Heartbeat  - unicast UDP ping on the fixed well-known heartbeat port
                   (default 5007) with nonce correlation.
  3. API commands - auto-detecting TCP client that negotiates the protocol by
                  sending ``hello``:

                  * v3 "Control API"  - plain JSON envelope ``{"protocol":3,...}``
                    on the command HostPort (advertised ``API_PORT``, else the
                    port itself, default 5008), per
                    Soleux_Control_API_Command_Specification_v0.2.
                  * v2               - ``J:``-prefixed JSON envelope on the
                    command HostPort (default 5008), per
                    Soleux-Mobile-TCP-Protocol.md.
                  * legacy ``AT+...`` lines are also supported.

Usage (CLI):

    python mock/module_client.py discover [--window 3.0]
    python mock/module_client.py heartbeat --ip 127.0.0.1 [--port 5007] [--count 1]
    python mock/module_client.py call --ip 127.0.0.1 [--port 5008] hello
    python mock/module_client.py call --ip 127.0.0.1 --port 5008 get_relay_configuration

Usage (library):

    from mock.module_client import discover
    devices = discover()                     # returns [DiscoveredDevice]
    from mock.module_client import SoleuxClient
    c = SoleuxClient.connect((dev.ipv4, dev.control_api_port or dev.legacy_tcp_port))
    c.hello()
    c.set_output_state(0, True)
    c.get_outputs()

Thread-safety: discovery and heartbeat are self contained. The command client
spawns one background reader thread per connection; use it from one thread.
"""

import argparse
import ipaddress
import json
import os
import queue
import socket
import struct
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

# ─── Well-known protocol constants (doc/ specs + module_dummy_server.py) ─────

DISCOVERY_REQUEST_GUID = "8C93472D-2EF0-4B82-BE96-4FBBED57783F"
DISCOVERY_PORT = 8000
DEFAULT_CALLBACK_PORT = 8001
DEFAULT_TCP_PORT = 5008
HEARTBEAT_PORT = 5007   # fixed well-known UDP heartbeat port
DISCOVERY_PROTOCOL_VERSION = "2.0"

DEVICE_FAMILY_GUIDS = {
    "relay_module":      "579E6EA1-2F64-4CDE-8190-1CD3646EFAA1",
    "dimmer":            "C47A5A88-03E8-4EC0-9F2D-67A6C43F0D91",
    "pdu_energy_meter":  "56EC974B-1C9F-48C3-B438-BFE976593072",
    "pdu_10kw":          "A728DD7D-0DEB-49B9-9B8B-A4556771815F",
    "pdu_v1":            "B4A6B160-0CBA-4BD8-873D-EDC9DF895C26",
}
GUID_TO_TYPE = {v.upper(): k for k, v in DEVICE_FAMILY_GUIDS.items()}

MAPPING_BEHAVIOURS = {
    "none": 0, "on": 1, "off": 2, "toggle": 3,
    "continuous_on": 4, "continuous_off": 5,
}
BEHAVIOUR_TO_CODE = {k: v for k, v in MAPPING_BEHAVIOURS.items()}
CODE_TO_BEHAVIOUR = {v: k for k, v in MAPPING_BEHAVIOURS.items()}

# Error codes shared by the v3 Control API contract (for error messages).
V3_ERROR_CODES = {
    "invalid_request", "unknown_action", "unsupported_command",
    "unsupported_protocol", "authentication_required",
    "authentication_failed", "permission_denied", "invalid_parameter",
    "invalid_channel", "not_found", "revision_conflict", "busy", "interlock",
    "timeout", "rate_limited", "payload_too_large", "internal_error",
}


class SoleuxError(Exception):
    """Base exception carrying the device error envelope when available."""

    def __init__(self, message, code=None, result=None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.result = result


class TransportError(SoleuxError):
    """Network-level failure (connect refused, timeout, disconnect)."""


class ProtocolError(SoleuxError):
    """The peer spoke a protocol this client was not expecting."""


class CommandError(SoleuxError):
    """The device returned a normal ``ok:false`` error response."""


# ─── Discovery ───────────────────────────────────────────────────────────────


@dataclass
class DiscoveredDevice:
    """Normalized record from a UDP discovery callback."""
    ipv4: str
    guid: str
    family_guid: str
    device_type: Optional[str]
    ver: str
    legacy_tcp_port: int
    serial: Optional[str] = None
    name: Optional[str] = None
    mac: Optional[str] = None
    control_api_port: Optional[int] = None
    heartbeat_port: Optional[int] = None
    api_version: Optional[int] = None
    capabilities: List[str] = field(default_factory=list)
    raw: Dict[str, Any] = field(default_factory=dict)

    def __init__(self, ipv4, guid, ver, legacy_tcp_port, serial=None, name=None,
                 mac=None, control_api_port=None, heartbeat_port=None,
                 api_version=None, capabilities=None, raw=None):
        self.ipv4 = ipv4
        self.guid = (guid or "").upper()
        self.family_guid = self.guid
        self.device_type = GUID_TO_TYPE.get(self.guid)
        self.ver = ver or ""
        self.legacy_tcp_port = int(legacy_tcp_port)
        self.serial = serial
        self.name = name
        self.mac = mac
        self.control_api_port = control_api_port
        self.heartbeat_port = heartbeat_port
        self.api_version = api_version
        self.capabilities = capabilities or []
        self.raw = raw or {}

    @property
    def inferred_control_api_port(self):
        """Advertised API_PORT, else the command HostPort itself."""
        if self.control_api_port:
            return self.control_api_port
        return self.legacy_tcp_port

    @property
    def inferred_heartbeat_port(self):
        """Advertised HEARTBEAT_PORT, else the fixed well-known 5007."""
        if self.heartbeat_port:
            return self.heartbeat_port
        return HEARTBEAT_PORT

    @property
    def connectable(self) -> bool:
        return bool(self.ipv4) and self.ipv4 != "0.0.0.0"

    def as_dict(self):
        return {
            "ipv4": self.ipv4, "guid": self.family_guid,
            "device_type": self.device_type, "ver": self.ver,
            "serial": self.serial, "name": self.name, "mac": self.mac,
            "legacy_tcp_port": self.legacy_tcp_port,
            "control_api_port": self.control_api_port,
            "heartbeat_port": self.heartbeat_port,
            "api_version": self.api_version,
            "capabilities": self.capabilities,
        }

    def __repr__(self):
        return (f"<DiscoveredDevice {self.name or '?'} ip={self.ipv4} "
                f"type={self.device_type or self.family_guid} "
                f"legacy={self.legacy_tcp_port} api={self.control_api_port}>")


def _windows_adapter_broadcasts() -> List[Tuple[str, str]]:
    """Enumerate (ip, broadcast) pairs via the Win32 IP Helper API.

    stdlib-only Windows fallback for when ``netifaces`` is not installed. Unlike
    the hostname heuristic it computes the true directed broadcast for every
    subnet size (e.g. a /16 LAN -> x.x.255.255, a /20 VPN -> x.x.15.255).
    """
    if os.name != "nt":
        return []
    import ctypes
    from ctypes import wintypes

    class _IP_ADDR_STRING(ctypes.Structure):
        pass

    _IP_ADDR_STRING._fields_ = [
        ("Next", ctypes.POINTER(_IP_ADDR_STRING)),
        ("IpAddress", ctypes.c_char * 16),
        ("IpMask", ctypes.c_char * 16),
        ("Context", wintypes.DWORD),
    ]

    class _IP_ADAPTER_INFO(ctypes.Structure):
        pass

    _IP_ADAPTER_INFO._fields_ = [
        ("Next", ctypes.POINTER(_IP_ADAPTER_INFO)),
        ("ComboIndex", wintypes.DWORD),
        ("AdapterName", ctypes.c_char * 260),
        ("Description", ctypes.c_char * 132),
        ("AddressLength", wintypes.UINT),
        ("Address", ctypes.c_ubyte * 8),
        ("Index", wintypes.DWORD),
        ("Type", wintypes.UINT),
        ("DhcpEnabled", wintypes.UINT),
        ("CurrentIpAddress", ctypes.POINTER(_IP_ADDR_STRING)),
        ("IpAddressList", _IP_ADDR_STRING),
        ("GatewayList", _IP_ADDR_STRING),
        ("DhcpServer", _IP_ADDR_STRING),
        ("HaveWins", ctypes.c_bool),
        ("PrimaryWinsServer", _IP_ADDR_STRING),
        ("SecondaryWinsServer", _IP_ADDR_STRING),
        ("LeaseObtained", wintypes.DWORD),
        ("LeaseExpires", wintypes.DWORD),
    ]

    try:
        get_adapters_info = ctypes.windll.iphlpapi.GetAdaptersInfo
    except AttributeError:
        return []
    size = wintypes.DWORD(0)
    get_adapters_info(None, ctypes.byref(size))
    if size.value <= 0:
        return []
    buf = ctypes.create_string_buffer(size.value)
    if get_adapters_info(buf, ctypes.byref(size)) != 0:
        return []
    pairs = []
    p = ctypes.cast(buf, ctypes.POINTER(_IP_ADAPTER_INFO))
    while p:
        entry = p.contents
        link = entry.IpAddressList
        while True:
            ip = link.IpAddress.decode("ascii", "replace").rstrip("\x00")
            mask = link.IpMask.decode("ascii", "replace").rstrip("\x00")
            if ip and mask and not ip.startswith("127."):
                try:
                    net = ipaddress.IPv4Network(f"{ip}/{mask}", strict=False)
                    pairs.append((ip, str(net.broadcast_address)))
                except ValueError:
                    pairs.append((ip, "255.255.255.255"))
            if not link.Next:
                break
            link = link.Next.contents
        p = entry.Next
    return pairs


def _local_interface_broadcasts() -> List[Tuple[str, str]]:
    """Return (ip, broadcast_ip) pairs for enabled IPv4 interfaces.

    Uses ``netifaces`` when installed for accurate subnet masks; otherwise on
    Windows enumerates adapters through the IP Helper API (stdlib-only), falling
    back to hostname-derived /24 broadcasts plus the limited broadcast.
    """
    found: Dict[str, str] = {}
    try:
        import netifaces  # type: ignore
        for iface in netifaces.interfaces():
            for link in netifaces.ifaddresses(iface).get(netifaces.AF_INET, []):
                ip = link.get("addr")
                netmask = link.get("netmask")
                if not ip or ip.startswith("127."):
                    continue
                bcast = "255.255.255.255"
                if netmask:
                    try:
                        net = ipaddress.IPv4Network(
                            f"{ip}/{netmask}", strict=False)
                        bcast = str(net.broadcast_address)
                    except ValueError:
                        bcast = "255.255.255.255"
                found[ip] = bcast
        if found:
            return [(ip, b) for ip, b in found.items()]
    except ImportError:
        pass

    adapter_pairs = _windows_adapter_broadcasts()
    if adapter_pairs:
        return adapter_pairs

    # Fallback: host default route via UDP connect trick.
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        found[ip] = "255.255.255.255"
        addr = ipaddress.IPv4Address(ip)
        net = ipaddress.IPv4Network(f"{addr}/24", strict=False)
        found[ip] = str(net.broadcast_address)
    except Exception:
        pass

    try:
        for name in socket.gethostbyname_ex(socket.gethostname())[2]:
            if name.startswith("127."):
                continue
            found.setdefault(name, "255.255.255.255")
    except Exception:
        pass

    return [(ip, b) for ip, b in found.items()]


def discover(window_s: float = 3.0, callback_port: Optional[int] = None,
             broadcast_hosts: Optional[List[str]] = None,
             want_extras: bool = True) -> List[DiscoveredDevice]:
    """Perform standard UDP discovery.

    Opens a temporary TCP callback listener, broadcasts the discovery request
    to UDP port 8000 on every eligible interface, then accepts device callbacks
    for ``window_s`` seconds. Returns deduplicated, normalized devices.

    ``callback_port`` defaults to an OS-assigned free port. Pass an explicit
    value when the device must reach a specific port (e.g. 8001).
    """
    print("[discovery] computing local interfaces")
    pairs = broadcast_hosts or _local_interface_broadcasts()
    if not pairs:
        pairs = [("0.0.0.0", "255.255.255.255")]

    callback = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    callback.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    callback.bind(("0.0.0.0", callback_port or 0))
    callback.listen(16)
    bound_port = callback.getsockname()[1]
    print(f"[discovery] TCP callback listener on 0.0.0.0:{bound_port}")

    req = {
        "GUID": DISCOVERY_REQUEST_GUID,
        "VER": DISCOVERY_PROTOCOL_VERSION,
        "PORT": str(bound_port),
    }
    if want_extras:
        req["CLIENT"] = "module_client"
        req["WANT"] = ["MAC", "API_PORT", "HEARTBEAT_PORT", "API_VER"]

    sent = set()
    payload = json.dumps(req).encode("utf-8")
    for ip, bcast in pairs:
        if not bcast or bcast in sent:
            continue
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        if ip and ip != "0.0.0.0":
            try:
                udp.bind((ip, 0))
            except OSError as exc:
                print(f"[discovery] bind {ip} failed: {exc}")
        try:
            udp.sendto(payload, (bcast, DISCOVERY_PORT))
            sent.add(bcast)
            print(f"[discovery] broadcast -> {bcast}:{DISCOVERY_PORT}"
                  f" (source {ip or '0.0.0.0'})")
        except OSError as exc:
            print(f"[discovery] send to {bcast} failed: {exc}")
        finally:
            udp.close()

    results: Dict[str, DiscoveredDevice] = {}
    callback.settimeout(0.25)
    deadline = time.monotonic() + window_s
    while time.monotonic() < deadline:
        try:
            conn, addr = callback.accept()
        except socket.timeout:
            continue
        conn.settimeout(1)
        buf = b""
        try:
            while True:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            pass
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
        _consume_callback(results, addr[0], buf.decode("utf-8", errors="replace"))

    callback.close()
    print(f"[discovery] {len(results)} unique device(s) found")
    return list(results.values())


def _consume_callback(results, peer_ip, text):
    fields: Dict[str, Any] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            fields[key.strip().upper()] = value.strip()
    guid = str(fields.get("GUID", "")).upper()
    if not guid or guid not in GUID_TO_TYPE:
        print(f"[discovery] ignore unknown/empty GUID {guid!r} from {peer_ip}")
        return
    try:
        legacy_port = int(fields.get("PORT", DEFAULT_TCP_PORT))
    except (TypeError, ValueError):
        legacy_port = DEFAULT_TCP_PORT

    def _int(name, default=None):
        try:
            return int(fields.get(name, default))
        except (TypeError, ValueError):
            return default

    dev = DiscoveredDevice(
        ipv4=peer_ip, guid=guid, ver=fields.get("VER", ""),
        legacy_tcp_port=legacy_port,
        serial=fields.get("SN"), name=fields.get("NAME"),
        mac=fields.get("MAC"),
        control_api_port=_int("API_PORT"),
        heartbeat_port=_int("HEARTBEAT_PORT"),
        api_version=_int("API_VER"),
        capabilities=[c for c in fields.get("CAPS", "").split(",") if c],
        raw=fields,
    )
    key = dev.serial or (dev.mac or f"{dev.ipv4}:{dev.legacy_tcp_port}")
    results[key] = dev
    print(f"[discovery] {dev}")


# ─── Heartbeat ───────────────────────────────────────────────────────────────


def heartbeat_ping(ip: str, port: Optional[int] = None, nonce: Optional[str] = None,
                   timeout_s: float = 1.5,
                   expect_host: Optional[str] = None) -> Dict[str, Any]:
    """Send one unicast heartbeat ping and validate the matching pong.

    Returns a dict with ``valid``, ``nonce``, ``tcp_port``, ``name``, optional
    additive endpoints, and ``round_trip_ms`` / ``last_seen_at``.
    """
    port = port or HEARTBEAT_PORT
    nonce = nonce or _new_nonce()
    sent_at = time.perf_counter()
    pong = {"soleux_heartbeat": 1, "op": "ping", "nonce": nonce}
    outcome: Dict[str, Any] = {
        "valid": False, "nonce": nonce, "tcp_port": None, "name": None,
        "source_ip": None, "source_port": None,
    }
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.05)
    sock.sendto(json.dumps(pong).encode("utf-8"), (ip, port))
    deadline = time.perf_counter() + timeout_s
    expected_ip = expect_host or ip
    while time.perf_counter() < deadline:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            # Windows surfaces an ICMP port-unreachable as ConnectionResetError
            # on an unconnected UDP socket; treat it as "no pong".
            continue
        msg = _decode_json(data)
        if not isinstance(msg, dict):
            continue
        if msg.get("soleux_heartbeat") != 1 or msg.get("op") != "pong":
            continue
        if msg.get("nonce") != nonce:
            continue
        if addr[0] != expected_ip:
            continue
        outcome.update({
            "valid": True, "tcp_port": msg.get("tcp_port"),
            "name": msg.get("name"), "api_port": msg.get("api_port"),
            "api_version": msg.get("api_version"),
            "device_id": msg.get("device_id"), "boot_id": msg.get("boot_id"),
            "source_ip": addr[0], "source_port": addr[1],
            "round_trip_ms": round((time.perf_counter() - sent_at) * 1000),
            "last_seen_at": datetime.now(timezone.utc).isoformat(),
        })
        break
    sock.close()
    return outcome


def _new_nonce() -> str:
    """A unique, short correlation value limited to 64 characters."""
    return uuid.uuid4().hex[:24]


class HeartbeatMonitor:
    """Periodically pings known devices and tracks availability.

    Follows the v0.1 timing profile (5 s interval, 1.5 s response window, idle
    threshold 15 s). Call :meth:`start` then :meth:`status`.
    """

    def __init__(self, devices: List[DiscoveredDevice],
                 interval_s: float = 5.0, window_s: float = 1.5,
                 alive_threshold_s: float = 15.0):
        self._targets = [
            {
                "ip": d.ipv4, "port": d.inferred_heartbeat_port,
                "legacy": d.legacy_tcp_port, "key": d.serial or d.ipv4,
            }
            for d in devices if d.connectable
        ]
        self._interval_s = interval_s
        self._window_s = window_s
        self._alive_threshold_s = alive_threshold_s
        self._last_seen: Dict[str, float] = {}
        self._missed: Dict[str, int] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="heartbeat-monitor")
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=self._window_s + 1)

    def _run(self):
        while not self._stop.is_set():
            for t in self._targets:
                if self._stop.is_set():
                    break
                outcome = heartbeat_ping(
                    t["ip"], t["port"], timeout_s=self._window_s)
                with self._lock:
                    if outcome["valid"]:
                        self._last_seen[t["key"]] = time.monotonic()
                        self._missed[t["key"]] = 0
                    else:
                        self._missed[t["key"]] = self._missed.get(t["key"], 0) + 1
            self._stop.wait(self._interval_s)

    def status(self) -> List[Dict[str, Any]]:
        now = time.monotonic()
        rows = []
        for t in self._targets:
            last = self._last_seen.get(t["key"])
            age = (now - last) if last is not None else None
            if last is not None and age <= self._alive_threshold_s:
                state = "online"
            elif self._missed.get(t["key"], 0) == 0:
                state = "unknown"
            else:
                state = "offline"
            rows.append({
                "key": t["key"], "ip": t["ip"], "port": t["port"],
                "state": state, "last_seen_age_s": None if age is None
                else round(age, 1), "missed": self._missed.get(t["key"], 0),
            })
        return rows


# ─── Command client (auto-detect v3 / v2 / AT) ──────────────────────────────


class _TcpSession:
    """Persistent TCP line reader with a background dispatcher thread."""

    def __init__(self, timeout_s=6.0):
        self.sock = None
        self.timeout_s = timeout_s
        self._reader: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self.inbox: queue.Queue = queue.Queue()
        self.closed_server = threading.Event()

    def connect(self, ip: str, port: int):
        try:
            self.sock = socket.create_connection((ip, port),
                                                 timeout=self.timeout_s)
        except OSError as exc:
            raise TransportError(f"connect {ip}:{port} failed: {exc}")
        self.sock.settimeout(0.4)
        self._reader = threading.Thread(
            target=self._read_loop, args=(ip, port), daemon=True,
            name="tcp-reader")
        self._reader.start()
        return self

    def _read_loop(self, ip, port):
        buf = ""
        try:
            while not self._stop.is_set():
                try:
                    data = self.sock.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                buf += data.decode("utf-8", errors="replace")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.rstrip("\r")
                    if line:
                        self.inbox.put(("line", line))
        finally:
            self._stop.set()
            self.closed_server.set()

    def send_line(self, text: str):
        if self.sock is None:
            raise TransportError("not connected")
        try:
            self.sock.sendall(text.encode("utf-8") + b"\r\n")
        except OSError as exc:
            raise TransportError(f"send failed: {exc}")

    def read_line(self, timeout=None):
        """Wait for the next line from the device (blocking)."""
        try:
            kind, val = self.inbox.get(timeout=timeout)
        except queue.Empty:
            return None
        return val if kind == "line" else None

    def drain(self):
        out = []
        while True:
            try:
                out.append(self.inbox.get_nowait())
            except queue.Empty:
                break
        return out

    def close(self):
        self._stop.set()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        if self._reader:
            self._reader.join(timeout=1)
        self.closed_server.set()


class _V3Api:
    """Protocol-3 Control API transport (plain JSON envelope, port 5008)."""

    def __init__(self, session: _TcpSession, timeout_s=6.0):
        self.session = session
        self.timeout_s = timeout_s
        self._ids = itertools_count()

    def call(self, action, params=None, id=None, protocol=3,
             timeout_ms=None):
        rid = id if id is not None else next(self._ids)
        request = {"protocol": protocol, "id": rid, "action": action,
                   "params": params or {}}
        if timeout_ms:
            request["timeout_ms"] = timeout_ms
        self.session.send_line(json.dumps(request, ensure_ascii=False))

        deadline = time.monotonic() + self.timeout_s
        while time.monotonic() < deadline:
            line = self.session.read_line(timeout=max(0.05, deadline - time.monotonic()))
            if line is None:
                continue
            msg = _decode_json(line)
            if not isinstance(msg, dict):
                continue
            if msg.get("id") == rid:
                if msg.get("ok"):
                    return msg.get("result", {})
                raise CommandError(
                    _fmt_error(msg.get("error") or {}),
                    code=((msg.get("error") or {}).get("code")),
                    result=msg)
        raise TransportError(f"no response for '{action}' (id={rid})")

    def hello(self):
        return self.call("hello", params={"client_name": "module_client",
                                          "client_version": "0.1.0"})

    # Convenience wrappers following the v0.2 catalogue.
    def ping(self, echo=None):
        return self.call("ping", {"echo": echo} if echo is not None else {})

    def get_device_info(self):
        return self.call("get_device_info")

    def get_device_state(self, include=None, include_configuration=False):
        params = {"include_configuration": include_configuration}
        if include:
            params["include"] = include
        return self.call("get_device_state", params)

    def get_outputs(self, include_configuration=True):
        return self.call("get_outputs",
                         {"include_configuration": include_configuration})

    def get_output(self, channel):
        return self.call("get_output", {"channel": int(channel)})

    def set_output_state(self, channel, state, source="module_client"):
        return self.call("set_output_state",
                         {"channel": int(channel), "state": bool(state),
                          "source": source})

    def toggle_output(self, channel, source="module_client"):
        return self.call("toggle_output",
                         {"channel": int(channel), "source": source})

    def restart_output(self, channel, off_time_ms=None, source="module_client"):
        params = {"channel": int(channel), "source": source}
        if off_time_ms is not None:
            params["off_time_ms"] = int(off_time_ms)
        return self.call("restart_output", params)

    def set_mapping(self, input_ch, output_ch, behavior):
        if behavior in BEHAVIOUR_TO_CODE:
            behavior_val = behavior
        elif isinstance(behavior, int):
            behavior_val = CODE_TO_BEHAVIOUR.get(behavior)
            if behavior_val is None:
                raise ValueError(f"unknown legacy mapping code {behavior}")
        else:
            raise ValueError(f"unknown behavior '{behavior}'")
        return self.call("set_mapping",
                         {"input": int(input_ch), "output": int(output_ch),
                          "behavior": behavior_val})

    def get_mappings(self):
        return self.call("get_mappings")

    def get_energy_history(self, parameter=0, start_date=None, end_date=None):
        if start_date is None:
            start_date = (datetime.now() - timedelta_7()).strftime("%Y-%m-%d")
        if end_date is None:
            end_date = datetime.now().strftime("%Y-%m-%d")
        return self.call("get_energy_history",
                         {"parameter": int(parameter),
                          "start_date": start_date, "end_date": end_date})

    def reboot_device(self, reason="module_client"):
        return self.call("reboot_device", {"reason": reason})

    def get_temperature(self, sensor_id=None):
        params = {}
        if sensor_id is not None:
            params["sensor_id"] = sensor_id
        return self.call("get_temperature", params)


class _V2Api:
    """Protocol-2 JSON transport on the legacy port (``J:`` prefix)."""

    def __init__(self, session: _TcpSession, timeout_s=6.0):
        self.session = session
        self.timeout_s = timeout_s
        self._ids = itertools_count()

    def call(self, action, params=None, id=None):
        rid = id if id is not None else next(self._ids)
        request = {"id": rid, "action": action, "params": params or {}}
        self.session.send_line("J:" + json.dumps(request, ensure_ascii=False))

        deadline = time.monotonic() + self.timeout_s
        while time.monotonic() < deadline:
            line = self.session.read_line(
                timeout=max(0.05, deadline - time.monotonic()))
            if line is None:
                continue
            if line.startswith("J:"):
                msg = _decode_json(line[2:])
                if not isinstance(msg, dict):
                    continue
                if msg.get("id") == rid:
                    if msg.get("ok"):
                        return msg.get("result", {})
                    raise CommandError(
                        _fmt_error(msg.get("error") or {}),
                        code=((msg.get("error") or {}).get("code")),
                        result=msg)
        raise TransportError(f"no response for '{action}' (id={rid})")

    def hello(self):
        return self.call("hello")

    # Convenience wrappers for the v2 mobile-protocol subset.
    def get_relay_configuration(self):
        return self.call("get_relay_configuration")

    def hello_and_config(self):
        return {"hello": self.hello(),
                "configuration": self.get_relay_configuration()}

    def set_output_configuration(self, channel, **opts):
        params = {"channel": int(channel)}
        params.update(opts)
        return self.call("set_output_configuration", params)

    def set_input_configuration(self, channel, **opts):
        params = {"channel": int(channel)}
        params.update(opts)
        return self.call("set_input_configuration", params)

    def set_virtual_input_state(self, channel, state, source=None):
        params = {"channel": int(channel), "state": bool(state)}
        if source is not None:
            params["source"] = source
        return self.call("set_virtual_input_state", params)

    def set_mapping(self, input_ch, output_ch, code):
        if isinstance(code, str):
            code = BEHAVIOUR_TO_CODE[code]
        return self.call("set_mapping",
                         {"input": int(input_ch), "output": int(output_ch),
                          "code": int(code)})

    def get_page_configuration(self, page):
        return self.call("get_page_configuration", {"page": page})

    def execute_page_action(self, page_action, **opts):
        params = {"page_action": page_action}
        params.update(opts)
        return self.call("execute_page_action", params)

    def get_energy_history(self, parameter=0, start_date=None, end_date=None):
        if start_date is None:
            start_date = (datetime.now() - timedelta_7()).strftime("%Y-%m-%d")
        if end_date is None:
            end_date = datetime.now().strftime("%Y-%m-%d")
        return self.call("get_energy_history",
                         {"parameter": int(parameter),
                          "start_date": start_date, "end_date": end_date})


class _LegacyAt:
    """Minimal legacy ``AT+`` command surface over the same session."""

    def __init__(self, session: _TcpSession, timeout_s=3.0):
        self.session = session
        self.timeout_s = timeout_s

    def call(self, command):
        self.session.send_line(command)
        lines = []
        deadline = time.monotonic() + self.timeout_s
        while time.monotonic() < deadline:
            line = self.session.read_line(max(0.05, deadline - time.monotonic()))
            if line is None:
                continue
            lines.append(line)
            # Commands other than AT/control end with an explicit OK line.
            if line.strip().upper() == "OK":
                break
            if re_ok_line(line):
                break
        return lines

    def on(self, channel):
        return self.call(f"AT+ON:{int(channel)}")

    def off(self, channel):
        return self.call(f"AT+OFF:{int(channel)}")

    def toggle(self, channel):
        return self.call(f"AT+TOGGLE:{int(channel)}")

    def restart(self, channel):
        return self.call(f"AT+RESTART:{int(channel)}")

    def outstat(self, channel=None):
        return self.call("AT+OUTSTAT" if channel is None
                         else f"AT+OUTSTAT:{int(channel)}")

    def instat(self, channel=None):
        return self.call("AT+INSTAT" if channel is None
                         else f"AT+INSTAT:{int(channel)}")

    def ver(self):
        return self.call("AT+VER")

    def energy(self):
        return self.call("AT+GETENERGY")

    def override(self):
        return self.call("AT+GETOVERRIDE")


class SoleuxClient:
    """Auto-detecting command client.

    Negotiates the device protocol by sending ``hello`` on the Control-API
    port first (v3), falling back to the legacy port (v2 ``J:``), and finally
    exposing the legacy ``AT+`` surface. Which mode was selected is available
    as ``mode``: ``"v3"``, ``"v2"`` or ``"at"``.
    """

    def __init__(self, session: _TcpSession, mode: str,
                 version: Optional[_V3Api] = None,
                 v2: Optional[_V2Api] = None,
                 at: Optional[_LegacyAt] = None):
        self.session = session
        self.mode = mode
        self.v3 = version
        self.v2 = v2
        self.at = at
        self.state = {}

    @classmethod
    def connect(cls, endpoint: Tuple[str, int],
                control_api_port: Optional[int] = None,
                timeout_s: float = 6.0, prefer_v3: bool = True) -> "SoleuxClient":
        ip, port = endpoint

        # 1) Try the v3 Control API on the advertised/derived port.
        if prefer_v3:
            probe_port = control_api_port or port
            tried_v3 = cls._try_make(ip, probe_port, tempo=timeout_s, mode_v3=True)
            if tried_v3:
                print(f"[client] negotiated v3 (control API) on "
                      f"{ip}:{probe_port}")
                return tried_v3

        # 2) Fall back to v2 on the legacy port.
        tried_v2 = cls._try_make(ip, port, tempo=timeout_s, mode_v2=True)
        if tried_v2:
            print(f"[client] negotiated v2 (J:) on {ip}:{port}")
            return tried_v2

        # 3) Open a raw session and rely on AT+ only.
        session = _TcpSession(timeout_s).connect(ip, port)
        print(f"[client] no JSON protocol negotiated on {ip}:{port}; "
              f"falling back to AT+")
        return cls(session, "at", at=_LegacyAt(session))

    @classmethod
    def _try_make(cls, ip, port, tempo, mode_v3=False, mode_v2=False):
        session = _TcpSession(timeout_s=tempo)
        try:
            session.connect(ip, port)
        except TransportError:
            return None
        api = (_V3Api(session, tempo) if mode_v3
               else _V2Api(session, tempo))
        try:
            api.hello()
        except (SoleuxError, TransportError, CommandError):
            session.close()
            return None
        if mode_v3:
            return cls(session, "v3", version=api, at=_LegacyAt(session))
        return cls(session, "v2", v2=api, at=_LegacyAt(session))

    # Unified, protocol-agnostic helpers -------------------------------------

    def hello(self):
        if self.mode == "v3":
            return self.v3.hello()
        if self.mode == "v2":
            return self.v2.hello()
        raise ProtocolError("device is AT-only; JSON hello unavailable")

    def get_state(self):
        """Return a normalized state snapshot regardless of protocol."""
        if self.mode == "v3":
            res = self.v3.get_device_state(
                include=["inputs", "outputs", "sensors"])
            return res
        if self.mode == "v2":
            res = self.v2.get_relay_configuration()
            return {
                "revision": 0, "captured_at": datetime.now(timezone.utc).isoformat(),
                "inputs": [{"channel": i.get("channel"), "state": i.get("input_state"),
                            "name": i.get("input_name"), "enabled": i.get("input_enabled")}
                           for i in res.get("inputs", [])],
                "outputs": [{"channel": o.get("channel"), "state": o.get("output_state"),
                             "name": o.get("output_name")}
                            for o in res.get("outputs", [])],
                "mapping": res.get("mapping", []),
            }
        raise ProtocolError("device is AT-only; JSON state unavailable")

    def set_output_state(self, channel, state):
        if self.mode == "v3":
            return self.v3.set_output_state(channel, state)
        if self.mode == "v2":
            at = self.at
            return at.on(channel) if state else at.off(channel)
        return self.at.on(channel) if state else self.at.off(channel)

    def toggle_output(self, channel):
        return self.at.toggle(channel) if self.mode in ("at", "v2") \
            else self.v3.toggle_output(channel)

    def restart_output(self, channel, off_time_ms=None):
        if self.mode in ("at", "v2"):
            return self.at.restart(channel)
        return self.v3.restart_output(channel, off_time_ms=off_time_ms)

    def set_mapping(self, input_ch, output_ch, behavior):
        if self.mode == "v3":
            return self.v3.set_mapping(input_ch, output_ch, behavior)
        if self.mode == "v2":
            code = behavior if isinstance(behavior, int) \
                else BEHAVIOUR_TO_CODE[behavior]
            return self.v2.set_mapping(input_ch, output_ch, code)
        raise ProtocolError("device is AT-only; JSON mapping unavailable")

    def reboot(self):
        if self.mode == "v3":
            return self.v3.reboot_device()
        if self.mode == "v2":
            return self.v2.execute_page_action("reboot")
        return self.at.call("AT+REBOOT")

    def close(self):
        self.session.close()


# ─── Small helpers ───────────────────────────────────────────────────────────


def _decode_json(data: Any) -> Optional[Any]:
    if isinstance(data, bytes):
        data = data.decode("utf-8", errors="replace")
    try:
        return json.loads(data)
    except (ValueError, TypeError):
        return None


def _fmt_error(err) -> str:
    if not isinstance(err, dict):
        return str(err)
    code = err.get("code", "error")
    message = err.get("message", "")
    return f"{code}: {message}".rstrip()


class _Counter:
    def __init__(self):
        self._n = 0
        self._lock = threading.Lock()

    def __next__(self):
        with self._lock:
            self._n += 1
            return self._n


def itertools_count():
    return _Counter()


def timedelta_7():
    import datetime as _dt
    return _dt.timedelta(days=7)


def re_ok_line(line: str) -> bool:
    """Best-effort AT response terminator checks (OK / ERROR line)."""
    upper = line.strip().upper()
    return upper == "OK" or upper == "ERROR" or upper.startswith("Error :")


# ─── CLI ─────────────────────────────────────────────────────────────────────


def _cmd_discover(args):
    devs = discover(window_s=args.window, callback_port=args.callback_port)
    for d in devs:
        print(json.dumps(d.as_dict(), indent=2))


def _cmd_heartbeat(args):
    nonce = _new_nonce() if args.nonce is None else args.nonce
    out = heartbeat_ping(args.ip, args.port, nonce=nonce,
                         timeout_s=args.window)
    print(json.dumps(out, indent=2))


def _cmd_call(args):
    params = _parse_kv(args.params)
    try:
        client = SoleuxClient.connect((args.ip, args.port),
                                      control_api_port=args.api_port,
                                      timeout_s=args.timeout)
    except SoleuxError as exc:
        print(f"connect error: {exc}")
        return
    try:
        result = _dispatch_call(client, args.command, params)
        print(json.dumps(result, ensure_ascii=False, indent=2)
              if not isinstance(result, str) else result)
    except SoleuxError as exc:
        print(f"error[{exc.code or 'unknown'}]: {exc.message}")
    finally:
        client.close()


def _dispatch_call(client, command, params):
    mode = client.mode
    if command.startswith("AT+"):
        return client.at.call(command)
    if mode == "v3":
        return client.v3.call(command, params)
    if mode == "v2":
        return client.v2.call(command, params)
    raise ProtocolError(f"command '{command}' needs a JSON protocol but "
                        f"device is AT-only")


def _parse_kv(items):
    out = {}
    for item in items or []:
        if "=" not in item:
            raise SystemExit(f"expected key=value, got '{item}'")
        key, value = item.split("=", 1)
        value = _coerce(value)
        out[key] = value
    return out


def _coerce(value):
    if value in ("true", "True"):
        return True
    if value in ("false", "False"):
        return False
    try:
        if value == str(int(value)):
            return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value


def build_parser():
    p = argparse.ArgumentParser(
        description="Soleux module command-test client "
                    "(discovery / heartbeat / API commands)")
    sub = p.add_subparsers(dest="command", required=True)

    disc = sub.add_parser("discover", help="run UDP discovery")
    disc.add_argument("--window", type=float, default=3.0,
                      help="callback accept window in seconds")
    disc.add_argument("--callback-port", type=int, default=None,
                      help="TCP callback port (default: ephemeral)")
    disc.set_defaults(func=_cmd_discover)

    hb = sub.add_parser("heartbeat", help="single heartbeat ping")
    hb.add_argument("--ip", required=True)
    hb.add_argument("--port", type=int, default=None,
                    help="heartbeat UDP port (default 5007)")
    hb.add_argument("--nonce", default=None)
    hb.add_argument("--window", type=float, default=1.5)
    hb.set_defaults(func=_cmd_heartbeat)

    call = sub.add_parser("call", help="invoke an API command")
    call.add_argument("--ip", required=True)
    call.add_argument("--port", type=int, default=DEFAULT_TCP_PORT,
                      help="TCP port to probe (default 5008)")
    call.add_argument("--api-port", type=int, default=None,
                      help="advertised Control API port override (v3)")
    call.add_argument("--timeout", type=float, default=6.0)
    call.add_argument("--params", nargs="*", default=[],
                      help="key=value parameters for JSON actions")
    call.add_argument("command", help="JSON action name or AT+ line")
    call.set_defaults(func=_cmd_call)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
