#!/usr/bin/env python3
"""
PDU Dummy Server - TCP ASCII + UDP Discovery Protocol Simulator

Based on PROTOCOLS.md:
- TCP ASCII Server on port 5008
- UDP Discovery Server on port 8000

Usage:
    python pdu_dummy_server.py
"""

import json
import socket
import struct
import threading
import time
from datetime import datetime, timedelta

from flask import Flask, request
from flask_socketio import SocketIO, emit

# ─── Configuration ───────────────────────────────────────────────────────────

TCP_HOST = "0.0.0.0"
TCP_PORT = 5008
TCP_BACKLOG = 5
TCP_BUFFER_SIZE = 64

UDP_HOST = "0.0.0.0"
UDP_PORT = 8000
UDP_BUFFER_SIZE = 1024

SOCKETIO_HOST = "0.0.0.0"
SOCKETIO_PORT = 8081

DISCOVERY_REQUEST_GUID = "8481fba0-f387-11ea-adc1-0242ac120002"
PDU_RESPONSE_GUID = "24d9b67e-f38d-11ea-adc1-0242ac120002"
CONTROL_API_PORT = 5008   # the command HostPort IS the Control API port
HEARTBEAT_PORT = 5007     # fixed well-known UDP heartbeat port
PDU_MAC = "AA:BB:CC:DD:EE:01"

IP_WHITELIST = set()

# ─── Device State ─────────────────────────────────────────────────────────────

N_CHANNELS = 14
FAN_CH = 12
SYS_LED = 11
WIFI_LED = 13

input_states = [False] * 16
output_states = [True] * 16
mapping = [False] * 16

device_info = {
    "DEVICE": "Soleux PDU",
    "VER": "2.0.0",
    "BUILD": "20250201",
    "RELEASE_DATE": "2025/02/01",
    "SN": "PDU-DUMMY-001",
    "LANMAC": "AA:BB:CC:DD:EE:01",
    "WIFIMAC": "AA:BB:CC:DD:EE:02",
    "RELAY_COUNT": str(N_CHANNELS),
}

network_info = {
    "LANIP": "192.168.1.100",
    "WIFIIP": "192.168.1.101",
    "WIFISSID": "PDU_Network",
    "APP_NAME": "PDU_DUMMY",
}

temperature_info = {
    "SYSTEMP": 35.5,
    "CPUTEMP": 42.1,
    "FAN_STATUS": "OFF",
    "FAN_HIGH_TEMP": 50.0,
    "FAN_LOW_TEMP": 35.0,
    "FAN_MODE": "auto",
}

schedule_data = [
    {
        "ID": 1,
        "RELAY": 1,
        "DATETIME": "2025/03/01 08:00:00",
        "ACTION": "ON",
        "PROCESSED": 0,
    },
]

weekly_schedule_data = [
    {
        "ID": 1,
        "RELAY": 1,
        "DATETIME": "08:00",
        "ACTION": "ON",
        "MON": True,
        "TUE": True,
        "WED": True,
        "THU": True,
        "FRI": True,
        "SAT": False,
        "SUN": False,
    },
]

channel_names_in = [f"Input {i+1}" for i in range(N_CHANNELS)]
channel_names_out = [f"Output {i+1}" for i in range(N_CHANNELS)]

start_time = time.time()

# ─── TCP Client Manager ──────────────────────────────────────────────────────

tcp_clients: dict[str, socket.socket] = {}
tcp_clients_lock = threading.Lock()

# ─── Helper Functions ────────────────────────────────────────────────────────


def now_str():
    return datetime.now().strftime("%Y/%m/%d %H:%M:%S")


def uptime_str():
    delta = timedelta(seconds=int(time.time() - start_time))
    days = delta.days
    hours, remainder = divmod(delta.seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{days}d {hours:02d}:{minutes:02d}:{seconds:02d}"


def send_tcp(sock: socket.socket, data: str):
    try:
        sock.sendall(data.encode())
    except Exception:
        pass


def respond(sock: socket.socket, body: str = ""):
    text = f"\r\n{body}\r\nOK\r\n" if body else "\r\nOK\r\n"
    print(f'[respond] {text.strip()}')
    send_tcp(sock, text)


def respond_error(sock: socket.socket, body: str = ""):
    text = f"\r\n{body}\r\nERROR\r\n" if body else "\r\nERROR\r\n"
    send_tcp(sock, text)


def broadcast(cmd: str):
    print(f'[BROADCAST] {cmd}')
    with tcp_clients_lock:
        dead_ips = []
        for ip, sock in tcp_clients.items():
            try:
                send_tcp(sock, cmd)
            except Exception:
                dead_ips.append(ip)
        for ip in dead_ips:
            tcp_clients.pop(ip, None)


def broadcast_output_change(pin: int):
    state = "ON" if output_states[pin] else "OFF"
    broadcast(f"AT+OUTSTAT:{pin}\r\nOUT:{pin}:{state}\r\n")


def broadcast_input_change(pin: int):
    state = "ON" if input_states[pin] else "OFF"
    broadcast(f"AT+INSTAT:{pin}\r\nIN:{pin}:{state}\r\n")


# ─── Status Dump ──────────────────────────────────────────────────────────────


def build_status_dump() -> str:
    lines = []
    lines.append(f"DEVICE:{device_info['DEVICE']}")
    lines.append(f"VER:{device_info['VER']} Build :{device_info['BUILD']}")
    lines.append(f"RELEASE_DATE:{device_info['RELEASE_DATE']}")
    lines.append(f"SN:{device_info['SN']}")
    lines.append(f"LANMAC:{device_info['LANMAC']}")
    lines.append(f"WIFIMAC:{device_info['WIFIMAC']}")
    lines.append(f"RELAY_COUNT:{device_info['RELAY_COUNT']}")

    for pin in range(N_CHANNELS):
        state = "ON" if input_states[pin] else "OFF"
        lines.append(f"IN:{pin}:{state}")

    for pin in range(N_CHANNELS):
        state = "ON" if output_states[pin] else "OFF"
        lines.append(f"OUT:{pin}:{state}")

    lines.append(f"SYSTEMP:{temperature_info['SYSTEMP']}")
    lines.append(f"CPUTEMP:{temperature_info['CPUTEMP']}")
    lines.append(f"FAN_STATUS:{temperature_info['FAN_STATUS']}")
    lines.append(f"FAN_HIGH_TEMP:{temperature_info['FAN_HIGH_TEMP']}")
    lines.append(f"FAN_LOW_TEMP:{temperature_info['FAN_LOW_TEMP']}")
    lines.append(f"FAN_MODE:{temperature_info['FAN_MODE']}")
    lines.append(f"SYSTIME:{now_str()}")
    lines.append(f"UPTIME:{uptime_str()}")

    lines.append(f"LANIP:{network_info['LANIP']}")
    lines.append(f"WIFIIP:{network_info['WIFIIP']}")
    lines.append(f"WIFISSID:{network_info['WIFISSID']}")
    lines.append(f"APP_NAME:{network_info['APP_NAME']}")

    for pin in range(N_CHANNELS):
        lines.append(f"CHNAME_IN:{pin}:{channel_names_in[pin]}")
        lines.append(f"CHNAME_OUT:{pin}:{channel_names_out[pin]}")

    for pin in range(N_CHANNELS):
        lines.append(f"SCHEDULE_START:{pin}")
        for s in schedule_data:
            lines.append(
                f"SCHEDULE_RUNONES:ID:{s['ID']},RELAY:{s['RELAY']},"
                f"DATETIME:{s['DATETIME']},ACTION:{s['ACTION']},"
                f"PROCESSED:{s['PROCESSED']}"
            )
        for w in weekly_schedule_data:
            lines.append(
                f"SCHEDULE_WEEKLY:ID:{w['ID']},RELAY:{w['RELAY']},"
                f"DATETIME:{w['DATETIME']},ACTION:{w['ACTION']},"
                f"MON:{str(w['MON']).upper()},TUE:{str(w['TUE']).upper()},"
                f"WED:{str(w['WED']).upper()},THU:{str(w['THU']).upper()},"
                f"FRI:{str(w['FRI']).upper()},SAT:{str(w['SAT']).upper()},"
                f"SUN:{str(w['SUN']).upper()}"
            )
        lines.append(f"SCHEDULE_END:{pin}")

    return "\r\n".join(lines) + "\r\n"


# ─── Command Handlers ─────────────────────────────────────────────────────────


def handle_command(sock: socket.socket, cmd: str):
    cmd = cmd.strip()

    if cmd == "AT":
        respond(sock)
        return

    if cmd == "AT+VER":
        resp = (
            f"DEVICE:{device_info['DEVICE']}\r\n"
            f"VER:{device_info['VER']} Build :{device_info['BUILD']}\r\n"
            f"RELEASE_DATE:{device_info['RELEASE_DATE']}\r\n"
            f"SN:{device_info['SN']}\r\n"
            f"LANMAC:{device_info['LANMAC']}\r\n"
            f"WIFIMAC:{device_info['WIFIMAC']}\r\n"
            f"RELAY_COUNT:{device_info['RELAY_COUNT']}"
        )
        respond(sock, resp)
        return

    if cmd == "AT+TIME":
        resp = f"SYSTIME:{now_str()}\r\nUPTIME:{uptime_str()}"
        respond(sock, resp)
        return

    if cmd == "AT+NET":
        resp = (
            f"LANIP:{network_info['LANIP']}\r\n"
            f"WIFIIP:{network_info['WIFIIP']}\r\n"
            f"WIFISSID:{network_info['WIFISSID']}\r\n"
            f"APP_NAME:{network_info['APP_NAME']}"
        )
        respond(sock, resp)
        return

    if cmd == "AT+TEMP":
        resp = (
            f"SYSTEMP:{temperature_info['SYSTEMP']}\r\n"
            f"CPUTEMP:{temperature_info['CPUTEMP']}\r\n"
            f"FAN_STATUS:{temperature_info['FAN_STATUS']}\r\n"
            f"FAN_HIGH_TEMP:{temperature_info['FAN_HIGH_TEMP']}\r\n"
            f"FAN_LOW_TEMP:{temperature_info['FAN_LOW_TEMP']}\r\n"
            f"FAN_MODE:{temperature_info['FAN_MODE']}"
        )
        respond(sock, resp)
        return

    if cmd == "AT+CHNAMES":
        resp_lines = []
        for pin in range(N_CHANNELS):
            resp_lines.append(f"CHNAME_IN:{pin}:{channel_names_in[pin]}")
            resp_lines.append(f"CHNAME_OUT:{pin}:{channel_names_out[pin]}")
        respond(sock, "\r\n".join(resp_lines))
        return

    if cmd == "AT+INSTAT":
        resp_lines = []
        for pin in range(N_CHANNELS):
            state = "ON" if input_states[pin] else "OFF"
            resp_lines.append(f"IN:{pin}:{state}")
        respond(sock, "\r\n".join(resp_lines))
        return

    if cmd == "AT+OUTSTAT":
        resp_lines = []
        for pin in range(N_CHANNELS):
            state = "ON" if output_states[pin] else "OFF"
            resp_lines.append(f"OUT:{pin}:{state}")
        respond(sock, "\r\n".join(resp_lines))
        return

    if cmd.startswith("AT+INSTAT:"):
        try:
            pin = int(cmd.split(":")[1])
            state = "ON" if input_states[pin] else "OFF"
            respond(sock, f"IN:{pin}:{state}")
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+OUTSTAT:"):
        try:
            pin = int(cmd.split(":")[1])
            state = "ON" if output_states[pin] else "OFF"
            respond(sock, f"OUT:{pin}:{state}")
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+MAPSTAT:"):
        try:
            pin = int(cmd.split(":")[1])
            state = "ON" if mapping[pin] else "OFF"
            respond(sock, f"MAP:{pin}:{state}")
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+MAP:"):
        try:
            parts = cmd.split(":")
            for i, val in enumerate(parts[1:]):
                if i < len(mapping):
                    mapping[i] = val.upper() == "T"
            respond(sock)
            for pin in range(N_CHANNELS):
                s = "ON" if mapping[pin] else "OFF"
                broadcast(f"AT+MAPSTAT:{pin}\r\nMAP:{pin}:{s}\r\n")
        except Exception:
            respond_error(sock)
        return

    if cmd.startswith("AT+TOGGLE:"):
        try:
            pin = int(cmd.split(":")[1])
            output_states[pin] = not output_states[pin]
            respond(sock)
            broadcast_output_change(pin)
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+ON:"):
        try:
            pin = int(cmd.split(":")[1])
            output_states[pin] = True
            respond(sock)
            broadcast_output_change(pin)
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+OFF:"):
        try:
            pin = int(cmd.split(":")[1])
            output_states[pin] = False
            respond(sock)
            broadcast_output_change(pin)
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd.startswith("AT+RESTART:"):
        try:
            pin = int(cmd.split(":")[1])
            output_states[pin] = False
            broadcast_output_change(pin)

            def delayed_on(p):
                time.sleep(5)
                output_states[p] = True
                broadcast_output_change(p)

            threading.Thread(target=delayed_on, args=(pin,), daemon=True).start()
            respond(sock)
        except (IndexError, ValueError):
            respond_error(sock)
        return

    if cmd == "AT+REBOOT":
        respond(sock)
        return

    if cmd == "AT+SCHEDULE":
        resp_lines = []
        for pin in range(N_CHANNELS):
            resp_lines.append(f"SCHEDULE_START:{pin}")
            for s in schedule_data:
                resp_lines.append(
                    f"SCHEDULE_RUNONES:ID:{s['ID']},RELAY:{s['RELAY']},"
                    f"DATETIME:{s['DATETIME']},ACTION:{s['ACTION']},"
                    f"PROCESSED:{s['PROCESSED']}"
                )
            for w in weekly_schedule_data:
                resp_lines.append(
                    f"SCHEDULE_WEEKLY:ID:{w['ID']},RELAY:{w['RELAY']},"
                    f"DATETIME:{w['DATETIME']},ACTION:{w['ACTION']},"
                    f"MON:{str(w['MON']).upper()},"
                    f"TUE:{str(w['TUE']).upper()},"
                    f"WED:{str(w['WED']).upper()},"
                    f"THU:{str(w['THU']).upper()},"
                    f"FRI:{str(w['FRI']).upper()},"
                    f"SAT:{str(w['SAT']).upper()},"
                    f"SUN:{str(w['SUN']).upper()}"
                )
            resp_lines.append(f"SCHEDULE_END:{pin}")
        respond(sock, "\r\n".join(resp_lines))
        return

    if cmd == "EXIT":
        send_tcp(sock, "Exiting Terminal \r\n")
        return

    respond_error(sock, "UNKNOWN_COMMAND")


# ─── TCP Client Handler ──────────────────────────────────────────────────────


def tcp_client_handler(client_sock: socket.socket, addr):
    client_ip = addr[0]
    print(f"[TCP] Connection from {addr}")

    if IP_WHITELIST and client_ip not in IP_WHITELIST:
        print(f"[TCP] Unauthorized IP: {client_ip}, closing")
        client_sock.close()
        return

    with tcp_clients_lock:
        old = tcp_clients.get(client_ip)
        if old:
            try:
                old.close()
            except Exception:
                pass
        tcp_clients[client_ip] = client_sock

    try:
        status_dump = build_status_dump()
        send_tcp(client_sock, status_dump)

        buffer = ""
        while True:
            try:
                data = client_sock.recv(TCP_BUFFER_SIZE)
                if not data:
                    break
                buffer += data.decode(errors="replace")
                print(f"[TCP] < {client_ip}: {buffer}")
                while "\r" in buffer:
                    line, buffer = buffer.split("\r", 1)
                    line = line.strip()
                    if not line:
                        continue
                    print(f"[TCP] < {client_ip}: {line}")
                    if line == "EXIT":
                        handle_command(client_sock, line)
                        return
                    handle_command(client_sock, line)
            except (ConnectionResetError, BrokenPipeError, OSError):
                break
    finally:
        with tcp_clients_lock:
            tcp_clients.pop(client_ip, None)
        client_sock.close()
        print(f"[TCP] Disconnected: {client_ip}")


# ─── TCP Server ──────────────────────────────────────────────────────────────


def tcp_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((TCP_HOST, TCP_PORT))
    server.listen(TCP_BACKLOG)
    print(f"[TCP] Server listening on {TCP_HOST}:{TCP_PORT}")

    while True:
        client_sock, addr = server.accept()
        thread = threading.Thread(
            target=tcp_client_handler, args=(client_sock, addr), daemon=True
        )
        thread.start()


# ─── UDP Discovery Server ────────────────────────────────────────────────────


def udp_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((UDP_HOST, UDP_PORT))
    print(f"[UDP] Discovery listening on {UDP_HOST}:{UDP_PORT}")

    while True:
        try:
            data, client_addr = sock.recvfrom(UDP_BUFFER_SIZE)
            print(f"[UDP] Received from {client_addr}: {data.decode(errors='replace')}")

            try:
                msg = json.loads(data.decode())
            except json.JSONDecodeError:
                print(f"[UDP] Invalid JSON from {client_addr}")
                continue

            if msg.get("GUID") != DISCOVERY_REQUEST_GUID:
                print(f"[UDP] Unknown GUID from {client_addr}")
                continue

            client_port = msg.get("PORT", msg.get("Port", msg.get("port")))
            if not isinstance(client_port, int):
                try:
                    client_port = int(client_port)
                except (TypeError, ValueError):
                    print(f"[UDP] Invalid Port from {client_addr}")
                    continue

            print(f"[UDP] Valid discovery request from {client_addr[0]}:{client_port}")

            def respond_to_discovery(ip: str, port: int):
                try:
                    resp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    resp_sock.settimeout(5)
                    resp_sock.connect((ip, port))
                    response = (
                        f"GUID:{PDU_RESPONSE_GUID}\r\n"
                        f"VER:{device_info['VER']}\r\n"
                        f"PORT:{TCP_PORT}\r\n"
                        f"SN:{device_info['SN']}\r\n"
                        f"NAME:{network_info['APP_NAME']}\r\n"
                        f"MAC:{PDU_MAC}\r\n"
                        f"API_PORT:{CONTROL_API_PORT}\r\n"
                        f"HEARTBEAT_PORT:{HEARTBEAT_PORT}\r\n"
                        f"API_VER:3\r\n"
                        f"CAPS:control_api_v3,heartbeat,l2\r\n"
                    )
                    send_tcp(resp_sock, response)
                    resp_sock.close()
                    print(f"[UDP] Discovery response sent to {ip}:{port}")
                except Exception as e:
                    print(f"[UDP] Failed to send discovery response: {e}")

            threading.Thread(
                target=respond_to_discovery,
                args=(client_addr[0], client_port),
                daemon=True,
            ).start()

        except Exception as e:
            print(f"[UDP] Error: {e}")


# ─── UDP Heartbeat Server (spec §4: ping -> pong) ───────────────────────────


def heartbeat_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((UDP_HOST, HEARTBEAT_PORT))
    print(f"[HB] Heartbeat listening on {UDP_HOST}:{HEARTBEAT_PORT}")

    while True:
        try:
            data, addr = sock.recvfrom(UDP_BUFFER_SIZE)
            try:
                msg = json.loads(data.decode())
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if msg.get("soleux_heartbeat") != 1 or msg.get("op") != "ping":
                continue
            nonce = msg.get("nonce", "")
            if not nonce or len(nonce) > 64:
                continue
            reply = json.dumps({
                "soleux_heartbeat": 1,
                "op": "pong",
                "nonce": nonce,
                "tcp_port": TCP_PORT,
                "name": network_info["APP_NAME"],
                "api_port": CONTROL_API_PORT,
                "api_version": 3,
                "device_id": device_info["SN"],
                "boot_id": "dummy-boot",
            })
            sock.sendto(reply.encode(), addr)
            print(f"[HB] pong -> {addr[0]}:{addr[1]} nonce={nonce}")
        except Exception as e:
            print(f"[HB] Error: {e}")


# ─── Socket.IO Server ────────────────────────────────────────────────────────

socket_app = Flask(__name__)
socket_app.config["SECRET_KEY"] = "pdu-dummy-secret"
socketio = SocketIO(socket_app, cors_allowed_origins="*")


def build_socket_states():
    return {
        "output": list(output_states),
        "input": list(input_states),
        "mapping": list(mapping),
    }


def socket_push(event: str, payload):
    """Emit an event to all Socket.IO clients from any thread."""
    try:
        socketio.emit(event, payload)
    except Exception as e:
        print(f"[SIO] push error: {e}")


@socketio.on("connect")
def _sio_connect():
    print(f"[SIO] Client connected: {request.sid}")
    emit("new states", build_socket_states())


@socketio.on("disconnect")
def _sio_disconnect():
    print(f"[SIO] Client disconnected: {request.sid}")


@socketio.on("is alive")
def _sio_is_alive():
    emit("is alive", "__ALIVE__")


@socketio.on("get states")
def _sio_get_states():
    emit("new states", build_socket_states())


@socketio.on("get pins")
def _sio_get_pins(data=None):
    pins = {
        "input": [
            {"id": i, "name": channel_names_in[i], "state": input_states[i]}
            for i in range(N_CHANNELS)
        ],
        "output": [
            {"id": i, "name": channel_names_out[i], "state": output_states[i]}
            for i in range(N_CHANNELS)
        ],
        "mapping": [
            {"id": i, "name": f"Map {i+1}", "state": mapping[i]}
            for i in range(N_CHANNELS)
        ],
    }
    emit("get pins", pins)


@socketio.on("change output state")
def _sio_change_output(payload):
    try:
        pin = int(payload.get("pin", payload.get("channel", 0)))
        output_states[pin] = not output_states[pin]
        broadcast_output_change(pin)
        socket_push("new states", build_socket_states())
    except Exception as e:
        print(f"[SIO] change output error: {e}")


@socketio.on("change mapping")
def _sio_change_mapping(payload):
    try:
        channel = int(payload.get("channel", payload.get("pin", 0)))
        state = bool(payload.get("state", payload.get("value", 0)))
        mapping[channel] = state
        socket_push("update mapping", {"channel": channel, "state": state})
        broadcast(f"AT+MAPSTAT:{channel}\r\nMAP:{channel}:{'ON' if state else 'OFF'}\r\n")
    except Exception as e:
        print(f"[SIO] change mapping error: {e}")


@socketio.on("restart output pin")
def _sio_restart_output(payload):
    try:
        pin = int(payload.get("pin", payload.get("channel", 0)))
        output_states[pin] = False
        broadcast_output_change(pin)
        socket_push("new states", build_socket_states())

        def delayed_on(p):
            time.sleep(5)
            output_states[p] = True
            broadcast_output_change(p)
            socket_push("new states", build_socket_states())

        threading.Thread(target=delayed_on, args=(pin,), daemon=True).start()
    except Exception as e:
        print(f"[SIO] restart output error: {e}")


@socketio.on("get temp_data")
def _sio_get_temp(data=None):
    payload = {
        "SYSTEMP": temperature_info["SYSTEMP"],
        "CPUTEMP": temperature_info["CPUTEMP"],
        "FAN_STATUS": temperature_info["FAN_STATUS"],
        "FAN_MODE": temperature_info["FAN_MODE"],
    }
    emit("temperature changed", payload)
    socket_push("temperature changed", payload)


@socketio.on("get general system info")
def _sio_general_info(data=None):
    emit("get general system info", {
        "cputemp": temperature_info["CPUTEMP"],
        "uptime": uptime_str(),
        "mode": "default",
        "fan": temperature_info["FAN_MODE"],
    })


@socketio.on("get tcp_ip_address")
def _sio_get_tcp_ips(data=None):
    emit("get tcp_ip_address", sorted(IP_WHITELIST))


@socketio.on("add tcp_ip_address")
def _sio_add_tcp_ip(payload):
    ip = (payload or {}).get("ip") or (payload or {}).get("address")
    if ip:
        IP_WHITELIST.add(ip.strip())
        print(f"[SIO] Whitelisted TCP IP: {ip}")


@socketio.on("delete tcp_ip_address")
def _sio_delete_tcp_ip(payload):
    ip = (payload or {}).get("ip") or (payload or {}).get("address")
    if ip:
        IP_WHITELIST.discard(ip.strip())


@socketio.on("get ssids")
def _sio_get_ssids(data=None):
    emit("get ssids", ["PDU_Network", "HomeWiFi_5G", "Guest_Network", "Office_2.4G"])


@socketio.on("get ssidsaved")
def _sio_get_ssidsaved(data=None):
    emit("get ssidsaved", {"ip": network_info["WIFIIP"], "ssid": network_info["WIFISSID"]})


@socketio.on("get wifi info")
def _sio_get_wifi_info(data=None):
    emit("get wifi info", {"ip": network_info["WIFIIP"], "ssid": network_info["WIFISSID"]})


@socketio.on("wifi connect")
def _sio_wifi_connect(payload):
    emit("wifi connect response", {"success": True, "ssid": (payload or {}).get("ssid", "")})


@socketio.on("wifi forget")
def _sio_wifi_forget(data=None):
    socket_push("refresh settings page", {"type": "wifi"})


@socketio.on("get timezones")
def _sio_get_timezones(data=None):
    emit("get timezones", ["UTC", "Asia/Shanghai", "Asia/Dubai", "Europe/London"])


@socketio.on("update firmware")
def _sio_update_firmware(data=None):
    socket_push("update_service::updating", "{}")

    def _done():
        time.sleep(3)
        socket_push("update_service::updated", "{}")

    threading.Thread(target=_done, daemon=True).start()


@socketio.on("get system logs")
def _sio_get_logs(data=None):
    emit("get system logs", [])


@socketio.on("delete system logs")
def _sio_delete_logs(data=None):
    pass


@socketio.on("get log tags")
def _sio_get_log_tags(data=None):
    emit("get log tags", ["power", "overcurrent", "reset", "schedule"])


@socketio.on("reboot bb")
def _sio_reboot(data=None):
    def _done():
        time.sleep(2)
        socket_push("new states", build_socket_states())

    threading.Thread(target=_done, daemon=True).start()


# Generic no-op handlers for the remaining schedule/profile/pin events to
# avoid "Invalid event" disconnects from the Web UI client.
for _evt in [
    "add relay_schedule", "save relay_schedule", "delete relay_schedule",
    "update relay_schedule", "add relay_schedule_daily",
    "save relay_schedule_daily", "delete relay_schedule_daily",
    "update relay_schedule_daily", "update tcp_ip_address",
    "update start_date", "update end_date", "update temp_name",
    "update pin", "set datetime", "get ssids",
    "wifi disconnect", "update profile settings", "update pdu name",
]:
    def _noop(payload=None, _evt=_evt):
        print(f"[SIO] {_evt}: {payload}")

    socketio.on(_evt)(_noop)


def socketio_server():
    print(f"[SIO] Socket.IO server listening on {SOCKETIO_HOST}:{SOCKETIO_PORT}")
    socketio.run(
        socket_app,
        host=SOCKETIO_HOST,
        port=SOCKETIO_PORT,
        debug=False,
        allow_unsafe_werkzeug=True,
    )


# ─── Dummy State Changer (for testing push broadcasts) ──────────────────────


def dummy_state_changer():
    pin_index = 0
    while True:
        time.sleep(15)
        output_states[pin_index] = not output_states[pin_index]
        broadcast_output_change(pin_index)
        socket_push("new states", build_socket_states())
        print(f"[SIM] Toggled output {pin_index} -> {'ON' if output_states[pin_index] else 'OFF'}")
        pin_index = (pin_index + 1) % N_CHANNELS


def main():
    print("=" * 60)
    print("  PDU Dummy Server")
    print(f"  TCP ASCII : {TCP_HOST}:{TCP_PORT}")
    print(f"  UDP Discov: {UDP_HOST}:{UDP_PORT}")
    print(f"  UDP Heart : {UDP_HOST}:{HEARTBEAT_PORT}")
    print(f"  Socket.IO : {SOCKETIO_HOST}:{SOCKETIO_PORT}")
    print("=" * 60)

    threads = [
        threading.Thread(target=tcp_server, daemon=True),
        threading.Thread(target=udp_server, daemon=True),
        threading.Thread(target=heartbeat_server, daemon=True),
        threading.Thread(target=socketio_server, daemon=True),
        #threading.Thread(target=dummy_state_changer, daemon=True),
    ]

    for t in threads:
        t.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nShutting down...")


if __name__ == "__main__":
    main()
