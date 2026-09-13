# herdr plugin: dopa macOS Sleep Guard

A macOS [herdr](https://github.com/gw31415/herdr) sleep guard that keeps the
machine awake with [dopa](https://github.com/gw31415/dopa) while agents are
working. Successor to the archived `herdr-amphetamine-macos` (Amphetamine is
gone; the old curses TUI is gone too). The guard itself is a single Swift
binary, `herdr-dopa-monitor`, built with Swift Package Manager — no Python runtime is
involved anymore.

It does one thing deliberately: when at least one herdr agent is `working`, it
holds one owned `dopa` process. When agents go idle, it ends that process. A
`dopa` session lives exactly as long as its process, so the guard can neither
leak wakefulness nor disturb your manual `dopa` sessions, Dopa.app, or anyone
else's sessions — it only ever signals its own child PID.

## Features

- Session-scoped per-user LaunchAgent, installed once and started/stopped with
  agent count.
- One modern CLI (`herdr-dopa-monitor`) for status, on/off, settings,
  install/uninstall — plain text over pipes, color dashboard on a TTY,
  `--json` for scripts, `--watch` for a live pane view. No curses, no
  fullscreen, no mouse.
- Immediate start/stop: any `working` agent starts dopa instantly, and the
  first all-idle observation stops it — no grace periods, no hysteresis.
- Event-driven with poll correction (hybrid): herdr event hooks run
  `herdr-dopa-monitor event` the moment pane/agent state changes, so reactions are
  immediate; the poll daemon (default 5s) stays as the safety net for missed
  events, herdr restarts, and reconnects.
- herdr UI integration: the daemon reports its state to the owning pane
  (`herdr pane report-metadata`) and posts notifications
  (`herdr notification show`) at guard start/end/error — best-effort,
  silent when herdr is unreachable.
- Single static-ish binary, Foundation-only (no external Swift packages).

## Requirements

- macOS 13+ with the `dopa-daemon` service installed
  (`sudo dopa-daemon install` from the dopa repo).
- `dopa` CLI (default: `/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa`;
  override with `herdr-dopa-monitor set dopa_bin PATH` or `DOPA_BIN`).
- herdr 0.9.0+ on `PATH` (or `HERDR_BIN_PATH` set) for live agent observation
  and the plugin actions/pane.
- Swift 5.9+ toolchain (Xcode Command Line Tools) to build.

## Build

```sh
cd herdr-dopa-monitor
swift build -c release        # binary at .build/release/herdr-dopa-monitor
swift test                    # unit tests (state machine, config, paths, socket)
```

`herdr plugin install` runs the same `swift build -c release` via the
manifest's `[[build]]` step. For local development, `herdr plugin link .`
links the working tree (link does not build; build it yourself first).

## Install

```sh
cd herdr-dopa-monitor
swift build -c release
.build/release/herdr-dopa-monitor install
.build/release/herdr-dopa-monitor sync
```

Or, with the plugin linked in herdr (0.9.0+):

```sh
herdr plugin link /path/to/herdr-dopa-monitor
herdr plugin enable herdr-dopa-monitor   # if linked --disabled
herdr plugin action invoke herdr-dopa-monitor.install-launchagent
herdr plugin pane open --plugin herdr-dopa-monitor --entrypoint status
```

The installer:

- resolves the `herdr` binary path for the LaunchAgent environment,
- infers the current herdr session (`HERDR_SESSION_NAME` / `HERDR_SESSION`, or
  the single running session),
- seeds `<config>/config.json` (per-session; never overwrites yours),
- writes `~/Library/LaunchAgents/com.amas.herdr.dopa.monitor.<session>.plist`
  pointing at the built `herdr-dopa-monitor` binary (release artifact under the
  plugin root, or the running binary when it already lives in `.build/`),
- registers the monitor (stopped; `sync` starts it when agents exist),
- writes logs under `~/Library/Logs/herdr-dopa-monitor/<session>/`.

No permission prompts: unlike the Amphetamine version there is no AppleScript
and no Automation access involved.

> **Label migration note.** The LaunchAgent label base was renamed from
> `com.herdr.dopa.monitor` to `com.amas.herdr.dopa.monitor`. `install` and
> `uninstall` automatically boot out and delete a leftover
> `~/Library/LaunchAgents/com.herdr.dopa.monitor.<session>.plist` for the
> same session only (no wildcard scans; other sessions and unrelated plists
> are never touched).

## Rename to `herdr-dopa-monitor` (0.3.0)

dopa itself is macOS-only, so the `-macos` suffix was dropped and everything
is unified on the `herdr-dopa-monitor` family. The LaunchAgent label is
deliberately **unchanged**.

| What | Old | New |
| --- | --- | --- |
| Binary / Swift target | `herdr-dopa` | `herdr-dopa-monitor` |
| herdr plugin id | `dopa-macos` | `herdr-dopa-monitor` |
| Data dirs | `~/Library/Application Support/herdr-dopa/<slug>` | `…/herdr-dopa-monitor/<slug>` |
| Log dir | `~/Library/Logs/herdr-dopa/<slug>` | `~/Library/Logs/herdr-dopa-monitor/<slug>` |
| LaunchAgent label | `com.amas.herdr.dopa.monitor.<slug>` | unchanged |
| Plist template | `launchagents/com.amas.herdr.dopa.monitor.plist.template` | unchanged (contents reference the new binary) |

### Migration notes

- **Plugin link**: the plugin id changed, so re-link the plugin:
  `herdr plugin unlink dopa-macos && herdr plugin link .` (then enable it if
  you linked `--disabled`). Old per-plugin data under the previous id is not
  carried over.
- **Data dirs**: the old standalone `herdr-dopa/<slug>` dirs are moved to the
  new `herdr-dopa-monitor/<slug>` layout automatically — once, at `install`
  and at the first `daemon`/`once`/`event` startup per invocation. The move
  happens only when the old dir exists and the new one does not (new wins);
  when both exist the old dir is left untouched for manual recovery. A failed
  move is logged and the new dir is created fresh; the guard never falls back
  to reading the old layout.
- **LaunchAgent plist**: the existing plist still points at the old
  `.build/release/herdr-dopa` binary path, which no longer exists after a
  rebuild. Run `herdr-dopa-monitor install` (or the `install-launchagent`
  action / `sync`) to rewrite and re-register the plist with the new binary
  path; the label stays the same, so no orphan agents are left behind.

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

`status --watch [SEC]` clears the screen and redraws (default interval: the
configured poll). The plugin's status pane runs exactly that. ANSI color is
enabled only on a TTY without `NO_COLOR` and with `TERM != dumb`.

## Behavior

The monitor observes the herdr session socket (`HERDR_SOCKET_PATH`,
`agent.list`) and treats only exact `working` statuses as active work. `sync`
installs this session's LaunchAgent if needed, starts it when agent count is
nonzero, and stops it when the count is zero. A running monitor also stops its
own LaunchAgent after it observes zero agents (`HERDR_DOPA_AUTO_UNLOAD=1`,
set by the plist).

```text
off --working--> on
on  --idle---->  off
```

Transitions are immediate: dopa starts the moment any agent is observed
`working` and stops the moment no agent is. Entering `on` starts (or adopts)
the owned `dopa` child; while `on`, a child that died on its own (e.g.
`--stop-on-lid-close` ended it) is restarted. Entering `off`, pausing
(`herdr-dopa-monitor off`), or daemon shutdown ends the owned child immediately. The
guard never signals any PID it did not start.

### Event hooks + poll correction (hybrid timing)

The manifest declares herdr event hooks that all run one command:

```toml
[[startup]]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/.build/release/herdr-dopa-monitor\" event"]

[[events]]
on = "pane.agent_status_changed"
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/.build/release/herdr-dopa-monitor\" event"]
```

Hooked events: `pane.agent_status_changed` (agent goes working/idle/etc.),
`pane.agent_detected`, `pane.created`, `pane.closed`, `pane.exited`, plus a
`[[startup]]` hook that runs once when herdr restores the session.

`herdr-dopa-monitor event` reads `HERDR_PLUGIN_EVENT` / `HERDR_PLUGIN_EVENT_JSON`
(injected by herdr) and performs exactly one state-locked monitor iteration,
so the guard reacts within milliseconds of the event instead of waiting for
the next poll. The event payload is informational: the iteration always
re-observes the herdr socket as the source of truth. Unknown, missing, or
malformed event data never fails the hook — it just behaves like `once`.

The poll daemon stays (default every 5 seconds) as the safety net: it
corrects anything a missed event, a herdr restart, or a socket reconnect
would have skipped. SIGHUP also interrupts the daemon's current sleep, so
config edits (`herdr-dopa-monitor set`, `on`, `off`) apply immediately rather than
at the next poll.

### Concurrency: one writer at a time

Three kinds of runners mutate state: the poll daemon, `herdr-dopa-monitor once`, and
the `event` hooks (which can fire while the daemon is mid-iteration). Every
writer performs its whole load → iterate → save critical section under an
advisory POSIX `flock` on `<state_dir>/monitor.lock`, so concurrent runners
serialize and can never double-spawn or double-terminate the owned dopa
child. State is re-loaded inside the lock on every iteration, which also
means the daemon adopts whatever an event hook last wrote instead of
clobbering it with a stale in-memory copy. Readers (`status`) never take the
lock; state writes are atomic (temp file + rename), so they can never see a
torn file. If the lock file cannot be opened (unwritable state dir), the
iteration still runs — availability over strictness.

At daemon transitions (start, guard on, guard off, error, stop) the monitor
calls `herdr notification show` and `herdr pane report-metadata` through
`HERDR_BIN_PATH` — best-effort, skipped silently outside a herdr session.

Default: poll every 5 seconds (events are immediate on top of it).

## Configuration

Persistent settings and runtime state live in per-session directories so
concurrent herdr sessions stay isolated:

```text
~/Library/Application Support/herdr-dopa-monitor/<session>/config.json  # settings
~/Library/Application Support/herdr-dopa-monitor/<session>/state.json   # runtime
~/Library/Application Support/herdr-dopa-monitor/<session>/monitor.lock # flock (writers)
```

(Herdr plugin directories are used automatically when plugin support provides
them.) The daemon reloads config every poll and on best-effort `SIGHUP` from
the CLI, so `set` applies within seconds.

| Key | Default | Env override | Meaning |
| --- | --- | --- | --- |
| `armed` | `true` | — | `off` pauses the guard |
| `poll_seconds` | `5` | `HERDR_DOPA_POLL_SECONDS` | seconds between observations |
| `dopa_bin` | (provisional build path) | `DOPA_BIN` | dopa CLI to run |
| `keep_display_on` | `false` | — | pass `--keep-display-on` |
| `stop_on_lid_close` | `false` | — | pass `--stop-on-lid-close` |
| `herdr_bin_path` | `None` | `HERDR_BIN_PATH` | herdr binary override |

## herdr plugin manifest

`herdr-plugin.toml` (min herdr 0.9.0) declares a `swift build -c release`
build step, a `[[startup]]` hook and `[[events]]` hooks (see
[Behavior](#behavior)) that run `herdr-dopa-monitor event` for immediate reactions,
actions (`status`, `on`, `off`, `sync-launchagent`, `install-launchagent`,
`uninstall-launchagent`), and an overlay status pane that runs
`herdr-dopa-monitor status --watch`. Actions and hooks exec
`$HERDR_PLUGIN_ROOT/.build/release/herdr-dopa-monitor`, so the release binary must
exist (build it, or install from GitHub which runs the build step).

## Tests

```sh
swift test
```

`DopaCtlTests` spawns a stub executable (no real dopa needed) and
`HerdrSocketTests` runs a fake herdr socket server, so the whole suite is
hermetic. For a live end-to-end check with the real daemon, see
`docs/manual-test.md`.
