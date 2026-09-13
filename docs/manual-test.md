# Manual end-to-end test (real dopa-daemon, fake herdr)

Requires the `dopa-daemon` service installed (`sudo dopa-daemon install`).
The fake herdr socket below only feeds canned agent lists to the monitor —
nothing else on the system is touched, and the owned `dopa` session is ended
by the monitor itself at the end of the test.

1. Start a fake herdr socket that reports one `working` agent:

```sh
/usr/bin/python3 - <<'EOF'
import json, os, socket
path = "/tmp/fake-herdr.sock"
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(1)
print("fake herdr listening", flush=True)
while True:
    conn, _ = srv.accept()
    with conn:
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk: break
            data += chunk
        body = json.dumps({"result": {"agents": [{"agent_status": "working"}]}}) + "\n"
        conn.sendall(body.encode())
EOF
```

2. In another shell, run one monitor iteration against it with short graces:

```sh
cd herdr-dopa-macos
export HERDR_SOCKET_PATH=/tmp/fake-herdr.sock
export HERDR_SESSION_NAME=manual-test
export HERDR_DOPA_CONFIG_DIR=/tmp/dopa-e2e-config
export HERDR_DOPA_STATE_DIR=/tmp/dopa-e2e-state
mkdir -p /tmp/dopa-e2e-config /tmp/dopa-e2e-state
python3 scripts/guard.py set start_grace_seconds 0
python3 scripts/guard.py set stop_grace_seconds 30
python3 scripts/monitor.py --once   # -> pending_on
python3 scripts/monitor.py --once   # -> on, dopa_pid set
```

3. Confirm the real daemon sees our session (no sudo, creates nothing):

```sh
.build/release/dopa-daemon status   # or the Helpers copy; sessions: 1
```

4. Stop the fake socket (Ctrl+C), run `--once` again: herdr is unreachable,
treated as idle → `pending_off`. After the stop grace, one more `--once`
moves to `off` and the owned `dopa` process is gone; the daemon shows
`sessions: 0` again.

5. Clean up: `rm -rf /tmp/dopa-e2e-config /tmp/dopa-e2e-state /tmp/fake-herdr.sock`.
