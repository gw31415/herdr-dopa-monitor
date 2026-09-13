#!/usr/bin/env python3
"""Persistent, CLI-editable configuration for the dopa sleep guard.

Settings live in ``config.json`` under the config directory (see
:func:`config_dir`); runtime state lives in ``state.json`` under
:func:`state_dir`. Both resolve to per-session subdirectories so concurrent
herdr sessions stay isolated. The daemon re-reads ``config.json`` every poll
cycle, so ``guard.py set`` takes effect within one cycle **without
reinstalling the LaunchAgent**.

Load precedence when the daemon builds its runtime config is::

    environment variable (if set) > config.json > built-in default

Stdlib-only; never spawns subprocesses, so both the daemon and the CLI can
use it safely.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT_CONFIG = {
    "armed": True,
    "poll_seconds": 5.0,
    "start_grace_seconds": 5.0,
    "stop_grace_seconds": 30.0,
    # Provisional dopa location (user-specified). Point it at a stable PATH
    # copy once dopa is installed elsewhere; the daemon never rewrites it.
    "dopa_bin": "/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa",
    "keep_display_on": False,   # -> dopa --keep-display-on
    "stop_on_lid_close": False,  # -> dopa --stop-on-lid-close
    "herdr_bin_path": None,     # None -> HERDR_BIN_PATH env -> `which herdr`
}

# Environment variables that override the file value when set and non-empty.
_ENV_FLOAT = {
    "poll_seconds": "HERDR_DOPA_POLL_SECONDS",
    "start_grace_seconds": "HERDR_DOPA_START_GRACE_SECONDS",
    "stop_grace_seconds": "HERDR_DOPA_STOP_GRACE_SECONDS",
}

# Valid keys for `guard.py set`, in display order.
SET_KEYS = tuple(DEFAULT_CONFIG.keys())


def _legacy_dir() -> Path:
    """Standalone fallback root (also where pre-herdr runs keep working)."""
    return Path.home() / "Library" / "Application Support" / "herdr-dopa"


def config_dir() -> Path:
    """Where ``config.json`` (user-editable settings) lives."""
    override = os.environ.get("HERDR_DOPA_CONFIG_DIR")
    if override:
        return Path(override)
    return _legacy_dir()


def state_dir() -> Path:
    """Where ``state.json`` (runtime monitor state) lives."""
    override = os.environ.get("HERDR_DOPA_STATE_DIR")
    if override:
        return Path(override)
    return _legacy_dir()


def config_path() -> Path:
    return config_dir() / "config.json"


def default_config() -> dict:
    """Return a fresh, independent copy of the defaults."""
    return json.loads(json.dumps(DEFAULT_CONFIG))  # deep copy of plain JSON data


def load_config_file() -> dict:
    """Load ``config.json`` merged over defaults. Never raises.

    Missing file -> defaults. Corrupt/unreadable -> defaults. Unknown keys are
    dropped so the schema stays forward-compatible. This does NOT rewrite a
    missing/corrupt file; the caller (installer/CLI) may re-save explicitly.
    """
    cfg = default_config()
    path = config_path()
    try:
        if path.exists():
            data = json.loads(path.read_text())
            if isinstance(data, dict):
                for key in DEFAULT_CONFIG:
                    if key in data:
                        cfg[key] = data[key]
    except (OSError, ValueError):
        pass
    return cfg


def save_config_file(cfg: dict) -> None:
    """Atomically write ``config.json`` (only known keys, validated first).

    Safe to call with a partial dict; missing keys fall back to defaults.
    """
    normalized = validate({k: cfg.get(k, DEFAULT_CONFIG[k]) for k in DEFAULT_CONFIG})
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(normalized, indent=2))
    os.replace(tmp, path)


def _to_float(val, default):
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def _to_bool(val, default):
    if isinstance(val, bool):
        return val
    if val is None:
        return default
    s = str(val).strip().lower()
    if s in ("1", "true", "yes", "y", "on", "armed"):
        return True
    if s in ("0", "false", "no", "n", "off", "disarmed"):
        return False
    return default


def validate(cfg: dict) -> dict:
    """Coerce and clamp values into a sane config. Returns a new dict.

    Numerics are clamped non-negative (poll >= 1s); booleans accept bool or the
    common true/false/on/off strings; ``herdr_bin_path``/``dopa_bin`` may be
    empty (dopa_bin then falls back to the built-in default).
    """
    out = default_config()
    out.update(cfg or {})
    out["armed"] = _to_bool(out.get("armed"), True)
    out["keep_display_on"] = _to_bool(out.get("keep_display_on"), False)
    out["stop_on_lid_close"] = _to_bool(out.get("stop_on_lid_close"), False)
    out["poll_seconds"] = max(1.0, _to_float(out.get("poll_seconds"), 5.0))
    out["start_grace_seconds"] = max(0.0, _to_float(out.get("start_grace_seconds"), 5.0))
    out["stop_grace_seconds"] = max(0.0, _to_float(out.get("stop_grace_seconds"), 30.0))
    for key in ("herdr_bin_path",):
        val = out.get(key)
        out[key] = str(val).strip() or None if val is not None else None
    dopa = out.get("dopa_bin")
    out["dopa_bin"] = str(dopa).strip() or DEFAULT_CONFIG["dopa_bin"]
    return out


def apply_env_overrides(cfg: dict) -> dict:
    """Apply ``HERDR_DOPA_*`` / ``HERDR_BIN_PATH`` / ``DOPA_BIN`` env overrides.

    Env is applied only when the variable is set and non-empty, so an unset env
    leaves the file value intact.
    """
    out = dict(cfg)
    for key, env in _ENV_FLOAT.items():
        raw = os.environ.get(env)
        if raw is not None and raw != "":
            out[key] = _to_float(raw, out.get(key))
    herdr = os.environ.get("HERDR_BIN_PATH")
    if herdr:
        out["herdr_bin_path"] = herdr
    dopa = os.environ.get("DOPA_BIN")
    if dopa:
        out["dopa_bin"] = dopa
    return out


def load_resolved() -> dict:
    """Convenience: file -> env overrides -> validate. The canonical read path."""
    return validate(apply_env_overrides(load_config_file()))
