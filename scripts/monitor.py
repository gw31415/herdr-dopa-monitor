#!/usr/bin/env python3
"""herdr dopa sleep-guard monitor.

Observes herdr agent status and holds one owned ``dopa`` child process while
at least one agent is ``working``. Uses hysteresis (start/stop grace periods)
so status flicker does not rapidly restart dopa. The owned session is exactly
the child process: ending it ends only our session — the user's manual dopa
sessions, Dopa.app, and other tools are never touched.

This process is launched by a session-scoped user LaunchAgent while that herdr
session has agents. All human control — arm/disarm, settings, status — happens
through the CLI (``scripts/guard.py``), which writes ``config.json``; this
daemon re-reads it every poll. When ``armed=false`` the daemon holds no dopa
process. SIGHUP forces an immediate config reload.

Modes:
  python3 monitor.py             # daemon loop (used by the LaunchAgent)
  python3 monitor.py --daemon    # same, explicit
  python3 monitor.py --status    # print observed agents + state, change nothing
  python3 monitor.py --once      # one iteration, then exit (manual testing)

Stdlib-only so it runs under /usr/bin/python3 from a LaunchAgent.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
import dopa_ctl  # noqa: E402
import launchagent  # noqa: E402

# Valid monitor states. Hysteresis lives in the pending_* states.
STATES = ("off", "pending_on", "on", "pending_off", "error")

# Built-in defaults; runtime values come from config.json (see config.py). These
# constants remain as fall-backs and for tests that construct Config directly.
DEFAULT_POLL_SECONDS = 5.0
DEFAULT_START_GRACE_SECONDS = 5.0
DEFAULT_STOP_GRACE_SECONDS = 30.0


class HerdrError(RuntimeError):
    """Raised when herdr cannot be queried."""


# --------------------------------------------------------------------------- #
# Pure helpers (no I/O) - the unit-tested core of the state machine.
# --------------------------------------------------------------------------- #
def any_agent_working(agent_statuses: list) -> bool:
    """Return True if any status is exactly 'working'."""
    return any(s == "working" for s in agent_statuses)


def next_monitor_state(
    current_state: str,
    observed_working: bool,
    elapsed_seconds: float,
    start_grace: float,
    stop_grace: float,
) -> str:
    """Return the next monitor state given an observation and elapsed time.

    elapsed_seconds is the time spent in current_state (the daemon resets it to
    zero on every transition). Transitions:

      off        --working-->                 pending_on
      pending_on --not working-->             off            (flicker cancelled)
      pending_on --working, grace elapsed-->  on
      on         --not working-->             pending_off
      pending_off --working-->                on             (resume, keep session)
      pending_off --not working, grace-->     off
      error      --(reconciled by daemon)-->  off / on
    """
    cs = current_state
    if cs == "off":
        return "pending_on" if observed_working else "off"
    if cs == "pending_on":
        if not observed_working:
            return "off"
        return "on" if elapsed_seconds >= start_grace else "pending_on"
    if cs == "on":
        return "on" if observed_working else "pending_off"
    if cs == "pending_off":
        if observed_working:
            return "on"
        return "off" if elapsed_seconds >= stop_grace else "pending_off"
    if cs == "error":
        # The daemon reconciles out of error using child liveness before
        # re-entering normal flow; this fallback keeps the function total.
        return "pending_on" if observed_working else "off"
    return "off"


def handle_transition(
    old: str,
    new: str,
    dopa_pid: Optional[int],
    spawn_fn: Callable[[], subprocess.Popen],
    terminate_fn: Callable[[Optional[int]], bool],
    is_alive_fn: Callable[[Optional[int]], bool],
    log_fn: Callable[[str], None],
):
    """Perform dopa side effects for a state transition.

    Returns (dopa_pid, ok). ok is False when dopa could not be started; the
    caller should then enter the error state. Side effects:

    * entering 'on'   -> ensure the owned dopa child is running (adopt a live
      PID, otherwise spawn; a spawn failure is an error);
    * entering 'off'  -> terminate the owned child if it is still alive;
    * pending transitions touch nothing.

    Only the PID recorded in our own state file is ever signalled.
    """
    if new == "on":
        if dopa_pid is not None and is_alive_fn(dopa_pid):
            if old == "pending_off":
                log_fn(f"Work resumed; keeping owned dopa session (pid {dopa_pid}).")
            else:
                log_fn(f"Adopted live dopa session (pid {dopa_pid}).")
            return dopa_pid, True
        if dopa_pid is not None:
            log_fn(f"Stale dopa pid {dopa_pid} is gone; starting a fresh session.")
        try:
            proc = spawn_fn()
        except Exception as exc:
            log_fn(f"dopa start failed: {exc}")
            return None, False
        log_fn(f"Started owned dopa session (pid {proc.pid}).")
        return proc.pid, True

    if new == "off":
        if dopa_pid is not None and is_alive_fn(dopa_pid):
            try:
                gone = terminate_fn(dopa_pid)
            except Exception as exc:
                log_fn(f"dopa stop failed (pid {dopa_pid}): {exc}")
                return dopa_pid, False
            if gone:
                log_fn(f"Agents idle; ended owned dopa session (pid {dopa_pid}).")
            else:
                log_fn(f"dopa session (pid {dopa_pid}) did not exit; will retry.")
                return dopa_pid, False
        elif old == "pending_off" and dopa_pid is not None:
            log_fn("Agents idle; owned dopa session already gone.")
        else:
            log_fn("Agents idle; nothing to stop.")
        return None, True

    # off->pending_on and on->pending_off: no dopa action.
    return dopa_pid, True


# --------------------------------------------------------------------------- #
# State persistence
# --------------------------------------------------------------------------- #
def default_state() -> dict:
    return {
        "monitor_state": "off",
        "dopa_pid": None,
        "last_agent_working": False,
        "agent_count": -1,
        "last_transition_unix": 0,
        "last_error": None,
    }


def load_state(path: Path) -> dict:
    """Load monitor state, returning defaults if missing or corrupt."""
    state = default_state()
    try:
        if path.exists():
            data = json.loads(path.read_text())
            if isinstance(data, dict):
                state.update(data)
    except (OSError, ValueError):
        # Corrupt or unreadable state: start fresh rather than crash.
        pass
    return state


def save_state(path: Path, state: dict) -> None:
    """Atomically write monitor state (write temp file then rename)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(tmp, path)


@dataclass
class MonitorCtx:
    monitor_state: str = "off"
    dopa_pid: Optional[int] = None
    last_transition: float = 0.0
    last_agent_working: bool = False
    agent_count: int = -1
    last_error: Optional[str] = None
    backoff: float = DEFAULT_POLL_SECONDS


def load_ctx(path: Path) -> MonitorCtx:
    s = load_state(path)
    try:
        last_t = float(s.get("last_transition_unix") or 0)
    except (TypeError, ValueError):
        last_t = 0.0
    try:
        agent_count = int(s.get("agent_count", -1))
    except (TypeError, ValueError):
        agent_count = -1
    try:
        dopa_pid = s.get("dopa_pid")
        dopa_pid = int(dopa_pid) if dopa_pid is not None else None
    except (TypeError, ValueError):
        dopa_pid = None
    return MonitorCtx(
        monitor_state=s.get("monitor_state", "off"),
        dopa_pid=dopa_pid,
        last_transition=last_t,
        last_agent_working=bool(s.get("last_agent_working", False)),
        agent_count=agent_count,
        last_error=s.get("last_error"),
    )


def save_ctx(path: Path, ctx: MonitorCtx) -> None:
    save_state(
        path,
        {
            "monitor_state": ctx.monitor_state,
            "dopa_pid": ctx.dopa_pid,
            "last_agent_working": ctx.last_agent_working,
            "agent_count": ctx.agent_count,
            "last_transition_unix": ctx.last_transition,
            "last_error": ctx.last_error,
        },
    )


# --------------------------------------------------------------------------- #
# herdr observation
# --------------------------------------------------------------------------- #
def _agent_statuses_from_response(data: dict) -> list:
    agents = (data.get("result") or {}).get("agents") or []
    return [a.get("agent_status", "unknown") for a in agents]


def _get_agent_statuses_from_socket(socket_path: str) -> list:
    req = {"id": "herdr-dopa:agent:list", "method": "agent.list", "params": {}}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(socket_path)
            sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
            chunks = []
            while True:
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    if chunks:
                        break
                    raise
                if not chunk:
                    break
                chunks.append(chunk)
                if b"\n" in chunk:
                    break
    except OSError as exc:
        raise HerdrError(f"herdr socket unavailable at {socket_path!r}: {exc}") from exc
    try:
        data = json.loads(b"".join(chunks).decode("utf-8").strip())
    except ValueError as exc:
        raise HerdrError(f"could not parse herdr socket response as JSON: {exc}") from exc
    if "error" in data:
        err = data.get("error") or {}
        raise HerdrError(f"herdr socket error: {err.get('message') or err}")
    return _agent_statuses_from_response(data)


def get_agent_statuses(herdr_bin: str) -> list:
    """Read herdr agent statuses from the session socket.

    The LaunchAgent pins HERDR_SOCKET_PATH. If that env is absent this process
    is outside a herdr session and must not probe user-facing CLI paths that
    may trigger terminal notifications. Raises HerdrError if herdr cannot be
    reached or its output cannot be parsed.
    """
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    if not socket_path:
        raise HerdrError("HERDR_SOCKET_PATH is not set; not running from a herdr session")
    return _get_agent_statuses_from_socket(socket_path)


# --------------------------------------------------------------------------- #
# Config (built from config.json + env overrides)
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    herdr_bin: str
    poll_seconds: float
    start_grace: float
    stop_grace: float
    state_path: Path
    dopa_bin: str = dopa_ctl.DEFAULT_DOPA_BIN
    keep_display_on: bool = False
    stop_on_lid_close: bool = False
    armed: bool = True


def resolve_state_path() -> Path:
    """The runtime state file: <state_dir>/state.json."""
    return config.state_dir() / "state.json"


def load_config() -> Config:
    """Build the runtime Config from config.json (file -> env -> validate)."""
    raw = config.load_resolved()
    herdr_bin = raw["herdr_bin_path"] or shutil.which("herdr") or "herdr"
    return Config(
        herdr_bin=herdr_bin,
        poll_seconds=raw["poll_seconds"],
        start_grace=raw["start_grace_seconds"],
        stop_grace=raw["stop_grace_seconds"],
        state_path=resolve_state_path(),
        dopa_bin=raw["dopa_bin"],
        keep_display_on=raw["keep_display_on"],
        stop_on_lid_close=raw["stop_on_lid_close"],
        armed=raw["armed"],
    )


# --------------------------------------------------------------------------- #
# Logging (stdout -> LaunchAgent log file)
# --------------------------------------------------------------------------- #
def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{stamp} {message}", flush=True)


def _auto_stop_if_empty(ctx: MonitorCtx) -> bool:
    """Stop only this session's LaunchAgent when no agents remain."""
    if os.environ.get("HERDR_DOPA_AUTO_UNLOAD") != "1" or ctx.agent_count != 0:
        return False
    label_name = os.environ.get("HERDR_DOPA_LABEL")
    if not label_name:
        return False
    log("No agents remain; stopping this session LaunchAgent.")
    launchagent.stop(label_name)
    return True


# --------------------------------------------------------------------------- #
# One iteration of the monitor (pure with respect to injected time)
# --------------------------------------------------------------------------- #
def iterate(cfg: Config, ctx: MonitorCtx, now: float) -> MonitorCtx:
    """Run one monitor iteration and return the updated context.

    `now` is injected so this is unit-testable; the daemon passes time.time().
    """
    state = ctx.monitor_state
    pid = ctx.dopa_pid
    last_t = ctx.last_transition if ctx.last_transition else now
    backoff = cfg.poll_seconds
    last_error: Optional[str] = None

    def _spawn():
        return dopa_ctl.spawn_session(
            cfg.dopa_bin, cfg.keep_display_on, cfg.stop_on_lid_close
        )

    # Master switch: when disarmed, hold no dopa process.
    if not cfg.armed:
        if pid is not None and dopa_ctl.is_pid_alive(pid):
            try:
                dopa_ctl.terminate_session(pid)
                log(f"Disarmed; ended owned dopa session (pid {pid}).")
            except dopa_ctl.DopaError as exc:
                log(f"Disarmed; could not end dopa session (pid {pid}): {exc}")
        return MonitorCtx(
            monitor_state="off",
            dopa_pid=None,
            last_transition=now,
            last_agent_working=ctx.last_agent_working,
            agent_count=ctx.agent_count,
            last_error=last_error,
            backoff=cfg.poll_seconds,
        )

    if not dopa_ctl.is_dopa_available(cfg.dopa_bin):
        last_error = f"dopa binary not found at {cfg.dopa_bin}"
        log(last_error + "; waiting.")
        return MonitorCtx(
            monitor_state="error",
            dopa_pid=pid,
            last_transition=last_t,
            last_agent_working=ctx.last_agent_working,
            agent_count=ctx.agent_count,
            last_error=last_error,
            backoff=min(60.0, ctx.backoff * 2),
        )

    # Recover from error: drop a stale PID, then resume normal flow.
    if state == "error":
        if pid is not None and not dopa_ctl.is_pid_alive(pid):
            log(f"Owned dopa session (pid {pid}) is gone; cleared.")
            pid = None
        state = "on" if pid is not None else "off"
        last_t = now
        backoff = cfg.poll_seconds
        log(f"Recovered from error; resuming in state '{state}'.")

    # Observe herdr. herdr being down is NOT an error state - treat as idle.
    try:
        statuses = get_agent_statuses(cfg.herdr_bin)
        agent_count = len(statuses)
    except HerdrError as exc:
        log(f"herdr unavailable ({exc}); treating as no working agents.")
        statuses = []
        agent_count = ctx.agent_count
    working = any_agent_working(statuses)

    new_state = next_monitor_state(
        state, working, now - last_t, cfg.start_grace, cfg.stop_grace
    )

    if new_state != state:
        pid, ok = handle_transition(
            state,
            new_state,
            pid,
            _spawn,
            dopa_ctl.terminate_session,
            dopa_ctl.is_pid_alive,
            log,
        )
        if ok:
            log(f"Transition: {state} -> {new_state} (working={working}).")
            state = new_state
            last_t = now
        else:
            log(f"Transition {state} -> {new_state} failed; entering error state.")
            state = "error"
            last_t = now
            last_error = "dopa control failure"
    elif state == "on":
        # Reconcile the on-state with reality: our child may have exited on
        # its own (e.g. --stop-on-lid-close ended it when the lid closed).
        if pid is None or not dopa_ctl.is_pid_alive(pid):
            log("Owned dopa session is gone while agents work; restarting it.")
            try:
                pid = _spawn().pid
                log(f"Restarted owned dopa session (pid {pid}).")
                last_t = now
            except dopa_ctl.DopaError as exc:
                log(f"Restart failed: {exc}; entering error state.")
                state = "error"
                last_t = now
                last_error = "dopa restart failure"
                pid = None

    return MonitorCtx(
        monitor_state=state,
        dopa_pid=pid,
        last_transition=last_t,
        last_agent_working=working,
        agent_count=agent_count,
        last_error=last_error,
        backoff=backoff,
    )


# --------------------------------------------------------------------------- #
# Modes
# --------------------------------------------------------------------------- #
def print_status(cfg: Config) -> None:
    """Print observed agents + dopa state + persisted monitor state."""
    print(f"herdr bin:       {cfg.herdr_bin}")
    print(f"state file:      {cfg.state_path}")
    print(f"config file:     {config.config_path()}")
    print(f"armed:           {cfg.armed}")
    print(f"poll/grace:      {cfg.poll_seconds}s / start {cfg.start_grace}s / stop {cfg.stop_grace}s")
    flags = []
    if cfg.keep_display_on:
        flags.append("--keep-display-on")
    if cfg.stop_on_lid_close:
        flags.append("--stop-on-lid-close")
    print(f"dopa flags:      {' '.join(flags) or '(none)'}")
    print(f"dopa bin:        {cfg.dopa_bin} "
          f"({'present' if dopa_ctl.is_dopa_available(cfg.dopa_bin) else 'MISSING'})")
    try:
        statuses = get_agent_statuses(cfg.herdr_bin)
        working = sum(1 for s in statuses if s == "working")
        print(f"herdr agents:    {len(statuses)} observed, {working} working")
        for s in statuses:
            print(f"    - {s}")
    except HerdrError as exc:
        print(f"herdr agents:    unavailable ({exc})")
    st = dopa_ctl.daemon_status(cfg.dopa_bin)
    if st is None:
        print("dopa daemon:     unknown (dopa-daemon status unreachable)")
    else:
        sessions = st.get("sessions", "?")
        print(f"dopa daemon:     phase={st.get('phase', '?')} sessions={sessions}")
    print("monitor state:")
    print(json.dumps(load_state(cfg.state_path), indent=2))


def run_once(cfg: Config) -> None:
    """Run a single iteration and exit. Does not end the session on exit."""
    ctx = load_ctx(cfg.state_path)
    ctx.backoff = cfg.poll_seconds
    ctx = iterate(cfg, ctx, time.time())
    save_ctx(cfg.state_path, ctx)
    print(json.dumps({
        "monitor_state": ctx.monitor_state,
        "dopa_pid": ctx.dopa_pid,
        "last_agent_working": ctx.last_agent_working,
        "last_error": ctx.last_error,
    }, indent=2))


def run_daemon(initial_cfg: Config) -> None:
    """Run the monitor loop until SIGTERM/SIGINT.

    Reloads config.json every cycle (so CLI edits take effect) and on SIGHUP
    (immediate). The session LaunchAgent is stopped when no agents remain.
    On shutdown the owned dopa child is terminated: it is our session, and
    leaving it behind would hold the Mac awake with no owner.
    """
    cfg = initial_cfg
    ctx = load_ctx(cfg.state_path)
    ctx.backoff = cfg.poll_seconds

    # Startup safety: adopt the recorded PID only if it is actually alive;
    # otherwise drop it so the next `on` cycle spawns fresh.
    if ctx.dopa_pid is not None and not dopa_ctl.is_pid_alive(ctx.dopa_pid):
        log(f"Recorded dopa pid {ctx.dopa_pid} is not alive; cleared.")
        ctx.dopa_pid = None

    stop = threading.Event()
    reload_now = threading.Event()

    def _stop_handler(signum, _frame):
        log(f"Received signal {signum}; stopping after current iteration.")
        stop.set()

    def _reload_handler(_signum, _frame):
        reload_now.set()

    signal.signal(signal.SIGTERM, _stop_handler)
    signal.signal(signal.SIGINT, _stop_handler)
    try:
        signal.signal(signal.SIGHUP, _reload_handler)
    except (AttributeError, ValueError, OSError):
        pass  # SIGHUP unavailable in this environment; polling still reloads.

    log(f"Monitor started (poll={cfg.poll_seconds}s start_grace={cfg.start_grace}s "
        f"stop_grace={cfg.stop_grace}s armed={cfg.armed} "
        f"state={cfg.state_path}).")
    try:
        while not stop.is_set():
            if reload_now.is_set():
                reload_now.clear()
                try:
                    cfg = load_config()
                    log("Config reloaded.")
                except Exception as exc:  # never let a reload kill the daemon
                    log(f"Config reload failed ({exc}); keeping previous config.")
            ctx = iterate(cfg, ctx, time.time())
            save_ctx(cfg.state_path, ctx)
            if _auto_stop_if_empty(ctx):
                return
            delay = ctx.backoff if ctx.monitor_state == "error" else cfg.poll_seconds
            stop.wait(max(1.0, delay))
    finally:
        if ctx.dopa_pid is not None:
            try:
                if dopa_ctl.terminate_session(ctx.dopa_pid):
                    log(f"Ended owned dopa session (pid {ctx.dopa_pid}) on shutdown.")
                else:
                    log(f"Owned dopa session (pid {ctx.dopa_pid}) would not exit.")
            except dopa_ctl.DopaError as exc:
                log(f"Could not end owned dopa session on shutdown: {exc}")
            ctx.dopa_pid = None
        # We are stopping, so we are no longer guarding: reflect that in state
        # so the CLI / --status do not show a stale "on".
        ctx.monitor_state = "off"
        ctx.last_error = None
        save_ctx(cfg.state_path, ctx)
        log("Monitor stopped.")


def main(argv=None) -> int:
    if ("HERDR_DOPA_CONFIG_DIR" not in os.environ
            or "HERDR_DOPA_STATE_DIR" not in os.environ):
        p = launchagent.paths()
        os.environ.setdefault("HERDR_DOPA_CONFIG_DIR", str(p["config_dir"]))
        os.environ.setdefault("HERDR_DOPA_STATE_DIR", str(p["state_dir"]))
    parser = argparse.ArgumentParser(
        description="dopa sleep-guard daemon for herdr."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true",
                      help="Print observed agents and monitor state; change nothing.")
    mode.add_argument("--once", action="store_true",
                      help="Run a single iteration and exit (manual testing).")
    mode.add_argument("--daemon", action="store_true",
                      help="Run the monitor loop forever (used by the LaunchAgent).")
    args = parser.parse_args(argv)

    cfg = load_config()
    if args.status:
        print_status(cfg)
    elif args.once:
        run_once(cfg)
    else:
        run_daemon(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
