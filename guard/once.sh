#!/bin/sh
# Manual one-iteration run. Honors the plugin gate: while disabled it ends
# the owned session instead of observing. Always exits 0.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOLD_SCRIPT="$ROOT/guard/hold.sh"
# shellcheck disable=SC1091
. "$ROOT/guard/lib.sh"

if manual_blocked; then
    reconcile_disabled
    exit 0
fi
do_iterate
exit 0
