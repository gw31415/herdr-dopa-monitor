# herdr plugin: dopa macOS Sleep Guard

A macOS [herdr](https://github.com/gw31415/herdr) sleep guard that keeps the
machine awake with [dopa](https://github.com/gw31415/dopa) while agents are
working. Successor to the archived `herdr-amphetamine-macos` (Amphetamine is
gone; the old curses TUI is gone too).

It does one thing deliberately: when at least one herdr agent is `working`, it
holds one owned `dopa` process. When agents go idle, it ends that process. A
`dopa` session lives exactly as long as its process, so the guard can neither
leak wakefulness nor disturb your manual `dopa` sessions, Dopa.app, or anyone
else's sessions — it only ever signals its own child PID.

## Features

- Session-scoped per-user LaunchAgent, installed once and started/stopped with
  agent count.
- One modern CLI (`scripts/guard.py`) for status, on/off, settings,
  install/uninstall — plain text over pipes, color dashboard on a TTY,
  `--json` for scripts. No curses, no fullscreen, no mouse.
- Flicker-resistant state machine with start/stop grace periods.
- Stdlib-only Python; runs under `/usr/bin/python3` from a LaunchAgent.

## Requirements

- macOS with the `dopa-daemon` service installed
  (`sudo dopa-daemon install` from the dopa repo).
- `dopa` CLI (default: `/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa`;
  override with `guard.py set dopa_bin PATH` or `DOPA_BIN`).
- herdr on `PATH` (or `HERDR_BIN_PATH` set) for live agent observation.
- `/usr/bin/python3`.

## Install

```sh
cd herdr-dopa-macos
python3 scripts/guard.py install
python3 scripts/guard.py sync
```

The installer:

- resolves the `herdr` binary path for the LaunchAgent environment,
- infers the current herdr session (`HERDR_SESSION_NAME` / `HERDR_SESSION`, or
  the single running session),
- seeds `<config>/config.json` (per-session; never overwrites yours),
- writes `~/Library/LaunchAgents/com.herdr.dopa.monitor.<session>.plist`,
- registers the monitor (stopped; `sync` starts it when agents exist),
- writes logs under `~/Library/Logs/herdr-dopa/<session>/`.

No permission prompts: unlike the Amphetamine version there is no AppleScript
and no Automation access involved.

## Usage

```sh
python3 scripts/guard.py status          # dashboard (or --json)
python3 scripts/guard.py off             # pause (ends only our dopa session)
python3 scripts/guard.py on              # resume
python3 scripts/guard.py set poll_seconds 5
python3 scripts/guard.py set keep_display_on true    # dopa -d
python3 scripts/guard.py set stop_on_lid_close true  # dopa -l
python3 scripts/guard.py get             # all settings
python3 scripts/guard.py logs            # tail the daemon log
python3 scripts/guard.py uninstall --cleanup
```

## Behavior

The monitor observes `herdr agent list` and treats only exact `working`
statuses as active work. `sync` installs this session's LaunchAgent if needed,
starts it when agent count is nonzero, and stops it when the count is zero. A
running monitor also stops its own LaunchAgent after it observes zero agents.

```text
off --working--> pending_on --(start grace)--> on
on  --idle----> pending_off --(stop grace)---> off
```

Entering `on` starts (or adopts) the owned `dopa` child; while `on`, a child
that died on its own (e.g. `--stop-on-lid-close` ended it) is restarted.
Entering `off`, pausing, or daemon shutdown ends the owned child. The guard
never signals any PID it did not start.

Defaults: poll every 5 seconds, 5 seconds of sustained work before starting,
30 seconds of sustained idle before stopping.

## Configuration

Persistent settings and runtime state live in per-session directories so
concurrent herdr sessions stay isolated:

```text
~/Library/Application Support/herdr-dopa/<session>/config.json  # settings
~/Library/Application Support/herdr-dopa/<session>/state.json   # runtime
```

(Herdr plugin directories are used automatically when plugin support provides
them.) The daemon reloads config every poll and on best-effort `SIGHUP` from
the CLI, so `set` applies within seconds.

| Key | Default | Env override | Meaning |
| --- | --- | --- | --- |
| `armed` | `true` | — | `off` pauses the guard |
| `poll_seconds` | `5` | `HERDR_DOPA_POLL_SECONDS` | seconds between observations |
| `start_grace_seconds` | `5` | `HERDR_DOPA_START_GRACE_SECONDS` | sustained work before starting |
| `stop_grace_seconds` | `30` | `HERDR_DOPA_STOP_GRACE_SECONDS` | sustained idle before stopping |
| `dopa_bin` | (provisional build path) | `DOPA_BIN` | dopa CLI to run |
| `keep_display_on` | `false` | — | pass `--keep-display-on` |
| `stop_on_lid_close` | `false` | — | pass `--stop-on-lid-close` |
| `herdr_bin_path` | `None` | `HERDR_BIN_PATH` | herdr binary override |

## herdr plugin manifest

`herdr-plugin.toml` is kept forward-compatible (actions delegate to
`guard.py`; the pane is a plain-text status, not a TUI). Note: herdr 0.9.0
removed the `herdr plugin` subcommand, so until plugin support returns,
run `scripts/guard.py` directly — everything works standalone.

## Tests

```sh
/usr/bin/python3 -m unittest discover -s tests
```

`test_dopa_ctl.py` spawns a stub executable (no real dopa needed). For a live
end-to-end check with the real daemon, point a fake herdr socket at the
monitor (see `docs/manual-test.md`).
