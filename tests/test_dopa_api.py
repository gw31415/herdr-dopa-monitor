#!/usr/bin/env python3
"""End-to-end contract tests for the native Swift guard and dopa API v1."""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class JsonLineServer:
    def __init__(self, path):
        self.path = str(path)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(8)
        self.listener.settimeout(0.1)
        self.stop_event = threading.Event()
        self.failures = []
        self.clients = []
        self.thread = threading.Thread(target=self._accept, daemon=True)
        self.thread.start()

    def _accept(self):
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            thread = threading.Thread(target=self.serve_client, args=(connection,), daemon=True)
            self.clients.append((connection, thread))
            thread.start()

    def serve_client(self, connection):
        raise NotImplementedError

    def send(self, connection, request, result=None, error=None):
        response = {"id": request.get("id")}
        if error is None:
            response["result"] = result if result is not None else {}
        else:
            response["error"] = error
        connection.sendall((json.dumps(response, separators=(",", ":")) + "\n").encode())

    @staticmethod
    def requests(connection):
        buffer = b""
        while True:
            data = connection.recv(65536)
            if not data:
                return
            buffer += data
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                if raw.strip():
                    yield json.loads(raw)

    def close(self):
        self.stop_event.set()
        try:
            self.listener.close()
        except OSError:
            pass
        for connection, _ in self.clients:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        self.thread.join(timeout=2)
        for _, thread in self.clients:
            thread.join(timeout=2)


class FakeHerdrServer(JsonLineServer):
    def __init__(self, path):
        self.working = True
        super().__init__(path)

    def serve_client(self, connection):
        try:
            for request in self.requests(connection):
                if request.get("method") != "agent.list":
                    self.send(connection, request, error={"code": "method_not_found"})
                    continue
                agents = [{"agent_status": "working"}] if self.working else []
                self.send(connection, request, result={"agents": agents})
        except (OSError, ValueError) as error:
            if not self.stop_event.is_set():
                self.failures.append(str(error))
        finally:
            try:
                connection.close()
            except OSError:
                pass


class FakeDopaServer(JsonLineServer):
    def __init__(self, path, daemon_version="0.3.3"):
        self.daemon_version = daemon_version
        self.acquired = threading.Event()
        self.disconnected = threading.Event()
        self.lock = threading.Lock()
        self.sessions = set()
        self.owned_connections = set()
        self.options = []
        self.acquire_count = 0
        super().__init__(path)

    def serve_client(self, connection):
        owned = set()
        try:
            for request in self.requests(connection):
                method = request.get("method")
                params = request.get("params")
                if not isinstance(params, dict):
                    self.send(connection, request, error={"code": "invalid_params"})
                elif method == "hello":
                    client = params.get("client", {})
                    if params.get("apiVersion") != 1 or client.get("name") != "herdr-dopa-monitor":
                        self.failures.append("invalid hello: %r" % request)
                    self.send(
                        connection,
                        request,
                        result={"apiVersion": 1, "daemonVersion": self.daemon_version},
                    )
                elif method == "session.acquire":
                    session = "fake-session"
                    with self.lock:
                        self.sessions.add(session)
                        self.owned_connections.add(connection)
                        self.options.append(params.get("options"))
                        self.acquire_count += 1
                    owned.add(session)
                    self.send(connection, request, result={"sessionId": session})
                    self.acquired.set()
                elif method == "session.release":
                    session = params.get("sessionId")
                    with self.lock:
                        self.sessions.discard(session)
                    owned.discard(session)
                    self.send(connection, request, result={})
                elif method == "status.get":
                    with self.lock:
                        sessions = [{"sessionId": value} for value in self.sessions]
                    self.send(connection, request, result={"sessions": sessions})
                else:
                    self.send(connection, request, error={"code": "method_not_found"})
        except (OSError, ValueError) as error:
            if not self.stop_event.is_set():
                self.failures.append(str(error))
        finally:
            with self.lock:
                for session in owned:
                    self.sessions.discard(session)
                self.owned_connections.discard(connection)
            if owned:
                self.disconnected.set()
            try:
                connection.close()
            except OSError:
                pass

    def disconnect_owned_clients(self):
        with self.lock:
            connections = list(self.owned_connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class NativeGuardContractTest(unittest.TestCase):
    def setUp(self):
        binary_override = os.environ.get("HERDR_DOPA_TEST_BINARY")
        self.binary = Path(binary_override) if binary_override else ROOT / "bin/herdr-dopa-monitor"
        if not self.binary.is_file():
            self.skipTest("build the release binary with scripts/build.sh first")

    def run_guard(self, command, env, timeout=15):
        return subprocess.run(
            [str(self.binary), *command],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
        )

    @staticmethod
    def wait_until(predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return False

    @staticmethod
    def process_is_alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def test_acquire_status_idle_release_and_disable_release(self):
        with tempfile.TemporaryDirectory(prefix="herdr-dopa-native-") as temp_name:
            temp = Path(temp_name)
            herdr = FakeHerdrServer(temp / "herdr.sock")
            dopa = FakeDopaServer(temp / "dopa.sock")
            registry = temp / "plugins.json"
            registry.write_text(
                '[{"plugin_id":"herdr-dopa-monitor","enabled":true}]\n',
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HERDR_SOCKET_PATH": herdr.path,
                    "DOPA_SOCK": dopa.path,
                    "HERDR_DOPA_CONFIG_DIR": str(temp / "config"),
                    "HERDR_DOPA_STATE_DIR": str(temp / "state"),
                    "HERDR_DOPA_PLUGIN_REGISTRY_FILE": str(registry),
                }
            )
            try:
                acquired = self.run_guard(["once"], env)
                self.assertEqual(acquired.returncode, 0, acquired.stderr)
                self.assertTrue(dopa.acquired.wait(5), dopa.failures)
                self.assertEqual(dopa.options[-1], {"keepDisplayOn": False})

                status = self.run_guard(["status", "--json"], env)
                self.assertEqual(status.returncode, 0, status.stderr)
                payload = json.loads(status.stdout)
                self.assertEqual(payload["monitor_state"], "on")
                self.assertEqual(payload["session_id"], "fake-session")
                self.assertTrue(payload["owned_session_alive"])
                self.assertEqual(payload["agents"]["working"], 1)

                herdr.working = False
                stopped = self.run_guard(["once"], env)
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
                self.assertTrue(dopa.disconnected.wait(5), dopa.failures)
                self.assertTrue(self.wait_until(lambda: not dopa.sessions))

                herdr.working = True
                dopa.acquired.clear()
                dopa.disconnected.clear()
                processes = [
                    subprocess.Popen(
                        [str(self.binary), "once"], cwd=ROOT, env=env,
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    for _ in range(2)
                ]
                results = [process.communicate(timeout=15) for process in processes]
                for process, (_, error) in zip(processes, results):
                    self.assertEqual(process.returncode, 0, error)
                self.assertTrue(dopa.acquired.wait(5), dopa.failures)
                self.assertEqual(dopa.acquire_count, 2, "concurrent once runs double-acquired")

                registry.write_text(
                    '[{"plugin_id":"herdr-dopa-monitor","enabled":false}]\n',
                    encoding="utf-8",
                )
                self.assertTrue(dopa.disconnected.wait(5), dopa.failures)
                self.assertTrue(self.wait_until(lambda: not dopa.sessions))
                self.assertEqual(herdr.failures, [])
                self.assertEqual(dopa.failures, [])
            finally:
                self.run_guard(["stop"], env)
                herdr.close()
                dopa.close()

    def test_incompatible_dopa_is_rejected_before_acquire(self):
        with tempfile.TemporaryDirectory(prefix="herdr-dopa-version-") as temp_name:
            temp = Path(temp_name)
            herdr = FakeHerdrServer(temp / "herdr.sock")
            dopa = FakeDopaServer(temp / "dopa.sock", daemon_version="0.3.2")
            registry = temp / "plugins.json"
            registry.write_text(
                '[{"plugin_id":"herdr-dopa-monitor","enabled":true}]\n', encoding="utf-8"
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HERDR_SOCKET_PATH": herdr.path,
                    "DOPA_SOCK": dopa.path,
                    "HERDR_DOPA_CONFIG_DIR": str(temp / "config"),
                    "HERDR_DOPA_STATE_DIR": str(temp / "state"),
                    "HERDR_DOPA_PLUGIN_REGISTRY_FILE": str(registry),
                }
            )
            try:
                result = self.run_guard(["once"], env)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = json.loads((temp / "state" / "state.json").read_text())
                self.assertEqual(state["monitor_state"], "error")
                self.assertIn("requires Dopa >=0.3.3", state["last_error"])
                self.assertEqual(dopa.acquire_count, 0)
            finally:
                self.run_guard(["stop"], env)
                herdr.close()
                dopa.close()

    def test_dopa_disconnect_exits_holder_from_socket_event(self):
        with tempfile.TemporaryDirectory(prefix="herdr-dopa-disconnect-") as temp_name:
            temp = Path(temp_name)
            herdr = FakeHerdrServer(temp / "herdr.sock")
            dopa = FakeDopaServer(temp / "dopa.sock")
            registry = temp / "plugins.json"
            registry.write_text(
                '[{"plugin_id":"herdr-dopa-monitor","enabled":true}]\n', encoding="utf-8"
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HERDR_SOCKET_PATH": herdr.path,
                    "DOPA_SOCK": dopa.path,
                    "HERDR_DOPA_CONFIG_DIR": str(temp / "config"),
                    "HERDR_DOPA_STATE_DIR": str(temp / "state"),
                    "HERDR_DOPA_PLUGIN_REGISTRY_FILE": str(registry),
                }
            )
            try:
                acquired = self.run_guard(["once"], env)
                self.assertEqual(acquired.returncode, 0, acquired.stderr)
                self.assertTrue(dopa.acquired.wait(5), dopa.failures)
                state = json.loads((temp / "state" / "state.json").read_text())
                holder_pid = state["holder_pid"]
                self.assertTrue(self.process_is_alive(holder_pid))

                dopa.disconnect_owned_clients()

                self.assertTrue(dopa.disconnected.wait(5), dopa.failures)
                self.assertTrue(
                    self.wait_until(lambda: not self.process_is_alive(holder_pid)),
                    "holder did not exit after the dopa socket closed",
                )
            finally:
                self.run_guard(["stop"], env)
                herdr.close()
                dopa.close()


if __name__ == "__main__":
    unittest.main()
