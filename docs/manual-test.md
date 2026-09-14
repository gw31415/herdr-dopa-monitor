# Manual end-to-end test (real dopa-daemon, fake herdr)

Requires the `dopa-daemon` service installed (`sudo dopa-daemon install`) and this
checkout linked with `herdr plugin link .`.
The fake herdr socket below only feeds canned agent lists to the guard —
nothing else on the system is touched, and the owned `dopa` session is ended
by the guard itself at the end of the test.

1. Start a fake herdr socket that reports one `working` agent. Any
   newline-terminated responder will do; one-shot per connection:

```sh
printf '%s\n' '{"result":{"agents":[{"agent_status":"working"}]}}' \
  | nc -lU /tmp/fake-herdr.sock
```

(The socket path must stay under ~100 chars — `sockaddr_un.sun_path` limit.)
`nc` serves one connection per invocation, so re-run the line before each
`once` below, or wrap it in a `while true; do …; done` loop. (macOS `nc`
clients exit on stdin EOF either way, so serve-then-close responders are
both necessary and sufficient.)

2. In another shell, run single monitor iterations against it:

```sh
cd herdr-dopa-monitor
export HERDR_SOCKET_PATH=/tmp/fake-herdr.sock
export HERDR_DOPA_CONFIG_DIR=/tmp/dopa-e2e-config
export HERDR_DOPA_STATE_DIR=/tmp/dopa-e2e-state
mkdir -p /tmp/dopa-e2e-config /tmp/dopa-e2e-state
sh guard/once.sh   # -> on, SESSION_ID set (run the nc line again first)
```

`HERDR_SOCKET_PATH` is always observed itself; the guard additionally unions
every live herdr session socket, so one idle session never stops the single
`dopa` session while another session still works.

3. Confirm the real daemon sees our session (read-only):

```sh
dopa-daemon status --json   # sessions: +1, clientName herdr-dopa-monitor
```

4. Stop the fake socket (Ctrl+C or let the one-shot `nc` exit), run `once`
   again: herdr is unreachable, treated as idle → immediate `off` and the
   owned session is gone; the daemon shows the previous session count again.

5. Event hook smoke test (same env as step 2, socket reporting `working`):

```sh
sh guard/event.sh                                  # no env: like once
HERDR_PLUGIN_EVENT=pane.agent_status_changed \
  sh guard/event.sh                                # immediate iteration
HERDR_PLUGIN_EVENT=bogus.event \
  sh guard/event.sh                                # still a clean once
```

Two concurrent `once` runs serialize on `<state_dir>/lock`: the second adopts
the first's saved state (one session total — check `SESSION_ID` is unchanged
and only one holder `nc` is alive).

6. Disable lifecycle (needs the plugin linked and herdr running):

```sh
herdr plugin disable herdr-dopa-monitor
# the owned session ends automatically within about one second
herdr plugin enable herdr-dopa-monitor
```

Repeat with `herdr plugin unlink herdr-dopa-monitor`: the owned session must end without
running `guard/stop.sh`. Relink the checkout afterward to continue testing. A managed
installation can be checked the same way with `herdr plugin uninstall`; no cleanup action
is required before either command.

7. Clean up:
   `sh guard/stop.sh`; `rm -rf /tmp/dopa-e2e-config /tmp/dopa-e2e-state /tmp/fake-herdr.sock`.

## Lid-close behavior

Run this after the basic flow above, with a fake socket that reports `working`.

1. Enable the plugin-side monitor and acquire while the lid is open:

   ```sh
   sh guard/set.sh stop_on_lid_close true
   # re-run the fake-socket responder, then:
   sh guard/once.sh
   ```

   `ioreg`/`plutil` are invoked only in this mode: once before acquisition and while the
   owned session holder is alive. With `stop_on_lid_close=false`, neither the preflight
   check nor the holder's lid-monitor loop may invoke them.

2. Close the lid and wait briefly. The holder must close its dopa connection and the
   owned session must disappear from `dopa-daemon status --json`. Reopening the lid must
   not reacquire a session by itself. Re-run the Herdr event hook (or `sh guard/once.sh`)
   after reopening; with the working response, the guard should acquire again.

3. Verify the pre-acquisition fail-closed path: release the owned session, close the lid,
   and run `once` while the fake socket still reports `working`. No new dopa session must
   be acquired. An unreadable lid-state result is handled the same way. Reopen the lid and
   trigger the next Herdr event to allow acquisition again.
