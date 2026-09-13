#!/usr/bin/env python3
"""Thin, auditable wrappers around the dopa CLI.

A dopa session is bound to the lifetime of its ``dopa`` process: while the
process runs, the Mac stays awake (via the dopa-daemon service); ending the
process (SIGTERM/SIGINT/SIGHUP/SIGQUIT) ends only that session. The monitor
therefore owns exactly one child ``dopa`` process and never touches sessions
created by the user, Dopa.app, or another tool.

All public functions map to one observable behavior each. No AppleScript, no
UI automation, no Accessibility prompts.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional

# Provisional install location the user pointed at. Override per-machine with
# the ``dopa_bin`` config key or the DOPA_BIN environment variable.
DEFAULT_DOPA_BIN = "/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa"

_TERMINATE_TIMEOUT_SECONDS = 10.0


class DopaError(RuntimeError):
    """Raised when the dopa CLI cannot be started, signalled, or queried."""


def bin_path(configured: Optional[str] = None) -> str:
    """Resolve the dopa binary: DOPA_BIN env > configured value > default."""
    env = os.environ.get("DOPA_BIN")
    if env and env.strip():
        return env.strip()
    if configured and str(configured).strip():
        return str(configured).strip()
    return DEFAULT_DOPA_BIN


def is_dopa_available(bin: Optional[str] = None) -> bool:
    """Cheap, side-effect-free existence check for the dopa binary."""
    candidate = bin_path(bin)
    return Path(candidate).is_file() and os.access(candidate, os.X_OK)


def build_argv(
    bin: Optional[str] = None,
    keep_display_on: bool = False,
    stop_on_lid_close: bool = False,
) -> list:
    """Build the argv for one owned dopa session."""
    argv = [bin_path(bin)]
    if keep_display_on:
        argv.append("--keep-display-on")
    if stop_on_lid_close:
        argv.append("--stop-on-lid-close")
    return argv


def spawn_session(
    bin: Optional[str] = None,
    keep_display_on: bool = False,
    stop_on_lid_close: bool = False,
) -> subprocess.Popen:
    """Start one owned dopa session and return the child process handle.

    The child is detached (its own session) so terminal signals aimed at the
    monitor do not leak into it; the monitor ends it explicitly with
    :func:`terminate_session`. Its output is discarded — the monitor logs to
    its own stdout, which the LaunchAgent captures.
    """
    argv = build_argv(bin, keep_display_on, stop_on_lid_close)
    if not is_dopa_available(argv[0]):
        raise DopaError(f"dopa binary not found or not executable: {argv[0]}")
    try:
        return subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        raise DopaError(f"could not start dopa ({' '.join(argv)}): {exc}") from exc


def is_pid_alive(pid: Optional[int]) -> bool:
    """Return True if ``pid`` names a live process (ours or anyone's).

    A zombie child of this process is reaped and reported as dead: without
    this, a ``dopa`` child we just terminated would still answer ``kill 0``
    until reaped, and the monitor would believe its own session is running
    forever.
    """
    if pid is None:
        return False
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        done, _status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            return False  # zombie child, just reaped
    except ChildProcessError:
        pass  # not our child (or already reaped); fall through to kill check
    except OSError:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, but not ours to signal
    except OSError:
        return False
    return True


def terminate_session(pid: Optional[int], timeout: float = _TERMINATE_TIMEOUT_SECONDS) -> bool:
    """End the owned dopa session ``pid``; return True when it is gone.

    Already-dead PIDs count as success. SIGTERM first (dopa shuts its session
    down gracefully), SIGKILL fallback after ``timeout``. Never raises for a
    missing process; raises DopaError only when signalling is refused.
    """
    if pid is None:
        return True
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return True
    if pid <= 0:
        return True
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    except PermissionError as exc:
        raise DopaError(f"cannot signal dopa session (pid {pid}): {exc}") from exc
    except OSError as exc:
        raise DopaError(f"cannot signal dopa session (pid {pid}): {exc}") from exc
    deadline = time.monotonic() + max(0.5, timeout)
    while time.monotonic() < deadline:
        if not is_pid_alive(pid):
            return True
        time.sleep(0.2)
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    time.sleep(0.3)
    return not is_pid_alive(pid)


def daemon_status(bin: Optional[str] = None) -> Optional[dict]:
    """Best-effort ``dopa-daemon status --json``; None when unavailable.

    Never creates a session, never escalates: the daemon answers on its public
    socket without sudo. Any failure (daemon not installed, not running,
    unparseable output) returns None so callers can show "unknown".
    """
    resolved = bin_path(bin)
    daemon = str(Path(resolved).parent / "dopa-daemon")
    if not (Path(daemon).is_file() and os.access(daemon, os.X_OK)):
        return None
    try:
        proc = subprocess.run(
            [daemon, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads((proc.stdout or "").strip())
    except ValueError:
        return None
    return data if isinstance(data, dict) else None
