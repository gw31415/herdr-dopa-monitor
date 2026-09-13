#!/bin/sh
# Event-hook entrypoint: one locked iteration and exit. herdr runs this from
# the manifest's [[events]] / [[startup]] hooks the moment pane/agent state
# changes. Unknown, missing, or malformed event data is not an error — the
# hook then simply behaves like once. Always exits 0.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
# shellcheck disable=SC1091
. "$ROOT/guard/lib.sh"

name="${HERDR_PLUGIN_EVENT:-unnamed}"
log "Event hook '$name' received; running one immediate iteration."
if manual_blocked; then
    reconcile_disabled
    exit 0
fi
do_iterate
exit 0
