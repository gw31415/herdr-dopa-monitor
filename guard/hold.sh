#!/bin/sh
# Supervisor for one owned dopa session: hold the fifo write end open so the
# connection's nc never sees stdin EOF (EOF would drop the connection and
# release the session server-side). When requested, monitor the local lid only
# for this holder's lifetime and close nc on a closed or unreadable state.
# The `ready` file is created only after the fifo is held open: senders must
# wait for it, otherwise bytes written before this point are lost (a fifo
# with no open references discards data).
# This shell execs nc, so the recorded holder pid remains the socket-owning nc
# pid. A lifecycle watcher is its only child and asks that pid to exit when the
# plugin is disabled/unregistered, or on lid close/error when requested. ioreg
# is never called when the third argument is false.
# Usage: hold.sh <holder-dir> <dopa-sock> <monitor-lid:true|false> <owned-nc-path> <plugins.json> <plugin-id>
set -u

HDIR="$1"
DOPA_SOCK="$2"
MONITOR_LID="$3"
OWNED_NC="$4"
PLUGIN_REGISTRY="$5"
PLUGIN_ID="$6"
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

# Prints enabled, disabled, missing, or unavailable. Herdr atomically replaces
# the whole registry, so every check opens the current path rather than holding
# an fd/inode across checks.
plugin_registry_state() {
    [ -r "$PLUGIN_REGISTRY" ] || {
        printf "unavailable"
        return 0
    }
    index=0
    while plugin_id="$(
        /usr/bin/plutil -extract "$index.plugin_id" raw -expect string -o - \
            "$PLUGIN_REGISTRY" 2>/dev/null
    )"; do
        if [ "$plugin_id" = "$PLUGIN_ID" ]; then
            enabled="$(
                /usr/bin/plutil -extract "$index.enabled" raw -expect bool -o - \
                    "$PLUGIN_REGISTRY" 2>/dev/null
            )" || {
                printf "unavailable"
                return 0
            }
            case "$enabled" in
                true) printf "enabled" ;;
                false) printf "disabled" ;;
                *) printf "unavailable" ;;
            esac
            return 0
        fi
        index=$((index + 1))
    done
    # A valid registry without our entry means unlink/uninstall. Distinguish it
    # from malformed JSON so diagnostics preserve the actual reason.
    if /usr/bin/plutil -convert xml1 -o /dev/null "$PLUGIN_REGISTRY" >/dev/null 2>&1; then
        printf "missing"
    else
        printf "unavailable"
    fi
}

(
    # Only nc should keep the fifo's write side open.
    exec 3>&-
    # The watcher is forked just before the parent execs nc. Wait for that
    # identity transition so the first registry check cannot race startup.
    waited=0
    while ! holder_is_current && kill -0 "$HOLDER_PID" 2>/dev/null; do
        [ "$waited" -lt 100 ] || exit 1
        sleep 0.05
        waited=$((waited + 1))
    done
    holder_is_current || exit 1
    # Signal readiness only after the parent has become the socket-owning nc;
    # callers may safely apply the same identity check as soon as this exists.
    : >"$HDIR/ready"
    last_registry_fingerprint=""
    while holder_is_current; do
        registry_fingerprint="$(/usr/bin/cksum "$PLUGIN_REGISTRY" 2>/dev/null)" || \
            registry_fingerprint=""
        if [ -z "$registry_fingerprint" ]; then
            registry_state="unavailable"
        elif [ "$registry_fingerprint" != "$last_registry_fingerprint" ]; then
            registry_state="$(plugin_registry_state)"
            last_registry_fingerprint="$registry_fingerprint"
        else
            registry_state="enabled"
        fi
        if [ "$registry_state" != "enabled" ]; then
            printf "plugin_%s" "$registry_state" >"$HDIR/end_reason"
            if holder_is_current; then kill "$HOLDER_PID" 2>/dev/null || true; fi
            exit 0
        fi
        if [ "$MONITOR_LID" = "true" ]; then
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
        fi
        # cksum reads the small registry once per second. plutil only runs when
        # its contents change; ioreg only runs when lid monitoring is enabled.
        sleep 1
    done
) &
printf "%s" "$!" >"$HDIR/watcher.pid"

exec "$OWNED_NC" -U "$DOPA_SOCK" <"$HDIR/in" >"$HDIR/out" 2>"$HDIR/err"
