#!/usr/bin/env python3
"""Unit tests for session naming / LaunchAgent path helpers."""

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import launchagent  # noqa: E402


class SessionTests(unittest.TestCase):
    def test_env_session_name_wins(self):
        os.environ["HERDR_SESSION_NAME"] = "work"
        try:
            self.assertEqual(launchagent.session_name(), "work")
        finally:
            os.environ.pop("HERDR_SESSION_NAME", None)

    def test_slug_stable_and_safe(self):
        with mock.patch.dict(os.environ, {"HERDR_SESSION_NAME": "my session/01"}):
            first = launchagent.session_slug()
            second = launchagent.session_slug()
        self.assertEqual(first, second)
        self.assertRegex(first, r"^[A-Za-z0-9_.-]+\.[0-9a-f]{8}$")
        self.assertNotIn("/", first)
        self.assertNotIn(" ", first)

    def test_label_format(self):
        with mock.patch.dict(os.environ, {"HERDR_SESSION_NAME": "default"}):
            self.assertTrue(launchagent.label().startswith("com.herdr.dopa.monitor."))

    def test_paths_layout(self):
        home = Path("/tmp/fakehome")
        with mock.patch.dict(os.environ, {"HERDR_SESSION_NAME": "s1"}, clear=False):
            os.environ.pop("HERDR_PLUGIN_CONFIG_DIR", None)
            os.environ.pop("HERDR_PLUGIN_STATE_DIR", None)
            p = launchagent.paths(home)
        self.assertTrue(str(p["plist"]).startswith("/tmp/fakehome"))
        self.assertTrue(p["plist"].name.startswith("com.herdr.dopa.monitor."))
        self.assertIn("herdr-dopa", str(p["log_dir"]))
        self.assertIn("herdr-dopa", str(p["config_dir"]))

    def test_plugin_roots_honored(self):
        home = Path("/tmp/fakehome")
        env = {"HERDR_SESSION_NAME": "s1",
               "HERDR_PLUGIN_CONFIG_DIR": "/tmp/cfg",
               "HERDR_PLUGIN_STATE_DIR": "/tmp/st"}
        with mock.patch.dict(os.environ, env, clear=False):
            p = launchagent.paths(home)
        self.assertTrue(str(p["config_dir"]).startswith("/tmp/cfg/"))
        self.assertTrue(str(p["state_dir"]).startswith("/tmp/st/"))


if __name__ == "__main__":
    unittest.main()
