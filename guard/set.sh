#!/bin/sh
# Change one setting (validated), then run one iteration so it applies now —
# unless the plugin is disabled, in which case the change is only saved.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
# shellcheck disable=SC1091
. "$ROOT/guard/lib.sh"

if [ $# -ne 2 ]; then
    printf "usage: set KEY VALUE\nkeys: keep_display_on, stop_on_lid_close, dopa_sock\n" >&2
    exit 2
fi
KEY="$1"
RAW="$2"

to_bool() {
    case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) printf "true" ;;
        0|false|no|n|off) printf "false" ;;
        *) return 1 ;;
    esac
}

load_config
case "$KEY" in
    keep_display_on|stop_on_lid_close)
        val="$(to_bool "$RAW")" || {
            printf "Invalid value: %s wants true/false, got '%s'\n" "$KEY" "$RAW" >&2
            exit 2
        }
        if [ "$KEY" = "keep_display_on" ]; then
            KEEP_DISPLAY_ON="$val"
        else
            STOP_ON_LID_CLOSE="$val"
        fi
        ;;
    dopa_sock)
        [ -n "$RAW" ] || { printf "Invalid value: dopa_sock wants a socket path\n" >&2; exit 2; }
        DOPA_SOCK="$RAW"
        ;;
    *)
        printf "Unknown key: %s. Valid: keep_display_on, stop_on_lid_close, dopa_sock\n" "$KEY" >&2
        exit 2
        ;;
esac
save_config
printf "%s = %s" "$KEY" "$RAW"
if [ "$KEY" = "dopa_sock" ] && [ ! -S "$DOPA_SOCK" ]; then
    printf " (warning: not a socket)" >&2
    printf "\n"
else
    printf " (applied)\n"
fi
if manual_blocked; then
    printf "Plugin disabled; change saved, applies on next enable.\n"
    exit 0
fi
do_iterate
exit 0
