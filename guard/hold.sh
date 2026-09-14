#!/bin/sh
# Supervisor for one owned dopa session: hold the fifo write end open so the
# connection's nc never sees stdin EOF (EOF would drop the connection and
# release the session server-side). When requested, monitor the local lid only
# for this holder's lifetime and close nc on a closed or unreadable state.
# The `ready` file is created only after the fifo is held open: senders must
# wait for it, otherwise bytes written before this point are lost (a fifo
# with no open references discards data).
# This shell execs nc, so the recorded holder pid remains the socket-owning nc
# pid. An optional watcher is its only child and asks that pid to exit on lid
# close/error. ioreg is never called when the third argument is false.
# Usage: hold.sh <holder-dir> <dopa-sock> <monitor-lid:true|false> <owned-nc-path>
set -u

HDIR="$1"
DOPA_SOCK="$2"
MONITOR_LID="$3"
OWNED_NC="$4"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/guard/lid.sh"

exec 3<>"$HDIR/in"
HOLDER_PID="$$"
HOLDER_STARTED="$(LC_ALL=C /bin/ps -p "$HOLDER_PID" -o lstart= 2>/dev/null)" || exit 1
[ -n "$HOLDER_STARTED" ] || exit 1
printf "%s" "$HOLDER_STARTED" >"$HDIR/started"

holder_is_current() {
    current_started="$(LC_ALL=C /bin/ps -p "$HOLDER_PID" -o lstart= 2>/dev/null)" || return 1
    [ "$current_started" = "$HOLDER_STARTED" ] || return 1
    current_command="$(LC_ALL=C /bin/ps -p "$HOLDER_PID" -o command= 2>/dev/null)" || return 1
    case "$current_command" in
        "$OWNED_NC"|"$OWNED_NC "*) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$MONITOR_LID" = "true" ]; then
    (
        # Only nc should keep the fifo's write side open.
        exec 3>&-
        # Give the parent shell time to exec the uniquely named nc. The acquire
        # preflight already covered this first polling interval.
        sleep 1
        while holder_is_current; do
            if ! lid_state="$(dopa_lid_state)"; then
                printf "lid_error" >"$HDIR/end_reason"
                if holder_is_current; then kill "$HOLDER_PID" 2>/dev/null || true; fi
                exit 0
            fi
            if [ "$lid_state" = "closed" ]; then
                printf "lid_closed" >"$HDIR/end_reason"
                if holder_is_current; then kill "$HOLDER_PID" 2>/dev/null || true; fi
                exit 0
            fi
            # One ioreg process per second, only while this option is on.
            sleep 1
        done
    ) &
    printf "%s" "$!" >"$HDIR/watcher.pid"
fi

: >"$HDIR/ready"
exec "$OWNED_NC" -U "$DOPA_SOCK" <"$HDIR/in" >"$HDIR/out" 2>"$HDIR/err"
