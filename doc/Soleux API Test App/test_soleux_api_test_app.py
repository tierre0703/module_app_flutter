import json
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from soleux_api_test_app import (
    COMMAND_PRESETS,
    DEVICE_PROFILES,
    PROFILE_AUTO,
    PROFILE_DIMMER,
    PROFILE_ENERGY,
    PROFILE_HIGH_POWER,
    PROFILE_MODBUS_HUB,
    PROFILE_PDU_V1,
    PROFILE_RELAY,
    ControlApiClient,
    actions_for_profile,
    build_request,
    control_api_port,
    preset_for_action,
    profile_from_hello_response,
    protocol_for_profile,
)


class SoleuxApiTestAppTests(unittest.TestCase):
    def test_control_port_is_legacy_plus_three(self):
        self.assertEqual(5008, control_api_port(5005))
        self.assertEqual(6003, control_api_port(6000))

    def test_request_envelope(self):
        request = build_request("hello", {}, "test-1")
        self.assertEqual(2, request["protocol"])
        self.assertEqual("test-1", request["id"])
        self.assertEqual("hello", request["action"])
        self.assertEqual({}, request["params"])

        hub_request = build_request(
            "hello", {}, "hub-test-1", protocol_for_profile(PROFILE_MODBUS_HUB))
        self.assertEqual(1, hub_request["protocol"])
        self.assertEqual(2, protocol_for_profile(PROFILE_AUTO))

    def test_every_command_preset_builds_a_valid_request(self):
        for action, params in COMMAND_PRESETS.items():
            with self.subTest(action=action):
                request = build_request(action, params, "preset-test")
                self.assertEqual(action, request["action"])
                self.assertIsInstance(request["params"], dict)

    def test_all_device_profiles_have_valid_filtered_presets(self):
        self.assertEqual(set(DEVICE_PROFILES), {
            PROFILE_AUTO, PROFILE_RELAY, PROFILE_DIMMER, PROFILE_ENERGY,
            PROFILE_HIGH_POWER, PROFILE_PDU_V1, PROFILE_MODBUS_HUB,
        })
        for profile in DEVICE_PROFILES:
            actions = actions_for_profile(profile)
            self.assertIn("hello", actions)
            for action in actions:
                with self.subTest(profile=profile, action=action):
                    self.assertIn(action, COMMAND_PRESETS)
                    self.assertIsInstance(preset_for_action(profile, action), dict)

        self.assertIn("set_dimmer_level", actions_for_profile(PROFILE_DIMMER))
        self.assertIn("get_output_groups", actions_for_profile(PROFILE_DIMMER))
        self.assertIn("save_output_group", actions_for_profile(PROFILE_DIMMER))
        self.assertIn("delete_output_group", actions_for_profile(PROFILE_DIMMER))
        self.assertIn("rewrite_output_groups", actions_for_profile(PROFILE_DIMMER))
        self.assertNotIn("set_dimmer_level", actions_for_profile(PROFILE_RELAY))
        self.assertIn("get_energy_state", actions_for_profile(PROFILE_ENERGY))
        self.assertNotIn("get_energy_state", actions_for_profile(PROFILE_HIGH_POWER))
        self.assertNotIn("set_input_state", actions_for_profile(PROFILE_PDU_V1))
        self.assertNotIn("write_hardware", actions_for_profile(PROFILE_PDU_V1))
        self.assertIn("get_dashboard", actions_for_profile(PROFILE_MODBUS_HUB))
        self.assertIn("set_modbus_output", actions_for_profile(PROFILE_MODBUS_HUB))
        self.assertIn("get_tag", actions_for_profile(PROFILE_MODBUS_HUB))
        self.assertNotIn(
            "get_device_state", actions_for_profile(PROFILE_MODBUS_HUB))
        self.assertEqual(
            1, preset_for_action(PROFILE_MODBUS_HUB, "set_output")["channel"])
        self.assertEqual(
            (
                "hello", "get_dashboard", "set_output", "pulse_output",
                "set_modbus_output", "restart_modbus_output", "set_tag",
                "get_tag", "get_device_info", "get_system",
                "clear_system_logs", "get_settings", "save_settings",
                "settings_action", "transfer_upload_begin",
                "transfer_upload_chunk", "transfer_upload_finish",
                "transfer_commit", "settings_backup_download_begin",
                "transfer_download_chunk", "transfer_download_finish",
                "get_security", "save_security", "security_action",
                "get_users", "save_user", "get_user_permissions",
                "save_user_permissions", "get_io_configuration",
                "save_io_channel", "rewrite_io_hardware",
            ),
            actions_for_profile(PROFILE_MODBUS_HUB),
        )

    def test_device_specific_presets_are_detached(self):
        dimmer = preset_for_action(PROFILE_DIMMER, "set_output_configuration")
        pdu_v1 = preset_for_action(PROFILE_PDU_V1, "set_output_configuration")
        self.assertEqual(50, dimmer["pwm"])
        self.assertNotIn("pwm", pdu_v1)
        dimmer["pwm"] = 99
        self.assertEqual(
            50, preset_for_action(PROFILE_DIMMER, "set_output_configuration")["pwm"])

    def test_hello_response_detects_every_device_family(self):
        expected = {
            "relay_module": PROFILE_RELAY,
            "dimmer": PROFILE_DIMMER,
            "pdu_energy_meter": PROFILE_ENERGY,
            "pdu_10kw": PROFILE_HIGH_POWER,
            "pdu_v1": PROFILE_PDU_V1,
        }
        for device, profile in expected.items():
            with self.subTest(device=device):
                response = {"ok": True, "result": {"device": device}}
                self.assertEqual(profile, profile_from_hello_response(response))
        hub_response = {
            "id": "hub-1", "ok": True,
            "result": {"protocol": 1, "device_type": "modbus_hub"},
        }
        self.assertEqual(
            PROFILE_MODBUS_HUB, profile_from_hello_response(hub_response))
        self.assertIsNone(profile_from_hello_response({"ok": False}))

    def test_tcp_round_trip(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        control_port = listener.getsockname()[1]
        received = {}

        def serve_once():
            connection, unused_address = listener.accept()
            with connection:
                data = b""
                while b"\n" not in data:
                    data += connection.recv(4096)
                received.update(json.loads(data.splitlines()[0]))
                connection.sendall(b'{"protocol":2,"id":"tcp-1","ok":true,"result":{"device":"relay_module"}}\r\n')
            listener.close()

        server = threading.Thread(target=serve_once, daemon=True)
        server.start()
        client = ControlApiClient("127.0.0.1", legacy_port=control_port - 3, timeout=2)
        result = client.send("TCP", build_request("hello", {}, "tcp-1"))
        server.join(2)
        self.assertEqual("hello", received["action"])
        self.assertTrue(result.response["ok"])
        self.assertEqual("relay_module", result.response["result"]["device"])

    def test_tcp_round_trip_skips_modbus_hub_greeting(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        control_port = listener.getsockname()[1]
        received = {}

        def serve_once():
            connection, unused_address = listener.accept()
            with connection:
                connection.sendall(b"Soleux JSON API Ready\r\n")
                data = b""
                while b"\n" not in data:
                    data += connection.recv(4096)
                received.update(json.loads(data.splitlines()[0]))
                connection.sendall(
                    b'{"id":"hub-1","ok":true,"result":'
                    b'{"protocol":1,"device_type":"modbus_hub"}}\r\n')
            listener.close()

        server = threading.Thread(target=serve_once, daemon=True)
        server.start()
        client = ControlApiClient(
            "127.0.0.1", legacy_port=control_port - 3, timeout=2)
        result = client.send(
            "TCP", build_request("hello", {}, "hub-1", protocol_version=1))
        server.join(2)
        self.assertEqual(1, received["protocol"])
        self.assertTrue(result.response["ok"])
        self.assertEqual(
            "modbus_hub", result.response["result"]["device_type"])
        self.assertTrue(result.raw_response.startswith('{"id":"hub-1"'))

    def test_http_round_trip(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received["path"] = self.path
                received["body"] = json.loads(self.rfile.read(length))
                body = b'{"protocol":2,"id":"http-1","ok":true,"result":{"api_port":5008}}\n'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, unused_format, *unused_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = ControlApiClient(
                "127.0.0.1", timeout=2, http_port=server.server_address[1])
            result = client.send("HTTP", build_request("hello", {}, "http-1"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)
        self.assertEqual("/api/v1/command", received["path"])
        self.assertEqual("hello", received["body"]["action"])
        self.assertEqual(200, result.status_code)
        self.assertTrue(result.response["ok"])


if __name__ == "__main__":
    unittest.main()
