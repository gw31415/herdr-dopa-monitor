#!/bin/sh
# Supervisor for one owned dopa session: hold the fifo write end open so the
# connection's nc never sees stdin EOF (EOF would drop the connection and
# release the session server-side), then run nc in the foreground.
# The `ready` file is created only after the fifo is held open: senders must
# wait for it, otherwise bytes written before this point are lost (a fifo
# with no open references discards data).
# This pid is the recorded holder pid; killing it releases the session.
# Usage: hold.sh <holder-dir> <dopa-sock>
exec 3<>"$1/in"
: >"$1/ready"
exec nc -U "$2" <"$1/in" >"$1/out" 2>"$1/err"
