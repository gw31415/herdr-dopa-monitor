#!/usr/bin/env python3
"""Unit tests for config load/save/validate/env-overrides (isolated config
dir via HERDR_DOPA_CONFIG_DIR)."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import config  # noqa: E402


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["HERDR_DOPA_CONFIG_DIR"] = self.tmp.name
        os.environ["HERDR_DOPA_STATE_DIR"] = self.tmp.name
        for key in ("HERDR_DOPA_POLL_SECONDS", "HERDR_BIN_PATH", "DOPA_BIN"):
            os.environ.pop(key, None)

    def tearDown(self):
        self.tmp.cleanup()
        os.environ.pop("HERDR_DOPA_CONFIG_DIR", None)
        os.environ.pop("HERDR_DOPA_STATE_DIR", None)
        for key in ("HERDR_DOPA_POLL_SECONDS", "HERDR_BIN_PATH", "DOPA_BIN"):
            os.environ.pop(key, None)

    def test_defaults_when_missing(self):
        cfg = config.load_resolved()
        self.assertTrue(cfg["armed"])
        self.assertEqual(cfg["poll_seconds"], 5.0)
        self.assertFalse(cfg["keep_display_on"])
        self.assertFalse(cfg["stop_on_lid_close"])
        self.assertIn("dopa", cfg["dopa_bin"])

    def test_save_load_roundtrip(self):
        cfg = config.default_config()
        cfg["poll_seconds"] = 7.5
        cfg["keep_display_on"] = True
        config.save_config_file(cfg)
        back = config.load_resolved()
        self.assertEqual(back["poll_seconds"], 7.5)
        self.assertTrue(back["keep_display_on"])

    def test_unknown_keys_dropped(self):
        path = config.config_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"armed": False, "bogus_key": 1}))
        cfg = config.load_resolved()
        self.assertFalse(cfg["armed"])
        self.assertNotIn("bogus_key", cfg)

    def test_corrupt_file_gives_defaults(self):
        path = config.config_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{broken")
        cfg = config.load_resolved()
        self.assertEqual(cfg["poll_seconds"], 5.0)

    def test_validate_clamps(self):
        out = config.validate({"poll_seconds": 0.1, "stop_grace_seconds": -5,
                               "armed": "off", "keep_display_on": "yes"})
        self.assertEqual(out["poll_seconds"], 1.0)
        self.assertEqual(out["stop_grace_seconds"], 0.0)
        self.assertFalse(out["armed"])
        self.assertTrue(out["keep_display_on"])

    def test_env_overrides(self):
        os.environ["HERDR_DOPA_POLL_SECONDS"] = "9"
        os.environ["DOPA_BIN"] = "/tmp/custom/dopa"
        cfg = config.load_resolved()
        self.assertEqual(cfg["poll_seconds"], 9.0)
        self.assertEqual(cfg["dopa_bin"], "/tmp/custom/dopa")

    def test_partial_save_keeps_defaults(self):
        config.save_config_file({"armed": False})
        cfg = config.load_resolved()
        self.assertFalse(cfg["armed"])
        self.assertEqual(cfg["poll_seconds"], 5.0)


if __name__ == "__main__":
    unittest.main()
