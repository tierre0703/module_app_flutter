#!/usr/bin/env python3
"""
Probe a Soleux device over TCP: connect, continuously print every received
line, and send the standard discovery/configuration commands:

    hello, get_device_info, get_relay_configuration

Per doc/Soleux-Mobile-TCP-Protocol.md:
- Requests are UTF-8 text lines terminated with CRLF.
- JSON requests use the ``J:{"id":N,"action":"...","params":{}}`` envelope.
- The device may send unsolicited status lines at any time, so we print
  everything we receive and match JSON responses by request ``id``.

Usage:
    python mock/probe_device_9001.py
    python mock/probe_device_9001.py --ip 90.8.178.220 --port 9001
"""

import argparse
import json
import socket
import sys
import threading
import time

HOST = "90.8.178.220"
PORT = 9001
CONNECT_TIMEOUT = 5.0
RECV_TIMEOUT = 60.0

# Commands to send, in order, with their request ids.
COMMANDS = ["hello", "get_device_info", "get_relay_configuration"]

_lock = threading.Lock()


def ts():
    return time.strftime("%H:%M:%S")


def log(tag, text):
    with _lock:
        print(f"[{ts()}] {tag} {text}", flush=True)


class DeviceProbe:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.sock = None
        self.pending = {}          # id -> {"action": ..., "event": threading.Event, "lines": []}
        self.next_id = 1
        self.reader = None

    def connect(self):
        log("CONN", f"connecting to {self.host}:{self.port} ...")
        self.sock = socket.create_connection((self.host, self.port), timeout=CONNECT_TIMEOUT)
        self.sock.settimeout(1.0)  # reader polls so Ctrl-C stays responsive
        log("CONN", "connected")

        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        """Continuously receive and print everything the device sends."""
        buf = b""
        while True:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                log("DISC", "connection closed by device")
                break

            # Print raw bytes too (helps spot framing oddities), then buffer.
            log("RAW ", repr(chunk))
            buf += chunk

            # Split complete CRLF/LF/CR-terminated lines and print each one.
            while b"\n" in buf or b"\r" in buf:
                # Find earliest terminator
                i_lf = buf.find(b"\n")
                i_cr = buf.find(b"\r")
                idx = min(x for x in (i_lf, i_cr) if x != -1)
                line, buf = buf[:idx], buf[idx + 1:]
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                self._handle_line(text)

    def _handle_line(self, text):
        if text.startswith("J:"):
            try:
                msg = json.loads(text[2:])
            except json.JSONDecodeError as exc:
                log("ERR ", f"bad JSON: {text} ({exc})")
                return
            log("RECV", text)
            msg_id = msg.get("id")
            waiter = self.pending.pop(msg_id, None) if msg_id is not None else None
            if waiter is not None:
                waiter["lines"].append(msg)
                waiter["event"].set()
        else:
            # Unsolicited legacy/status/event line (e.g. ``OUT:0:ON``).
            log("RECV", text)

    def send_command(self, action, params=None, wait=RECV_TIMEOUT):
        """Send one J: command and wait for the matching JSON response."""
        req_id = self.next_id
        self.next_id += 1
        request = "J:" + json.dumps({"id": req_id, "action": action, "params": params or {}})

        waiter = {"action": action, "event": threading.Event(), "lines": []}
        self.pending[req_id] = waiter

        log("SEND", request)
        self.sock.sendall((request + "\r\n").encode("utf-8"))

        if not waiter["event"].wait(wait):
            self.pending.pop(req_id, None)
            log("TIME", f"no response to '{action}' (id={req_id}) within {wait}s")
            return None
        return waiter["lines"]

    def close(self):
        try:
            # Optional clean shutdown, per protocol doc.
            self.sock.sendall(b"EXIT\r\n")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        log("CONN", "closed")


def main():
    ap = argparse.ArgumentParser(description="Probe Soleux TCP device and print all received messages")
    ap.add_argument("--ip", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--listen", action="store_true",
                    help="keep listening for unsolicited messages after the commands finish")
    ap.add_argument("--drain", type=float, default=2.0,
                    help="seconds to wait for late/unsolicited lines before exiting (default 2)")
    args = ap.parse_args()

    probe = DeviceProbe(args.ip, args.port)
    try:
        probe.connect()
        time.sleep(0.5)  # give any unsolicited greeting lines a moment

        for action in COMMANDS:
            responses = probe.send_command(action)
            if responses:
                for msg in responses:
                    ok = msg.get("ok")
                    tag = "OK  " if ok else "FAIL"
                    result = msg.get("result") or msg.get("error")
                    log(tag, f"{action} -> {json.dumps(result, ensure_ascii=False)}")
            else:
                log("FAIL", f"{action} -> no response")

        if args.listen:
            # Keep receiving: the device may push unsolicited status/event lines.
            log("----", "listening for further device messages (Ctrl-C to quit)")
            while True:
                time.sleep(0.5)
        else:
            # Fully automatic: give late/unsolicited lines a short drain window,
            # then exit without any user interaction.
            log("----", f"draining remaining device output for {args.drain}s ...")
            time.sleep(args.drain)
    except KeyboardInterrupt:
        print()
        log("EXIT", "interrupted by user")
    except OSError as exc:
        log("ERR ", f"connection error: {exc}")
        sys.exit(1)
    finally:
        probe.close()


if __name__ == "__main__":
    main()
