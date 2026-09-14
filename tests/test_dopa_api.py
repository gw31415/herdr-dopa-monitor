#!/usr/bin/env python3
"""Exercise the raw dopa API v1 boundary with a fake Unix socket."""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FakeDopaServer:
    """Small, dependency-free dopa control socket used by the contract test."""

    def __init__(self, path):
        self.path = str(path)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.stop = threading.Event()
        self.connected = threading.Event()
        self.disconnected = threading.Event()
        self.release_seen = threading.Event()
        self.requests = []
        self.failures = []
        self.connection = None
        self.thread = threading.Thread(target=self._serve, name="fake-dopa", daemon=True)
        self.thread.start()

    def _fail(self, message):
        self.failures.append(message)

    def _send(self, request, result=None, error=None):
        if self.connection is None:
            return
        response = {"id": request.get("id")}
        if error is not None:
            response["error"] = error
        else:
            response["result"] = result if result is not None else {}
        try:
            self.connection.sendall(
                (json.dumps(response, separators=(",", ":")) + "\n").encode("utf-8")
            )
        except OSError as exc:
            if not self.stop.is_set():
                self._fail("failed to send response: %s" % exc)

    def _handle(self, request):
        self.requests.append(request)
        method = request.get("method")
        params = request.get("params")
        if not isinstance(params, dict):
            self._fail("%s did not contain an object params value" % method)
            self._send(request, error={"code": "invalid_params"})
            return

        if method == "hello":
            if params.get("apiVersion") != 1:
                self._fail("hello apiVersion was %r, expected 1" % params.get("apiVersion"))
            client = params.get("client")
            if not isinstance(client, dict):
                self._fail("hello client was not an object")
            elif client.get("name") != "herdr-dopa-monitor":
                self._fail("hello client name was %r" % client.get("name"))
            self._send(
                request,
                result={"apiVersion": 1, "daemonVersion": "fake-dopa-0.0.0"},
            )
            return

        if method == "session.acquire":
            options = params.get("options")
            if not isinstance(options, dict):
                self._fail("session.acquire did not contain an options object")
            self._send(request, result={"sessionId": "fake-session"})
            return

        if method == "session.release":
            if params.get("sessionId") != "fake-session":
                self._fail("session.release sessionId was %r" % params.get("sessionId"))
            self.release_seen.set()
            self._send(request, result={})
            return

        self._fail("unexpected dopa method: %r" % method)
        self._send(request, error={"code": "method_not_found"})

    def _serve(self):
        conn = None
        try:
            while not self.stop.is_set():
                try:
                    conn, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
                except OSError:
                    return
            if conn is None:
                return
            self.connection = conn
            self.connection.settimeout(0.2)
            self.connected.set()
            buffer = b""
            while not self.stop.is_set():
                try:
                    data = self.connection.recv(4096)
                except socket.timeout:
                    continue
                except OSError as exc:
                    if not self.stop.is_set():
                        self._fail("socket receive failed: %s" % exc)
                    break
                if not data:
                    self.disconnected.set()
                    break
                buffer += data
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    if not raw.strip():
                        continue
                    try:
                        request = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        self._fail("invalid JSON request: %s" % exc)
                        continue
                    self._handle(request)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except OSError:
                    pass
            self.connection = None
            self.disconnected.set()

    def close(self):
        self.stop.set()
        if self.connection is not None:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.connection.close()
            except OSError:
                pass
        try:
            self.listener.close()
        except OSError:
            pass
        self.thread.join(timeout=2)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


class DopaApiContractTest(unittest.TestCase):
    def run_shell(self, script, env, timeout=15):
        return subprocess.run(
            ["/bin/sh", "-c", script, "dopa-contract-test", str(ROOT)],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
        )

    def test_hello_builder_uses_api_v1(self):
        result = self.run_shell(
            'ROOT="$1"; . "$ROOT/guard/lib.sh"; dopa_hello contract-hello',
            os.environ.copy(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        request = json.loads(result.stdout)
        self.assertEqual(request["id"], "contract-hello")
        self.assertEqual(request["method"], "hello")
        self.assertEqual(request["params"]["apiVersion"], 1)
        self.assertEqual(request["params"]["client"]["name"], "herdr-dopa-monitor")
        self.assertEqual(request["params"]["client"]["version"], "0.1.0")

    def test_hello_validator_rejects_incompatible_or_error_responses(self):
        result = self.run_shell(
            r'''
set -eu
ROOT="$1"
. "$ROOT/guard/lib.sh"
dopa_hello_v1_ok '{"id":"hello","result":{"apiVersion":1}}'
dopa_hello_v1_ok '{"id":"hello","result":{"apiVersion":1.0}}'
! dopa_hello_v1_ok '{"id":"hello","result":{"apiVersion":2}}'
! dopa_hello_v1_ok '{"id":"hello","error":{"code":"unsupported_version"}}'
! dopa_hello_v1_ok ''
''',
            os.environ.copy(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_acquire_release_and_disconnect_contract(self):
        with tempfile.TemporaryDirectory(prefix="herdr-dopa-contract-") as temp_dir:
            temp = Path(temp_dir)
            socket_path = temp / "dopa.sock"
            state_dir = temp / "state"
            config_dir = temp / "config"
            registry = temp / "plugins.json"
            registry.write_text(
                '[{"plugin_id":"herdr-dopa-monitor","enabled":true}]\n',
                encoding="utf-8",
            )
            server = FakeDopaServer(socket_path)
            env = os.environ.copy()
            env.update(
                {
                    "DOPA_SOCK": str(socket_path),
                    "HERDR_DOPA_STATE_DIR": str(state_dir),
                    "HERDR_DOPA_CONFIG_DIR": str(config_dir),
                    "HERDR_DOPA_PLUGIN_REGISTRY_FILE": str(registry),
                    "HOME": str(temp / "home"),
                }
            )
            script = r'''
set -eu
ROOT="$1"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
. "$ROOT/guard/lib.sh"
load_config
SESSION_ID="$(dopa_acquire)"
[ "$SESSION_ID" = "fake-session" ]
dopa_release
'''
            try:
                result = self.run_shell(script, env)
                self.assertEqual(
                    result.returncode,
                    0,
                    "shell contract failed\nstdout:\n%s\nstderr:\n%s"
                    % (result.stdout, result.stderr),
                )
                self.assertTrue(
                    server.release_seen.wait(5),
                    "fake dopa did not receive session.release; requests=%r"
                    % server.requests,
                )
                self.assertTrue(
                    server.disconnected.wait(5),
                    "dopa holder did not disconnect after release; requests=%r"
                    % server.requests,
                )
                self.assertEqual(
                    [request.get("method") for request in server.requests],
                    ["hello", "session.acquire", "session.release"],
                )
                self.assertEqual(server.requests[0]["params"]["apiVersion"], 1)
                self.assertEqual(
                    server.requests[1]["params"]["options"]["keepDisplayOn"], False
                )
                self.assertEqual(server.requests[2]["params"]["sessionId"], "fake-session")
                self.assertEqual(server.failures, [])
            finally:
                server.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
