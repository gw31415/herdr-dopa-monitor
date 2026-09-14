#!/bin/sh
# Shared, one-shot lid-state reader. This file is sourced by lib.sh for the
# acquire preflight and by hold.sh for active-session monitoring.
#
# Keep the expensive ioreg call behind dopa_lid_state(): callers invoke it only
# when stop_on_lid_close is enabled and an acquire is being attempted or held.

DOPA_IOREG_BIN="${HERDR_DOPA_IOREG_BIN:-/usr/sbin/ioreg}"
DOPA_PLUTIL_BIN="${HERDR_DOPA_PLUTIL_BIN:-/usr/bin/plutil}"

# Prints "open" or "closed". Any missing service/property, unexpected type, or
# command failure returns non-zero so callers can fail closed.
dopa_lid_state() {
    # Capture first so POSIX sh can observe ioreg's status without pipefail.
    _dopa_lid_plist="$(
        "$DOPA_IOREG_BIN" -a -r -n IOPMrootDomain -d 1 2>/dev/null
    )" || return 1
    _dopa_lid_value="$(
        printf "%s" "$_dopa_lid_plist" \
            | "$DOPA_PLUTIL_BIN" -extract 0.AppleClamshellState raw \
                -expect bool -o - - 2>/dev/null
    )" || return 1
    case "$_dopa_lid_value" in
        true) printf "closed" ;;
        false) printf "open" ;;
        *) return 1 ;;
    esac
}
