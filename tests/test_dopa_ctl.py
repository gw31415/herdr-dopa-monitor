#!/usr/bin/env python3
"""Unit tests for dopa_ctl: argv building, PID liveness, and real spawn /
terminate cycles against a stub executable (no real dopa needed)."""

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import dopa_ctl  # noqa: E402

STUB = """#!/bin/sh
# Behaves like `dopa` for lifecycle tests: runs until SIGTERM, then exits 0.
trap 'exit 0' TERM
while true; do sleep 0.2; done
"""


class BinPathTests(unittest.TestCase):
    def test_default(self):
        os.environ.pop("DOPA_BIN", None)
        self.assertEqual(dopa_ctl.bin_path(), dopa_ctl.DEFAULT_DOPA_BIN)

    def test_configured(self):
        os.environ.pop("DOPA_BIN", None)
        self.assertEqual(dopa_ctl.bin_path("/tmp/x/dopa"), "/tmp/x/dopa")

    def test_env_wins(self):
        os.environ["DOPA_BIN"] = "/tmp/env/dopa"
        try:
            self.assertEqual(dopa_ctl.bin_path("/tmp/x/dopa"), "/tmp/env/dopa")
        finally:
            os.environ.pop("DOPA_BIN", None)


class ArgvTests(unittest.TestCase):
    def test_bare(self):
        self.assertEqual(dopa_ctl.build_argv("/tmp/dopa"), ["/tmp/dopa"])

    def test_display_flag(self):
        self.assertEqual(dopa_ctl.build_argv("/tmp/dopa", keep_display_on=True),
                         ["/tmp/dopa", "--keep-display-on"])

    def test_lid_flag(self):
        self.assertEqual(dopa_ctl.build_argv("/tmp/dopa", stop_on_lid_close=True),
                         ["/tmp/dopa", "--stop-on-lid-close"])

    def test_both_flags(self):
        self.assertEqual(
            dopa_ctl.build_argv("/tmp/dopa", True, True),
            ["/tmp/dopa", "--keep-display-on", "--stop-on-lid-close"])


class PidAliveTests(unittest.TestCase):
    def test_self_alive(self):
        self.assertTrue(dopa_ctl.is_pid_alive(os.getpid()))

    def test_none_dead(self):
        self.assertFalse(dopa_ctl.is_pid_alive(None))

    def test_bogus_dead(self):
        self.assertFalse(dopa_ctl.is_pid_alive(999999999))

    def test_garbage_dead(self):
        self.assertFalse(dopa_ctl.is_pid_alive("nope"))
        self.assertFalse(dopa_ctl.is_pid_alive(-3))


class SpawnTerminateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.stub = Path(self.tmp.name) / "dopa-stub"
        self.stub.write_text(STUB)
        self.stub.chmod(self.stub.stat().st_mode | stat.S_IXUSR)

    def tearDown(self):
        self.tmp.cleanup()

    def test_spawn_and_terminate(self):
        proc = dopa_ctl.spawn_session(str(self.stub))
        try:
            self.assertTrue(dopa_ctl.is_pid_alive(proc.pid))
        finally:
            self.assertTrue(dopa_ctl.terminate_session(proc.pid))
        self.assertFalse(dopa_ctl.is_pid_alive(proc.pid))
        try:
            proc.wait(timeout=10)
        except ChildProcessError:
            pass  # already reaped by terminate_session

    def test_spawn_with_flags(self):
        proc = dopa_ctl.spawn_session(str(self.stub), True, True)
        try:
            self.assertTrue(dopa_ctl.is_pid_alive(proc.pid))
        finally:
            dopa_ctl.terminate_session(proc.pid)
            try:
                proc.wait(timeout=10)
            except ChildProcessError:
                pass  # already reaped by terminate_session

    def test_terminate_missing_pid_is_success(self):
        self.assertTrue(dopa_ctl.terminate_session(999999999))
        self.assertTrue(dopa_ctl.terminate_session(None))

    def test_spawn_missing_binary_raises(self):
        with self.assertRaises(dopa_ctl.DopaError):
            dopa_ctl.spawn_session("/nonexistent/dopa-binary-xyz")

    def test_is_available(self):
        os.environ.pop("DOPA_BIN", None)
        self.assertTrue(dopa_ctl.is_dopa_available(str(self.stub)))
        self.assertFalse(dopa_ctl.is_dopa_available("/nonexistent/dopa-binary-xyz"))


class DaemonStatusTests(unittest.TestCase):
    def test_unavailable_returns_none(self):
        self.assertIsNone(dopa_ctl.daemon_status("/nonexistent/dopa-binary-xyz"))


if __name__ == "__main__":
    unittest.main()
