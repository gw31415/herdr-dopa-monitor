#!/usr/bin/env python3
"""Modern control surface for the dopa sleep guard (replaces the old curses TUI).

A single command with subcommands instead of a fullscreen interactive UI: it
works in any terminal, inside herdr panes, over pipes, and from scripts.

  guard.py status [--json]     show guard / agents / dopa state
  guard.py on | off            arm / disarm the guard (applies within one poll)
  guard.py get [KEY]           show config (all keys, or one)
  guard.py set KEY VALUE       change config (validated, applied within one poll)
  guard.py install             install/refresh this session's LaunchAgent
  guard.py sync                match the LaunchAgent to the live agent count
  guard.py uninstall [--cleanup]  remove the LaunchAgent (and optionally data)
  guard.py once | daemon       run one monitor iteration / the daemon loop
  guard.py logs [-n LINES]     tail the daemon log

Config edits send SIGHUP to the running daemon best-effort (via
``launchctl kill``); the daemon also re-reads config.json every poll, so a
missed signal only delays the change by one cycle.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config  # noqa: E402
import dopa_ctl  # noqa: E402
import launchagent  # noqa: E402
import monitor  # noqa: E402


def plugin_root() -> Path:
    return Path(__file__).resolve().parent.parent


def template_path() -> Path:
    return plugin_root() / "launchagents" / "com.herdr.dopa.monitor.plist.template"


def ensure_session_env() -> dict:
    """Pin per-session config/state dirs; return launchagent.paths()."""
    p = launchagent.paths()
    os.environ.setdefault("HERDR_DOPA_CONFIG_DIR", str(p["config_dir"]))
    os.environ.setdefault("HERDR_DOPA_STATE_DIR", str(p["state_dir"]))
    return p


# --------------------------------------------------------------------------- #
# Output styling (ANSI only when it helps: TTY, not NO_COLOR, not piped)
# --------------------------------------------------------------------------- #
def _styled() -> bool:
    return (
        sys.stdout.isatty()
        and os.environ.get("NO_COLOR") is None
        and os.environ.get("TERM", "") != "dumb"
    )


class Style:
    def __init__(self, on: bool):
        self.on = on

    def wrap(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.on else text

    def bold(self, text: str) -> str:
        return self.wrap("1", text)

    def dim(self, text: str) -> str:
        return self.wrap("2", text)

    def green(self, text: str) -> str:
        return self.wrap("32", text)

    def yellow(self, text: str) -> str:
        return self.wrap("33", text)

    def red(self, text: str) -> str:
        return self.wrap("31", text)

    def cyan(self, text: str) -> str:
        return self.wrap("36", text)


STATE_DOT = {"on": "●", "pending_on": "◐", "pending_off": "◐", "off": "○", "error": "✖"}


def state_color(st: Style, state: str) -> str:
    dot = STATE_DOT.get(state, "?")
    if state == "on":
        return st.green(dot)
    if state in ("pending_on", "pending_off"):
        return st.yellow(dot)
    if state == "error":
        return st.red(dot)
    return st.dim(dot)


# --------------------------------------------------------------------------- #
# status
# --------------------------------------------------------------------------- #
def collect_status() -> dict:
    """Gather everything the dashboard needs. Read-only; never spawns dopa."""
    cfg = monitor.load_config()
    try:
        statuses = monitor.get_agent_statuses(cfg.herdr_bin)
        agents: dict = {
            "available": True,
            "total": len(statuses),
            "working": sum(1 for s in statuses if s == "working"),
            "statuses": statuses,
            "error": None,
        }
    except monitor.HerdrError as exc:
        agents = {"available": False, "total": 0, "working": 0, "statuses": [], "error": str(exc)}
    persisted = monitor.load_state(cfg.state_path)
    dopa_pid = persisted.get("dopa_pid")
    owned_alive = dopa_ctl.is_pid_alive(dopa_pid)
    daemon = dopa_ctl.daemon_status(cfg.dopa_bin)
    flags = []
    if cfg.keep_display_on:
        flags.append("--keep-display-on")
    if cfg.stop_on_lid_close:
        flags.append("--stop-on-lid-close")
    return {
        "armed": cfg.armed,
        "monitor_state": persisted.get("monitor_state", "off"),
        "dopa_pid": dopa_pid,
        "owned_session_alive": owned_alive,
        "dopa_flags": flags,
        "dopa_bin": cfg.dopa_bin,
        "dopa_present": dopa_ctl.is_dopa_available(cfg.dopa_bin),
        "daemon": daemon,
        "agents": agents,
        "config": {
            "poll_seconds": cfg.poll_seconds,
            "start_grace_seconds": cfg.start_grace,
            "stop_grace_seconds": cfg.stop_grace,
            "keep_display_on": cfg.keep_display_on,
            "stop_on_lid_close": cfg.stop_on_lid_close,
            "dopa_bin": cfg.dopa_bin,
            "herdr_bin": cfg.herdr_bin,
        },
        "config_file": str(config.config_path()),
        "state_file": str(cfg.state_path),
        "last_error": persisted.get("last_error"),
    }


def cmd_status(args) -> int:
    ensure_session_env()
    data = collect_status()
    if args.json:
        print(json.dumps(data, indent=2))
        return 0
    st = Style(_styled())
    ms = data["monitor_state"]
    head = f"{state_color(st, ms)} dopa guard — "
    if not data["armed"]:
        head += st.dim("paused (off)") + st.dim("  ·  `guard.py on` to resume")
    elif ms == "on":
        head += st.bold(st.green("guarding")) + st.dim(f"  ·  {data['agents']['working']} working")
    elif ms in ("pending_on", "pending_off"):
        head += st.bold(st.yellow("settling")) + st.dim(f"  ·  state {ms}")
    elif ms == "error":
        head += st.bold(st.red("error")) + st.dim(f"  ·  {data['last_error'] or 'see logs'}")
    else:
        head += st.dim("idle")
    print(head)
    ag = data["agents"]
    if ag["available"]:
        print(f"  agents        {ag['total']} observed · {ag['working']} working")
    else:
        print(f"  agents        {st.dim('unavailable')} ({ag['error']})")
    if data["owned_session_alive"]:
        flag_str = " " + " ".join(data["dopa_flags"]) if data["dopa_flags"] else ""
        print(f"  dopa session  {st.green('active')} · pid {data['dopa_pid']}{flag_str}")
    elif data["dopa_pid"] is not None:
        print(f"  dopa session  {st.yellow('stale pid')} {data['dopa_pid']} (process gone)")
    else:
        print(f"  dopa session  {st.dim('none')}")
    if not data["dopa_present"]:
        print(f"  dopa binary   {st.red('MISSING')}: {data['dopa_bin']}")
    daemon = data["daemon"]
    if daemon is None:
        print(f"  dopa daemon   {st.dim('unknown')} (dopa-daemon status unreachable)")
    else:
        sessions = daemon.get("sessions", "?")
        print(f"  dopa daemon   phase={daemon.get('phase', '?')} · sessions={sessions}")
    print(f"  config        {st.cyan(data['config_file'])}")
    for key, val in data["config"].items():
        if key in ("dopa_bin", "herdr_bin"):
            continue
        print(f"    {key:<20} {val}")
    print(f"    {'dopa_bin':<20} {data['config']['dopa_bin']}")
    print(f"    {'herdr_bin':<20} {data['config']['herdr_bin']}")
    _print_log_tail(st)
    return 0


def _print_log_tail(st: Style, lines: int = 5) -> None:
    p = ensure_session_env()
    log = Path(p["log_dir"]) / "monitor.out.log"
    if not log.exists():
        return
    try:
        tail = log.read_text().strip().splitlines()[-lines:]
    except OSError:
        return
    if not tail:
        return
    print(st.dim("  recent log:"))
    for line in tail:
        print(st.dim(f"    {line}"))


# --------------------------------------------------------------------------- #
# on / off / get / set
# --------------------------------------------------------------------------- #
def _nudge_daemon(label_name: str) -> None:
    """Best-effort SIGHUP so a config edit applies immediately."""
    launchagent.run(["launchctl", "kill", "HUP", launchagent.service_target(label_name)])


def cmd_on(args) -> int:
    p = ensure_session_env()
    cfg = config.load_config_file()
    cfg["armed"] = True
    config.save_config_file(cfg)
    _nudge_daemon(p["label"])
    print("Guard armed. Takes effect within one poll "
          f"({config.load_resolved()['poll_seconds']:g}s).")
    return 0


def cmd_off(args) -> int:
    p = ensure_session_env()
    cfg = config.load_config_file()
    cfg["armed"] = False
    config.save_config_file(cfg)
    _nudge_daemon(p["label"])
    print("Guard paused. The owned dopa session (if any) ends within one poll; "
          "nothing else is touched.")
    return 0


def cmd_get(args) -> int:
    ensure_session_env()
    cfg = config.load_resolved()
    if args.key:
        if args.key not in config.DEFAULT_CONFIG:
            print(f"Unknown key: {args.key}. Valid: {', '.join(config.SET_KEYS)}",
                  file=sys.stderr)
            return 2
        print(_format_value(cfg[args.key]))
        return 0
    st = Style(_styled())
    for key in config.SET_KEYS:
        # Pad by the raw key length: ANSI codes must not count toward width.
        print(f"{st.cyan(key)}{' ' * (22 - len(key))}{_format_value(cfg[key])}")
    print(st.dim(f"# from {config.config_path()}"))
    return 0


def _format_value(val) -> str:
    if isinstance(val, bool):
        return "true" if val else "false"
    if isinstance(val, float) and val.is_integer():
        return str(int(val))
    return str(val)


def _parse_value(key: str, raw: str):
    if key in ("armed", "keep_display_on", "stop_on_lid_close"):
        low = raw.strip().lower()
        if low in ("1", "true", "yes", "y", "on"):
            return True
        if low in ("0", "false", "no", "n", "off"):
            return False
        raise ValueError(f"{key} wants true/false, got {raw!r}")
    if key in ("poll_seconds", "start_grace_seconds", "stop_grace_seconds"):
        try:
            return float(raw)
        except ValueError:
            raise ValueError(f"{key} wants a number of seconds, got {raw!r}")
    return raw  # dopa_bin, herdr_bin_path: free-form paths


def cmd_set(args) -> int:
    p = ensure_session_env()
    if args.key not in config.DEFAULT_CONFIG:
        print(f"Unknown key: {args.key}. Valid: {', '.join(config.SET_KEYS)}",
              file=sys.stderr)
        return 2
    try:
        value = _parse_value(args.key, args.value)
    except ValueError as exc:
        print(f"Invalid value: {exc}", file=sys.stderr)
        return 2
    cfg = config.load_config_file()
    cfg[args.key] = value
    try:
        config.save_config_file(cfg)
    except Exception as exc:  # validated data should always save; be loud if not
        print(f"Could not save config: {exc}", file=sys.stderr)
        return 1
    saved = config.load_resolved()[args.key]
    _nudge_daemon(p["label"])
    print(f"{args.key} = {_format_value(saved)} (takes effect within one poll)")
    if args.key == "dopa_bin" and not dopa_ctl.is_dopa_available(str(saved)):
        print(f"Warning: {saved} is not an executable file.", file=sys.stderr)
    return 0


# --------------------------------------------------------------------------- #
# install / sync / uninstall
# --------------------------------------------------------------------------- #
def resolve_herdr_bin() -> str:
    """Absolute herdr path to bake into the LaunchAgent (minimal PATH there)."""
    herdr = os.environ.get("HERDR_BIN_PATH") or shutil.which("herdr")
    if not herdr:
        sys.exit(
            "Could not find herdr on PATH. Run `guard.py install` from a shell "
            "that has herdr, or set HERDR_BIN_PATH to the absolute binary."
        )
    return str(Path(herdr).resolve())


def render_plist(home_dir: Path, p: dict) -> str:
    python = os.environ.get("HERDR_DOPA_PYTHON", "/usr/bin/python3")
    socket_path = os.environ.get("HERDR_SOCKET_PATH", "")
    return (
        template_path().read_text()
        .replace("__LABEL__", p["label"])
        .replace("__PYTHON__", python)
        .replace("__PLUGIN_ROOT__", str(plugin_root()))
        .replace("__HOME__", str(home_dir))
        .replace("__CONFIG_DIR__", str(p["config_dir"]))
        .replace("__STATE_DIR__", str(p["state_dir"]))
        .replace("__LOG_DIR__", str(p["log_dir"]))
        .replace("__PLIST__", str(p["plist"]))
        .replace("__HERDR_BIN__", resolve_herdr_bin())
        .replace("__HERDR_SOCKET__", socket_path)
    )


def do_install() -> dict:
    home_dir = Path.home()
    p = launchagent.paths(home_dir)
    for d in ("log_dir", "config_dir", "state_dir"):
        Path(p[d]).mkdir(parents=True, exist_ok=True)
    (home_dir / "Library" / "LaunchAgents").mkdir(parents=True, exist_ok=True)
    # Pin the resolved per-session dirs so config/state land in the right place
    # for seeding here and for any subprocess spawned below.
    os.environ["HERDR_DOPA_CONFIG_DIR"] = str(p["config_dir"])
    os.environ["HERDR_DOPA_STATE_DIR"] = str(p["state_dir"])

    # Seed config.json with defaults if absent. Never overwrite (user edits).
    if not config.config_path().exists():
        config.save_config_file(config.default_config())
        print(f"[install] wrote default config: {config.config_path()}")

    Path(p["plist"]).write_text(render_plist(home_dir, p))
    print(f"[install] wrote plist: {p['plist']}")

    launchagent.run(["launchctl", "bootout", launchagent.domain(), str(p["plist"])])
    # A previous stop stores a persistent disabled override for this label.
    # Bootstrap of a disabled agent can fail with a generic I/O error, so
    # enable first; stop() below leaves the documented stopped state.
    launchagent.run(["launchctl", "enable", launchagent.service_target(p["label"])])
    code, err = launchagent.run(
        ["launchctl", "bootstrap", launchagent.domain(), str(p["plist"])])
    if code != 0 and err:
        print(f"[install] bootstrap note (ignored if already loaded): {err}",
              file=sys.stderr)

    launchagent.stop(p["label"])
    print(f"[install] registered LaunchAgent: {p['label']} (stopped)")
    print(f"[install] stdout log: {p['log_dir']}/monitor.out.log")
    print(f"[install] stderr log: {p['log_dir']}/monitor.err.log")
    print(f"[install] config file: {p['config_dir']}/config.json")
    print(f"[install] state file: {p['state_dir']}/state.json")
    print("[install] verify with:")
    print(f"    launchctl print gui/$UID/{p['label']}")
    print(f"    tail -n 50 {p['log_dir']}/monitor.out.log")
    print("    python3 scripts/guard.py status")
    return p


def cmd_install(args) -> int:
    ensure_session_env()
    do_install()
    return 0


def cmd_sync(args) -> int:
    p = ensure_session_env()
    cfg = monitor.load_config()
    try:
        count = len(monitor.get_agent_statuses(cfg.herdr_bin))
    except monitor.HerdrError as exc:
        print(f"[sync] herdr unavailable; leaving LaunchAgent unchanged: {exc}")
        return 0
    if count:
        print(f"[sync] {count} agents; ensuring LaunchAgent is installed and started.")
        do_install()
        # do_install deliberately leaves the service stopped; re-enable before
        # bootstrap to recover from a persisted disabled override.
        launchagent.run(["launchctl", "enable", launchagent.service_target(p["label"])])
        launchagent.run(["launchctl", "bootstrap", launchagent.domain(), str(p["plist"])])
        launchagent.start(p["label"])
        return 0
    print("[sync] no agents; stopping LaunchAgent but keeping it installed.")
    launchagent.stop(p["label"])
    return 0


def cmd_uninstall(args) -> int:
    p = ensure_session_env()
    home_dir = Path.home()
    plist_dest = Path(p["plist"])

    proc_code, msg = launchagent.run(
        ["launchctl", "bootout", launchagent.domain(), str(plist_dest)])
    if proc_code == 0:
        print(f"[uninstall] unloaded LaunchAgent: {p['label']}")
    elif msg:
        print(f"[uninstall] bootout (ignored if not loaded): {msg}")

    if plist_dest.exists():
        plist_dest.unlink()
        print(f"[uninstall] removed plist: {plist_dest}")
    else:
        print(f"[uninstall] no plist at {plist_dest}; nothing to remove.")

    if args.cleanup:
        for key in ("log_dir", "state_dir"):
            d = Path(p[key])
            if d.exists():
                shutil.rmtree(d)
                print(f"[uninstall] removed {d}")
        cfg_file = config.config_path()
        try:
            if cfg_file.exists():
                cfg_file.unlink()
                print(f"[uninstall] removed {cfg_file}")
        except OSError as exc:
            print(f"[uninstall] could not remove {cfg_file}: {exc}")
        print("[uninstall] logs, state, and config removed.")
    else:
        print(f"[uninstall] kept logs ({p['log_dir']}), state ({p['state_dir']}), "
              "and config.")
        print("[uninstall] pass --cleanup to remove them.")
    print("[uninstall] done. Your own dopa sessions were never touched.")
    return 0


# --------------------------------------------------------------------------- #
# once / daemon / logs
# --------------------------------------------------------------------------- #
def cmd_once(args) -> int:
    ensure_session_env()
    return monitor.main(["--once"])


def cmd_daemon(args) -> int:
    ensure_session_env()
    return monitor.main(["--daemon"])


def cmd_logs(args) -> int:
    p = ensure_session_env()
    log = Path(p["log_dir"]) / "monitor.out.log"
    if not log.exists():
        print(f"No log file yet: {log}")
        return 0
    lines = log.read_text().splitlines()
    for line in lines[-max(1, args.n):]:
        print(line)
    return 0


# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="guard.py",
        description="Control the herdr dopa sleep guard (no curses, no fullscreen).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="Show guard / agents / dopa state.")
    s.add_argument("--json", action="store_true", help="Machine-readable output.")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("on", help="Arm the guard.")
    s.set_defaults(func=cmd_on)
    s = sub.add_parser("off", help="Pause the guard (ends only our dopa session).")
    s.set_defaults(func=cmd_off)

    s = sub.add_parser("get", help="Show config values.")
    s.add_argument("key", nargs="?", help="Single key to show (default: all).")
    s.set_defaults(func=cmd_get)
    s = sub.add_parser("set", help="Change a config value.")
    s.add_argument("key", help=f"One of: {', '.join(config.SET_KEYS)}")
    s.add_argument("value", help="New value (true/false, seconds, or path).")
    s.set_defaults(func=cmd_set)

    s = sub.add_parser("install", help="Install/refresh this session's LaunchAgent.")
    s.set_defaults(func=cmd_install)
    s = sub.add_parser("sync", help="Match the LaunchAgent to the live agent count.")
    s.set_defaults(func=cmd_sync)
    s = sub.add_parser("uninstall", help="Remove this session's LaunchAgent.")
    s.add_argument("--cleanup", action="store_true",
                   help="Also remove logs, state, and config.")
    s.set_defaults(func=cmd_uninstall)

    s = sub.add_parser("once", help="Run a single monitor iteration (testing).")
    s.set_defaults(func=cmd_once)
    s = sub.add_parser("daemon", help="Run the monitor loop (used by LaunchAgent).")
    s.set_defaults(func=cmd_daemon)

    s = sub.add_parser("logs", help="Tail the daemon log.")
    s.add_argument("-n", type=int, default=30, help="Lines to show (default: 30).")
    s.set_defaults(func=cmd_logs)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
