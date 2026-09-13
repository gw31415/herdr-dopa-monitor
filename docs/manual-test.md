# Manual end-to-end test (real dopa-daemon, fake herdr)

Requires the `dopa-daemon` service installed (`sudo dopa-daemon install`).
The fake herdr socket below only feeds canned agent lists to the monitor —
nothing else on the system is touched, and the owned `dopa` session is ended
by the monitor itself at the end of the test.

1. Start a fake herdr socket that reports one `working` agent. Any
   newline-terminated responder will do; one-shot per connection:

```sh
printf '%s\n' '{"result":{"agents":[{"agent_status":"working"}]}}' \
  | nc -lU /tmp/fake-herdr.sock
```

(The socket path must stay under ~100 chars — `sockaddr_un.sun_path` limit.)
`nc` serves one connection per invocation, so re-run the line before each
`once` below, or wrap it in a `while true; do …; done` loop.

2. In another shell, run single monitor iterations against it:

```sh
cd herdr-dopa-monitor
swift build -c release
export HERDR_SOCKET_PATH=/tmp/fake-herdr.sock
export HERDR_SESSION_NAME=manual-test
export HERDR_DOPA_CONFIG_DIR=/tmp/dopa-e2e-config
export HERDR_DOPA_STATE_DIR=/tmp/dopa-e2e-state
mkdir -p /tmp/dopa-e2e-config /tmp/dopa-e2e-state
.build/release/herdr-dopa-monitor once   # -> on, dopa_pid set (run the nc line again first)
```

3. Confirm the real daemon sees our session (no sudo, creates nothing):

```sh
.build/release/dopa-daemon status   # or the Helpers copy; sessions: +1
```

4. Stop the fake socket (Ctrl+C or let the one-shot `nc` exit), run `once`
   again: herdr is unreachable, treated as idle → immediate `off` and the
   owned `dopa` process is gone; the daemon shows the previous session count
   again.

5. Daemon smoke test (signal handling + shutdown cleanup):

```sh
.build/release/herdr-dopa-monitor daemon &
kill -TERM %1   # after SIGTERM the owned dopa child ends and state.json says off
```

5b. SIGHUP wake test: with `poll_seconds` set high (e.g. `herdr-dopa-monitor set
poll_seconds 30`), start the daemon, note that `state.json` stops changing
during the sleep, then `kill -HUP %1` — the daemon logs `Config reloaded.`
and runs an iteration within ~0.1s instead of finishing the 30s sleep.

5c. Event hook smoke test (same env as step 2, socket reporting `working`):

```sh
.build/release/herdr-dopa-monitor event                                  # no env: like once
HERDR_PLUGIN_EVENT=pane.agent_status_changed \
HERDR_PLUGIN_EVENT_JSON='{"type":"pane.agent_status_changed","agent_status":"working"}' \
  .build/release/herdr-dopa-monitor event                                # immediate iteration
HERDR_PLUGIN_EVENT=bogus.event HERDR_PLUGIN_EVENT_JSON='{nope' \
  .build/release/herdr-dopa-monitor event                                # still a clean once
```

While the daemon is mid-iteration, a concurrent `event` blocks on
`<state_dir>/monitor.lock` until the daemon's save finishes, then adopts the
saved state (one spawn total — check `dopa_pid` is unchanged).

6. Clean up:
   `rm -rf /tmp/dopa-e2e-config /tmp/dopa-e2e-state /tmp/fake-herdr.sock`.

## herdr UI integration check

From inside a herdr pane (so `HERDR_BIN_PATH` / `HERDR_PANE_ID` are set):

```sh
.build/release/herdr-dopa-monitor notify "dopa guard" --body "smoke"
.build/release/herdr-dopa-monitor report-metadata   # title + tokens on the owning pane
.build/release/herdr-dopa-monitor status --watch 2   # live dashboard, Ctrl+C to exit
```

`report-metadata` is display-only and carries a 10-minute TTL, so stale
guard metadata disappears on its own. Both commands fail soft (exit 1 with a
note) when run outside a herdr session; the daemon skips them silently.
