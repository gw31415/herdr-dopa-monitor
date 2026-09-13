# herdr plugin: dopa macOS Sleep Guard

A macOS [herdr](https://github.com/gw31415/herdr) sleep guard that keeps the machine awake
with [dopa](https://github.com/gw31415/dopa) while agents work: any `working` agent makes it
hold one owned `dopa` child process, and the first all-idle observation ends it. The guard is
a single Foundation-only Swift binary; a `dopa` session lives exactly as long as its process,
so it can never leak wakefulness or disturb your manual sessions.

## Features

- Session-scoped per-user LaunchAgent, started/stopped with agent count.
- One CLI (`herdr-dopa-monitor`) for status, on/off, settings, install/uninstall — plain text
  over pipes, color dashboard on a TTY, `--json` for scripts, `--watch` live view.
- Immediate start/stop: any `working` agent starts dopa instantly; the first all-idle
  observation stops it — no grace periods, no hysteresis.
- Hybrid timing: herdr event hooks trigger a state-locked iteration the moment pane/agent
  state changes; the poll daemon (default 5s) is the safety net.
- herdr UI integration: reports state to the owning pane and posts notifications at guard
  transitions — best-effort, silent when herdr is unreachable.

## Requirements

- macOS 13+ with the `dopa-daemon` service installed (`sudo dopa-daemon install`).
- `dopa` CLI (default: `/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa`; override with
  `herdr-dopa-monitor set dopa_bin PATH` or `DOPA_BIN`).
- herdr 0.9.0+ on `PATH` (or `HERDR_BIN_PATH` set) for live observation and plugin actions.
- Swift 5.9+ toolchain (Xcode Command Line Tools) to build.

## Build

```sh
swift build -c release        # binary at .build/release/herdr-dopa-monitor
swift test                    # unit tests (state machine, config, paths, socket)
```

`herdr plugin install` runs the same build via the manifest's `[[build]]` step; for local
development `herdr plugin link .` links the working tree (build it yourself first).

## Install

```sh
swift build -c release
.build/release/herdr-dopa-monitor install
.build/release/herdr-dopa-monitor sync
```

Or via the plugin: `herdr plugin link .` and the `install-launchagent` action. The installer
resolves the `herdr` binary path and current session, seeds the per-session config (never
overwrites yours), registers the LaunchAgent (stopped; `sync` starts it when agents exist),
and logs to `~/Library/Logs/herdr-dopa-monitor/<session>/` — no AppleScript, no Automation
access, no permission prompts.

## Usage

```sh
herdr-dopa-monitor status          # dashboard (or --json, or --watch for a live view)
herdr-dopa-monitor off             # pause (ends only our dopa session; `stop` alias)
herdr-dopa-monitor on              # resume
herdr-dopa-monitor set poll_seconds 5
herdr-dopa-monitor set keep_display_on true    # dopa --keep-display-on
herdr-dopa-monitor set stop_on_lid_close true  # dopa --stop-on-lid-close
herdr-dopa-monitor get             # all settings
herdr-dopa-monitor logs            # tail the daemon log
herdr-dopa-monitor notify "title" --body "text"          # herdr notification
herdr-dopa-monitor report-metadata # push guard state to the owning herdr pane
herdr-dopa-monitor uninstall --cleanup
```

`status --watch [SEC]` redraws the dashboard (default interval: the configured poll); ANSI
color only on a TTY without `NO_COLOR` and with `TERM != dumb`.

## Behavior

The monitor observes the herdr session socket (`HERDR_SOCKET_PATH`, `agent.list`) and treats
only exact `working` statuses as active work. Entering `on` starts (or adopts) one owned
`dopa` child; entering `off`, pausing, or daemon shutdown ends it immediately — the guard
never signals any PID it did not start. `sync` starts/stops the session's LaunchAgent with
the agent count.

```text
off --working--> on
on  --idle---->  off
```

Timing is hybrid: herdr event hooks run `herdr-dopa-monitor event` the moment pane/agent
state changes, so reactions are immediate; event payloads are informational — each iteration
re-observes the socket as the source of truth, and malformed events just behave like `once`.
The poll daemon (default 5s) corrects missed events, herdr restarts, and reconnects; SIGHUP
applies config edits immediately. All state writers (daemon, `once`, event hooks) serialize
their load → iterate → save cycle under an advisory `flock` on `<state_dir>/monitor.lock`,
so concurrent runners never double-spawn or double-terminate the dopa child.

## Configuration

Settings and runtime state live in per-session directories so concurrent herdr sessions stay
isolated (herdr plugin directories are used automatically when provided):

```text
~/Library/Application Support/herdr-dopa-monitor/<session>/config.json  # settings
~/Library/Application Support/herdr-dopa-monitor/<session>/state.json   # runtime
~/Library/Application Support/herdr-dopa-monitor/<session>/monitor.lock # flock (writers)
```

The daemon reloads config every poll and on `SIGHUP`, so `set` applies within seconds.

| Key | Default | Env override | Meaning |
| --- | --- | --- | --- |
| `armed` | `true` | — | `off` pauses the guard |
| `poll_seconds` | `5` | `HERDR_DOPA_POLL_SECONDS` | seconds between observations |
| `dopa_bin` | (provisional build path) | `DOPA_BIN` | dopa CLI to run |
| `keep_display_on` | `false` | — | pass `--keep-display-on` |
| `stop_on_lid_close` | `false` | — | pass `--stop-on-lid-close` |
| `herdr_bin_path` | `None` | `HERDR_BIN_PATH` | herdr binary override |

## Tests

```sh
swift test
```

`DopaCtlTests` spawns a stub executable (no real dopa needed) and `HerdrSocketTests` runs a
fake herdr socket server, so the suite is hermetic. For a live end-to-end check with the
real daemon, see `docs/manual-test.md`.
