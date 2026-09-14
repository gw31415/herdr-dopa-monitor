# herdr plugin: dopa macOS Sleep Guard

A macOS [herdr](https://github.com/gw31415/herdr) sleep guard that keeps the machine awake
with [dopa](https://github.com/gw31415/dopa) while agents work: any `working` agent makes it
hold one owned `dopa` session, and the first all-idle observation ends it. One machine
holds exactly one session, shared across all herdr sessions. The guard is event-driven
shell only — no build, no extra daemon, and no guard-wide poll loop. A `dopa` session lives
exactly as long as its holder connection, so the guard can never leak wakefulness or
disturb your manual sessions.

Pause and resume via herdr itself: `herdr plugin disable herdr-dopa-monitor` stops the
guard (hooks stop firing and the owned session is ended), `herdr plugin enable
herdr-dopa-monitor` resumes it.

## Requirements

- macOS with the `dopa-daemon` service installed (`sudo dopa-daemon install`).
- herdr 0.9.0+ for live observation and plugin actions.
- Stock tools only (`sh`, `nc`, `ps`, `ln`, `grep`, `kill`, `launchctl`, `cksum`, `ioreg`, `plutil`) — no
  toolchain, no packages.

## Quick install

```sh
herdr plugin install gw31415/herdr-dopa-monitor
```

That is the whole flow: herdr registers the hooks, and from the first event on the guard
follows the agent state. No build step, no AppleScript, no Automation access, no
permission prompts.

## Manual install

For a local checkout (no build needed — it is all shell):

```sh
git clone https://github.com/gw31415/herdr-dopa-monitor.git
cd herdr-dopa-monitor
herdr plugin link .
```

Disable or uninstall normally through herdr; no cleanup command is required. The active
holder watches herdr's plugin registry and releases its owned `dopa` session when the
plugin is disabled, unlinked, or uninstalled.

## Usage

```sh
sh guard/status.sh          # dashboard (or --json, or --watch for a live view)
sh guard/set.sh keep_display_on true    # dopa session option (applies now)
sh guard/set.sh stop_on_lid_close true  # plugin-side lid monitor (applies now)
sh guard/stop.sh       # end the owned dopa session
```

`status.sh --watch [SEC]` redraws the dashboard (default interval: 2s).

## Behavior

Each run re-observes **all** herdr sessions (every session socket under the herdr config
root) and treats only exact `working` statuses as active work — one idle session never
stops the single session while another session still works. Entering `on` acquires one
owned session on the dopa-daemon control socket; entering `off` releases it — the guard
never touches sessions it did not acquire.

```text
off --working--> on
on  --idle---->  off
```

Timing is purely event-driven: herdr event hooks run `guard/event.sh` the moment
pane/agent state changes (plus one `[[startup]]` reconciliation after herdr restores the
session). Each run re-observes the sockets as the source of truth, and malformed events
just behave like `once`. Every run also reconciles the on-state, so a session that died
on its own is re-acquired on the next run. All writers serialize their load → observe →
save cycle on an atomic `mkdir` lock under `<state_dir>/lock`, so concurrent runners
never double-acquire.

The owned session is held by a background `nc` connected to the dopa-daemon control
socket: the connection owns the session, so killing the holder releases it. The holder
is a plain orphan process (no LaunchAgent, no daemon); a supervisor shell keeps its
stdin open so it never sees EOF.

When `stop_on_lid_close=true`, the guard reads `AppleClamshellState` with
`/usr/sbin/ioreg` and `/usr/bin/plutil` once before acquisition and then only while its
owned session is held. With the setting disabled, it does not invoke either tool. A
closed lid or an unreadable lid state is fail-closed: before acquisition the guard skips
`session.acquire`; while holding a session it closes the dopa connection, which releases
the owned session. Reopening the lid does not reacquire it automatically; reacquisition
waits for the next Herdr event (or an explicit manual iteration).

Enable/disable is herdr's switch and the guard respects it: hooks only run while enabled
(herdr-enforced), and manual commands never hold a session while disabled. While an owned
session exists, its lightweight lifecycle watcher reads herdr's global `plugins.json`;
`enabled=false` or a missing plugin entry closes the holder connection automatically, so
disable, unlink, and uninstall need no preparatory cleanup command. A malformed or missing
registry also fails closed. Enabling resumes normal event handling; if agents are already
working, acquisition occurs on the next Herdr event or explicit manual iteration.

There is no guard-wide lid poll loop: registry monitoring exists only for an active owned
session, and lid polling exists only when the setting is enabled. If that session ends
because the lid closes or its state cannot be read while agents still work, nothing
re-acquires it until the next event or manual command. The next run heals it when the lid
is open and readable, and the all-idle stop transition (the case that would leak
wakefulness) is itself an event.

## Configuration

One config file, one state file for the whole machine. herdr injects the locations
into hook runs (`HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR`); manual runs
resolve the same herdr plugin locations from the XDG base dirs:

```text
~/.config/herdr/plugins/config/herdr-dopa-monitor/config  # settings (KEY='value')
~/.local/state/herdr/plugins/herdr-dopa-monitor/state     # runtime (KEY='value')
~/.local/state/herdr/plugins/herdr-dopa-monitor/holder/   # session holder (fifo, pid)
```

(`$XDG_CONFIG_HOME` / `$XDG_STATE_HOME` respected; `HERDR_DOPA_CONFIG_DIR` /
`HERDR_DOPA_STATE_DIR` override both for manual testing.)

Every run reads the config fresh, so `set.sh` applies on the next run — and `set.sh`
runs one iteration itself, so it applies immediately (unless the plugin is disabled, in
which case the change is saved and applies on next enable).

| Key | Default | Env override | Meaning |
| --- | --- | --- | --- |
| `dopa_sock` | `/var/run/dopa/control.sock` | `DOPA_SOCK` | dopa-daemon control socket |
| `keep_display_on` | `false` | — | session option `keepDisplayOn` |
| `stop_on_lid_close` | `false` | — | plugin-side lid monitor; when true, check before acquisition and while the owned session is held, then close it on a closed or unreadable state |

## For developers

Shell only: `sh -n guard/*.sh` syntax-checks everything. There is no unit suite by
design (stock macOS has no test runner worth depending on); verify live with
`docs/manual-test.md` (fake herdr socket + real dopa-daemon).
