#!/bin/sh
# Dashboard: plain text on a TTY/pipes, --json for scripts, --watch for a
# live view. Read-only; never spawns dopa.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
# shellcheck disable=SC1091
. "$ROOT/guard/lib.sh"

JSON=false
WATCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON=true ;;
        --watch)
            if [ $# -ge 2 ]; then
                WATCH="$2"
                shift
            else
                WATCH=2
            fi
            ;;
        *) printf "Unknown option for status: %s\n" "$1" >&2; exit 2 ;;
    esac
    shift
done

render() {
    load_config
    load_state
    if observe; then
        TOTAL="$OBS_TOTAL"
        WORKING="$OBS_WORKING"
        AGENTS_ERR=""
    else
        TOTAL=0
        WORKING=0
        AGENTS_ERR="herdr unreachable"
    fi
    ALIVE=false
    if [ -n "$SESSION_ID" ] && dopa_session_alive "$SESSION_ID"; then
        ALIVE=true
    fi
    ENABLED="$(plugin_enabled)"
    DOPA_PRESENT=false
    [ -S "$DOPA_SOCK" ] && DOPA_PRESENT=true
    if [ "$JSON" = "true" ]; then
        if [ -n "$SESSION_ID" ]; then SID_JSON="\"$SESSION_ID\""; else SID_JSON=null; fi
        if [ -n "$LAST_ERROR" ]; then ERR_JSON="\"$(printf "%s" "$LAST_ERROR" | sed 's/"/\\"/g')\""; else ERR_JSON=null; fi
        if [ -n "$AGENTS_ERR" ]; then AERR_JSON="\"$AGENTS_ERR\""; else AERR_JSON=null; fi
        printf '{\n'
        printf '  "monitor_state": "%s",\n' "$STATE"
        printf '  "session_id": %s,\n' "$SID_JSON"
        printf '  "owned_session_alive": %s,\n' "$ALIVE"
        printf '  "dopa_sock": "%s",\n' "$(printf "%s" "$DOPA_SOCK" | sed 's/"/\\"/g')"
        printf '  "dopa_present": %s,\n' "$DOPA_PRESENT"
        printf '  "plugin_enabled": %s,\n' "$([ "$ENABLED" = "unknown" ] && printf null || printf "%s" "$ENABLED")"
        printf '  "agents": {"available": %s, "total": %s, "working": %s, "error": %s},\n' \
            "$([ -z "$AGENTS_ERR" ] && printf true || printf false)" "$TOTAL" "$WORKING" "$AERR_JSON"
        printf '  "config": {"keep_display_on": %s, "stop_on_lid_close": %s, "dopa_sock": "%s"},\n' \
            "$KEEP_DISPLAY_ON" "$STOP_ON_LID_CLOSE" "$(printf "%s" "$DOPA_SOCK" | sed 's/"/\\"/g')"
        printf '  "config_file": "%s",\n' "$(config_file)"
        printf '  "state_file": "%s",\n' "$(state_file)"
        printf '  "last_error": %s\n}\n' "$ERR_JSON"
        return 0
    fi
    if [ "$ENABLED" = "false" ]; then
        printf "○ dopa guard — disabled\n"
    elif [ "$STATE" = "on" ]; then
        printf "● dopa guard — guarding  ·  %s working\n" "$WORKING"
    elif [ "$STATE" = "error" ]; then
        printf "✖ dopa guard — error  ·  %s\n" "${LAST_ERROR:-run once/event to retry}"
    else
        printf "○ dopa guard — idle\n"
    fi
    if [ -z "$AGENTS_ERR" ]; then
        printf "  agents        %s observed · %s working\n" "$TOTAL" "$WORKING"
    else
        printf "  agents        unavailable (%s)\n" "$AGENTS_ERR"
    fi
    if [ "$ALIVE" = "true" ]; then
        flags=""
        [ "$KEEP_DISPLAY_ON" = "true" ] && flags="$flags --keep-display-on"
        [ "$STOP_ON_LID_CLOSE" = "true" ] && flags="$flags --stop-on-lid-close"
        printf "  dopa session  active ·%s\n" "$flags"
    elif [ -n "$SESSION_ID" ]; then
        printf "  dopa session  stale session %s (gone)\n" "$SESSION_ID"
    else
        printf "  dopa session  none\n"
    fi
    if [ "$DOPA_PRESENT" = "false" ]; then
        printf "  dopa socket   MISSING: %s\n" "$DOPA_SOCK"
    fi
    printf "  config        %s\n" "$(config_file)"
    printf "    keep_display_on    %s\n" "$KEEP_DISPLAY_ON"
    printf "    stop_on_lid_close  %s\n" "$STOP_ON_LID_CLOSE"
    printf "    dopa_sock          %s\n" "$DOPA_SOCK"
}

if [ -n "$WATCH" ]; then
    case "$WATCH" in
        ''|*[!0-9.]*) WATCH=2 ;;
    esac
    while :; do
        printf '\033[H\033[2J\033[3J'
        render
        sleep "$WATCH"
    done
fi
render
exit 0
