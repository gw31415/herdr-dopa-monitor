#!/bin/sh
# End the owned dopa session now and leave the guard idle. There is no
# background process left behind by design: hook runs are one-shot, so
# stop only has to release our own session, reset the state to off,
# and sweep leftovers of removed generations (LaunchAgent plists, old
# daemon binaries). Your own dopa sessions are never touched. Config and
# state are kept. Always allowed (it is the cleanup path).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
# shellcheck disable=SC1091
. "$ROOT/guard/lib.sh"

# Leftover LaunchAgent plists of the removed daemon generation (ours by
# label prefix only — nothing else is touched).
for plist in "$HOME"/Library/LaunchAgents/com.amas.herdr.dopa.monitor.*.plist \
             "$HOME"/Library/LaunchAgents/com.herdr.dopa.monitor.*.plist; do
    [ -e "$plist" ] || continue
    label="$(basename "$plist" .plist)"
    log "booting out leftover LaunchAgent: $label"
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    rm -f "$plist" && log "removed leftover plist: $plist"
done
# Leftover monitor daemons of the removed Swift generation.
pkill -f 'herdr-dopa-monitor daemon' 2>/dev/null || true

lock
load_state
if [ -n "$SESSION_ID" ] || holder_alive; then
    dopa_release
    printf "Stopped: ended owned dopa session.\n"
else
    printf "Stopped: no owned dopa session.\n"
fi
STATE=off
SESSION_ID=""
HOLDER_PID=""
LAST_WORKING=false
LAST_ERROR=""
save_state
unlock
printf "Done. Run \`stop\` before \`herdr plugin uninstall\`"
printf " so no owned dopa session is left behind.\n"
exit 0
