#!/bin/sh
# Shared helpers for the herdr-dopa-monitor shell guard. Sourced, not executed.
# Event-driven only: every entry runs one locked iteration and exits; the
# single owned dopa session is held by a background `nc` connected to the
# dopa-daemon control socket (the connection owns the session — closing it
# releases the session, same contract as the `dopa` CLI).
#
# Stock macOS only: sh, nc -U, mkdir, ln, grep/sed, kill, launchctl, ioreg, plutil.

PLUGIN_ID="herdr-dopa-monitor"
DEFAULT_DOPA_SOCK="/var/run/dopa/control.sock"
LOCK_WAIT_SECONDS=15

# Captured at source time (each CLI run is a fresh process): explicit env
# overrides that a sourced config file must never clobber.
ENV_DOPA_SOCK="${DOPA_SOCK:-}"

# Never die on SIGPIPE (fifo writes racing a dead holder must be handled,
# not fatal).
trap "" PIPE

# One-shot AppleClamshellState reader. Callers keep it behind the
# STOP_ON_LID_CLOSE gate so ioreg never runs when the feature is disabled.
# shellcheck disable=SC1091
. "$ROOT/guard/lid.sh"

# --- paths (single global config/state for the whole machine) ---
#
# Precedence: explicit HERDR_DOPA_* overrides (manual testing), then the
# HERDR_PLUGIN_* dirs herdr injects into hook/action/pane runs, then the
# herdr plugin locations derived from the XDG base dirs (this is where
# herdr puts them: $XDG_CONFIG_HOME/herdr/plugins/config/<id> and
# $XDG_STATE_HOME/herdr/plugins/<id>), then the standalone Library dir.
# The XDG step keeps manual runs (plain terminal, no plugin env) on the
# exact same files the hooks use.

config_dir() {
    if [ -n "${HERDR_DOPA_CONFIG_DIR:-}" ]; then
        printf "%s" "$HERDR_DOPA_CONFIG_DIR"
    elif [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then
        printf "%s" "$HERDR_PLUGIN_CONFIG_DIR"
    else
        printf "%s" "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/herdr-dopa-monitor"
    fi
}

state_dir() {
    if [ -n "${HERDR_DOPA_STATE_DIR:-}" ]; then
        printf "%s" "$HERDR_DOPA_STATE_DIR"
    elif [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
        printf "%s" "$HERDR_PLUGIN_STATE_DIR"
    else
        printf "%s" "${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/herdr-dopa-monitor"
    fi
}

config_file() { printf "%s/config" "$(config_dir)"; }
state_file() { printf "%s/state" "$(state_dir)"; }
lock_dir() { printf "%s/lock" "$(state_dir)"; }
holder_dir() { printf "%s/holder" "$(state_dir)"; }

# --- logging (stderr: captured in the herdr plugin command log, and never
# swallowed by command substitution) ---

log() {
    printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# --- locking (mkdir is atomic; stale locks are stolen) ---

lock() {
    dir="$(lock_dir)"
    waited=0
    while ! mkdir "$dir" 2>/dev/null; do
        if [ -f "$dir/pid" ]; then
            oldpid="$(cat "$dir/pid" 2>/dev/null || true)"
            case "$oldpid" in
                ''|*[!0-9]*) ;;
                *) kill -0 "$oldpid" 2>/dev/null || {
                    log "stale lock (pid $oldpid gone); stealing"
                    rm -rf "$dir"
                    continue
                } ;;
            esac
        fi
        waited=$((waited + 1))
        if [ "$waited" -ge $((LOCK_WAIT_SECONDS * 20)) ]; then
            log "lock busy after ${LOCK_WAIT_SECONDS}s; proceeding anyway"
            return 0
        fi
        sleep 0.05
    done
    printf "%s" "$$" > "$dir/pid"
}

unlock() {
    rm -rf "$(lock_dir)"
}

# --- shell-quoted KEY='value' files (we own the format; no JSON parsing) ---

q() {
    # single-quote $1 for shell sourcing
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

# Extract one KEY='value' line without sourcing the file (never executes it).
get_kv() {
    # $1 = file, $2 = key
    [ -f "$1" ] || return 0
    sed -n "s/^$2='\\(.*\\)'$/\\1/p" "$1" 2>/dev/null | head -n 1 \
        | sed "s/'\\\\''/'/g"
}

# --- config (keys: keep_display_on, stop_on_lid_close, dopa_sock) ---

KEEP_DISPLAY_ON=false
STOP_ON_LID_CLOSE=false
DOPA_SOCK="$DEFAULT_DOPA_SOCK"

load_config() {
    KEEP_DISPLAY_ON=false
    STOP_ON_LID_CLOSE=false
    DOPA_SOCK="$DEFAULT_DOPA_SOCK"
    cfg="$(config_file)"
    v="$(get_kv "$cfg" KEEP_DISPLAY_ON)"
    [ -n "$v" ] && KEEP_DISPLAY_ON="$v"
    v="$(get_kv "$cfg" STOP_ON_LID_CLOSE)"
    [ -n "$v" ] && STOP_ON_LID_CLOSE="$v"
    v="$(get_kv "$cfg" DOPA_SOCK)"
    [ -n "$v" ] && DOPA_SOCK="$v"
    # Explicit environment wins over the file.
    if [ -n "$ENV_DOPA_SOCK" ]; then
        DOPA_SOCK="$ENV_DOPA_SOCK"
    fi
    case "$KEEP_DISPLAY_ON" in
        true) KEEP_DISPLAY_ON=true ;; *) KEEP_DISPLAY_ON=false ;;
    esac
    case "$STOP_ON_LID_CLOSE" in
        true) STOP_ON_LID_CLOSE=true ;; *) STOP_ON_LID_CLOSE=false ;;
    esac
    [ -n "$DOPA_SOCK" ] || DOPA_SOCK="$DEFAULT_DOPA_SOCK"
}

save_config() {
    mkdir -p "$(config_dir)"
    tmp="$(config_dir)/config.tmp.$$"
    {
        printf "KEEP_DISPLAY_ON=%s\n" "$(q "$KEEP_DISPLAY_ON")"
        printf "STOP_ON_LID_CLOSE=%s\n" "$(q "$STOP_ON_LID_CLOSE")"
        printf "DOPA_SOCK=%s\n" "$(q "$DOPA_SOCK")"
    } > "$tmp"
    mv "$tmp" "$(config_file)"
}

# --- state (keys: STATE, SESSION_ID, HOLDER_PID, LAST_WORKING, AGENT_COUNT, LAST_ERROR) ---

STATE=off
SESSION_ID=""
HOLDER_PID=""
LAST_WORKING=false
AGENT_COUNT=-1
LAST_ERROR=""

load_state() {
    STATE=off
    SESSION_ID=""
    HOLDER_PID=""
    LAST_WORKING=false
    AGENT_COUNT=-1
    LAST_ERROR=""
    f="$(state_file)"
    v="$(get_kv "$f" STATE)"
    [ -n "$v" ] && STATE="$v"
    SESSION_ID="$(get_kv "$f" SESSION_ID)"
    HOLDER_PID="$(get_kv "$f" HOLDER_PID)"
    v="$(get_kv "$f" LAST_WORKING)"
    [ -n "$v" ] && LAST_WORKING="$v"
    v="$(get_kv "$f" AGENT_COUNT)"
    [ -n "$v" ] && AGENT_COUNT="$v"
    LAST_ERROR="$(get_kv "$f" LAST_ERROR)"
    case "$STATE" in
        on|off|error) ;;
        *) STATE=off ;;
    esac
    case "$LAST_WORKING" in
        true) LAST_WORKING=true ;; *) LAST_WORKING=false ;;
    esac
    case "$AGENT_COUNT" in
        ''|*[!0-9-]*) AGENT_COUNT=-1 ;;
    esac
}

save_state() {
    mkdir -p "$(state_dir)"
    tmp="$(state_dir)/state.tmp.$$"
    {
        printf "STATE=%s\n" "$(q "$STATE")"
        printf "SESSION_ID=%s\n" "$(q "$SESSION_ID")"
        printf "HOLDER_PID=%s\n" "$(q "$HOLDER_PID")"
        printf "LAST_WORKING=%s\n" "$(q "$LAST_WORKING")"
        printf "AGENT_COUNT=%s\n" "$(q "$AGENT_COUNT")"
        printf "LAST_ERROR=%s\n" "$(q "$LAST_ERROR")"
    } > "$tmp"
    mv "$tmp" "$(state_file)"
}

# --- herdr CLI + plugin gate ---

herdr_bin() {
    if [ -n "${HERDR_BIN_PATH:-}" ]; then
        printf "%s" "$HERDR_BIN_PATH"
    else
        command -v herdr 2>/dev/null
    fi
}

# Run "$@" (output to $2) with a timeout; 0 = finished (any status),
# 1 = timed out (process killed). No `timeout(1)` on stock macOS.
run_timeout() {
    secs="$1"
    out="$2"
    shift 2
    "$@" >"$out" 2>/dev/null &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -ge $((secs * 10)) ]; then
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
    done
    wait "$pid" 2>/dev/null
    return 0
}

# True for herdr hook runs (actions, events, startup, panes). herdr only
# invokes hooks of enabled plugins, so a hook run is enabled by construction;
# manual CLI runs must check plugin_enabled instead.
is_hook() {
    [ -n "${HERDR_PLUGIN_EVENT:-}" ] \
        || [ -n "${HERDR_PLUGIN_ACTION_ID:-}" ] \
        || [ -n "${HERDR_PLUGIN_ENTRYPOINT_ID:-}" ]
}

# Echoes true/false/unknown. Unknown (no herdr, not installed, herdr down,
# unparseable) means "proceed with the normal flow". The --plugin filter
# returns exactly our object, so a bare enabled-field match is unambiguous.
plugin_enabled() {
    hb="$(herdr_bin || true)"
    if [ -z "$hb" ]; then
        printf "unknown"
        return 0
    fi
    gate="/tmp/hd-gate-$$"
    if ! run_timeout 8 "$gate" "$hb" plugin list --plugin "$PLUGIN_ID" --json; then
        rm -f "$gate"
        printf "unknown"
        return 0
    fi
    out="$(cat "$gate" 2>/dev/null || true)"
    rm -f "$gate"
    if printf "%s" "$out" | grep -q '"enabled"[[:space:]]*:[[:space:]]*false'; then
        printf "false"
    elif printf "%s" "$out" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true'; then
        printf "true"
    else
        printf "unknown"
    fi
}

# --- herdr observation: union over ALL session sockets ---

# Print candidate session sockets (existing files only): the default
# <root>/herdr.sock, <root>/sessions/*/herdr.sock, then HERDR_SOCKET_PATH
# itself when it lives outside the standard layout. Deterministic order.
herdr_sockets() {
    envsock="${HERDR_SOCKET_PATH:-}"
    if [ -n "$envsock" ]; then
        parent="$(dirname "$envsock")"
        grandparent="$(dirname "$parent")"
        if [ "$(basename "$grandparent")" = "sessions" ]; then
            root="$(dirname "$grandparent")"
        else
            root="$parent"
        fi
    else
        root="$HOME/.config/herdr"
    fi
    seen=""
    emit() {
        case "$seen" in
            *"|$1|"*) ;;
            *)
                seen="$seen|$1|"
                if [ -S "$1" ]; then
                    printf "%s\n" "$1"
                fi
                ;;
        esac
    }
    emit "$root/herdr.sock"
    if [ -d "$root/sessions" ]; then
        for d in "$root"/sessions/*/; do
            [ -d "$d" ] || continue
            emit "${d}herdr.sock"
        done
    fi
    if [ -n "$envsock" ]; then
        emit "$envsock"
    fi
}

# OBS_TOTAL / OBS_WORKING from every reachable session socket. Returns 0
# when at least one socket answered (even with zero agents), 1 when herdr
# is unreachable — which the caller treats as idle, never as error.
OBS_TOTAL=0
OBS_WORKING=0
observe() {
    OBS_TOTAL=0
    OBS_WORKING=0
    answered=false
    list="/tmp/hd-sockets-$$"
    : > "$list" || return 1
    herdr_sockets > "$list"
    while IFS= read -r sock; do
        [ -n "$sock" ] || continue
        resp="$(printf '%s\n' '{"id":"hd-obs","method":"agent.list","params":{}}' \
            | nc -w 5 -U "$sock" 2>/dev/null)" || continue
        [ -n "$resp" ] || continue
        answered=true
        statuses="$(printf "%s" "$resp" \
            | grep -o '"agent_status"[[:space:]]*:[[:space:]]*"[a-z]*"' \
            | sed -E 's/.*"([a-z]*)"$/\1/')"
        for st in $statuses; do
            OBS_TOTAL=$((OBS_TOTAL + 1))
            if [ "$st" = "working" ]; then
                OBS_WORKING=$((OBS_WORKING + 1))
            fi
        done
    done < "$list"
    rm -f "$list"
    if [ "$answered" = "true" ]; then
        return 0
    fi
    return 1
}

# --- dopa control socket (session owned by the holder connection) ---

dopa_hello() {
    # $1 = request id
    printf '{"id":"%s","method":"hello","params":{"apiVersion":1,"client":{"name":"%s","version":"0.1.0"}}}\n' \
        "$1" "$PLUGIN_ID"
}

# One-shot requests over a fresh connection; prints response lines.
dopa_rpc() {
    sock="$1"
    shift
    for line in "$@"; do
        printf "%s\n" "$line"
    done | nc -w 5 -U "$sock" 2>/dev/null
}

# True when session $1 is currently held by the daemon.
dopa_session_alive() {
    sid="$1"
    [ -n "$sid" ] || return 1
    resp="$(dopa_rpc "$DOPA_SOCK" "$(dopa_hello "hd-alive-$$")" \
        '{"id":"hd-status-'"$$"'","method":"status.get","params":{}}')" || return 1
    printf "%s" "$resp" | grep -F -q "\"$sid\""
}

# Start the holder: a background nc owning one session via its connection.
# A supervisor shell holds the fifo write end open so nc never sees stdin
# EOF when our sender fd closes (EOF would drop the connection and release
# the session). Echoes the session id on success.
dopa_acquire() {
    if [ "$STOP_ON_LID_CLOSE" = "true" ]; then
        if ! lid_state="$(dopa_lid_state)"; then
            log "lid state unavailable; refusing to acquire"
            return 1
        fi
        if [ "$lid_state" = "closed" ]; then
            log "lid is already closed; refusing to acquire"
            return 1
        fi
    fi
    hdir="$(holder_dir)"
    rm -rf "$hdir"
    mkdir -p "$hdir"
    {
        printf "KEEP_DISPLAY_ON=%s\n" "$(q "$KEEP_DISPLAY_ON")"
        printf "STOP_ON_LID_CLOSE=%s\n" "$(q "$STOP_ON_LID_CLOSE")"
    } >"$hdir/options"
    nc_target="$(command -v nc 2>/dev/null || true)"
    [ -n "$nc_target" ] || {
        log "nc is unavailable; refusing to acquire"
        rm -rf "$hdir"
        return 1
    }
    holder_exec="$hdir/nc-holder-$$-$RANDOM"
    ln -s "$nc_target" "$holder_exec" || {
        log "cannot create owned nc link; refusing to acquire"
        rm -rf "$hdir"
        return 1
    }
    printf "%s" "$holder_exec" >"$hdir/executable"
    mkfifo "$hdir/in"
    # Redirect the supervisor itself so command substitutions calling this
    # function see EOF after the session id is printed. nc has its own files.
    nohup sh "$HOLD_SCRIPT" "$hdir" "$DOPA_SOCK" "$STOP_ON_LID_CLOSE" "$holder_exec" \
        </dev/null >"$hdir/supervisor.out" 2>"$hdir/supervisor.err" &
    holder="$!"
    printf "%s" "$holder" > "$hdir/pid"
    # Handshake: bytes sent before the supervisor holds the fifo open are
    # lost (an unreferenced fifo discards data), so wait for `ready`.
    waited=0
    while [ ! -e "$hdir/ready" ] && [ "$waited" -lt 100 ]; do
        kill -0 "$holder" 2>/dev/null || {
            log "holder died during acquire"
            rm -rf "$hdir"
            return 1
        }
        sleep 0.05
        waited=$((waited + 1))
    done
    if [ ! -e "$hdir/ready" ]; then
        log "holder never became ready; killing it"
        if holder_process_alive "$holder"; then kill "$holder" 2>/dev/null || true; fi
        rm -rf "$hdir"
        return 1
    fi
    # O_RDWR open never blocks, even with no other writer.
    exec 3<>"$hdir/in"
    rid="hd-$$-$RANDOM"
    send_ok=true
    dopa_hello "hd-hello-$rid" >&3 || send_ok=false
    printf '{"id":"hd-acquire-%s","method":"session.acquire","params":{"options":{"keepDisplayOn":%s}}}\n' \
        "$rid" "$KEEP_DISPLAY_ON" >&3 || send_ok=false
    exec 3>&-
    if [ "$send_ok" = "false" ]; then
        log "holder vanished before acquire; giving up"
        if holder_process_alive "$holder"; then kill "$holder" 2>/dev/null || true; fi
        rm -rf "$hdir"
        return 1
    fi
    waited=0
    while [ "$waited" -lt 50 ]; do
        if grep -q '"error"' "$hdir/out" 2>/dev/null; then
            log "acquire refused: $(head -n 2 "$hdir/out" | tr '\n' ' ')"
            if holder_process_alive "$holder"; then kill "$holder" 2>/dev/null || true; fi
            rm -rf "$hdir"
            return 1
        fi
        line="$(grep -o '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$hdir/out" 2>/dev/null | head -n 1)"
        if [ -n "$line" ]; then
            sid="$(printf "%s" "$line" | sed -E 's/.*"([^"]+)"$/\1/')"
            if [ -n "$sid" ]; then
                printf "%s" "$sid"
                return 0
            fi
        fi
        if ! holder_process_alive "$holder"; then
            log "holder died during acquire"
            rm -rf "$hdir"
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    log "acquire timed out; killing holder"
    if holder_process_alive "$holder"; then kill "$holder" 2>/dev/null || true; fi
    rm -rf "$hdir"
    return 1
}

# Verify a pid against the process start time captured before hold.sh execs nc.
# A stale/reused pid must never be signalled.
holder_process_alive() {
    _holder_pid="$1"
    case "$_holder_pid" in ''|*[!0-9]*) return 1 ;; esac
    _holder_started_file="$(holder_dir)/started"
    _holder_executable_file="$(holder_dir)/executable"
    [ -f "$_holder_started_file" ] || return 1
    [ -f "$_holder_executable_file" ] || return 1
    _holder_expected_started="$(cat "$_holder_started_file" 2>/dev/null || true)"
    _holder_expected_executable="$(cat "$_holder_executable_file" 2>/dev/null || true)"
    [ -n "$_holder_expected_started" ] || return 1
    [ -n "$_holder_expected_executable" ] || return 1
    _holder_current_started="$(LC_ALL=C /bin/ps -p "$_holder_pid" -o lstart= 2>/dev/null)" \
        || return 1
    [ "$_holder_current_started" = "$_holder_expected_started" ] || return 1
    _holder_current_command="$(LC_ALL=C /bin/ps -p "$_holder_pid" -o command= 2>/dev/null)" \
        || return 1
    case "$_holder_current_command" in
        "$_holder_expected_executable"|"$_holder_expected_executable "*) return 0 ;;
        *) return 1 ;;
    esac
}

# True only for the non-zombie lid watcher that is still a child of holder $1.
holder_watcher_alive() {
    _holder_parent="$1"
    _holder_watcher_file="$(holder_dir)/watcher.pid"
    [ -f "$_holder_watcher_file" ] || return 1
    _holder_watcher="$(cat "$_holder_watcher_file" 2>/dev/null || true)"
    case "$_holder_watcher" in ''|*[!0-9]*) return 1 ;; esac
    _holder_watcher_info="$(LC_ALL=C /bin/ps -p "$_holder_watcher" -o ppid= -o state= 2>/dev/null)" \
        || return 1
    set -- $_holder_watcher_info
    [ "$#" -eq 2 ] || return 1
    [ "$1" = "$_holder_parent" ] || return 1
    case "$2" in Z*) return 1 ;; esac
    return 0
}

# End the owned session: graceful release first, then kill the holder.
# Closing the connection alone already releases server-side; release is
# best-effort on top.
dopa_release() {
    hdir="$(holder_dir)"
    [ -d "$hdir" ] || return 0
    sid="$SESSION_ID"
    if [ -f "$hdir/pid" ]; then
        holder="$(cat "$hdir/pid" 2>/dev/null || true)"
    else
        holder=""
    fi
    if holder_process_alive "$holder"; then
        if holder_watcher_alive "$holder"; then
            kill "$_holder_watcher" 2>/dev/null || true
        fi
        if [ -n "$sid" ] && [ -p "$hdir/in" ]; then
            if exec 3<>"$hdir/in" 2>/dev/null; then
                printf '{"id":"hd-release-%s-%s","method":"session.release","params":{"sessionId":"%s"}}\n' \
                    "$$" "$RANDOM" "$sid" >&3 || true
                exec 3>&-
                sleep 0.3
            fi
        fi
        if holder_process_alive "$holder"; then
            kill "$holder" 2>/dev/null || true
        fi
        waited=0
        while holder_process_alive "$holder" && [ "$waited" -lt 25 ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        if holder_process_alive "$holder"; then
            kill -KILL "$holder" 2>/dev/null || true
        fi
    fi
    rm -rf "$hdir"
}

holder_alive() {
    [ -f "$(holder_dir)/pid" ] || return 1
    pid="$(cat "$(holder_dir)/pid" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    holder_process_alive "$pid"
}

# True when the live holder was acquired with the current config. This makes
# set.sh apply both daemon and local holder options immediately by restarting
# the one owned session on the next iteration.
holder_matches_config() {
    options="$(holder_dir)/options"
    [ -f "$options" ] || return 1
    [ "$(get_kv "$options" KEEP_DISPLAY_ON)" = "$KEEP_DISPLAY_ON" ] || return 1
    [ "$(get_kv "$options" STOP_ON_LID_CLOSE)" = "$STOP_ON_LID_CLOSE" ] || return 1
    _holder_config_pid="$(cat "$(holder_dir)/pid" 2>/dev/null || true)"
    holder_process_alive "$_holder_config_pid" || return 1
    if [ "$STOP_ON_LID_CLOSE" = "true" ]; then
        holder_watcher_alive "$_holder_config_pid" || return 1
    fi
}

# --- herdr UI (best-effort; skipped silently when unreachable) ---

ui_notify() {
    # $1 = title, $2 = body (may be empty). Always succeeds.
    hb="$(herdr_bin || true)"
    [ -n "$hb" ] || return 0
    if [ -n "$2" ]; then
        "$hb" notification show "$1" --body "$2" >/dev/null 2>&1 || true
    else
        "$hb" notification show "$1" >/dev/null 2>&1 || true
    fi
    return 0
}

ui_pane_id() {
    if [ -n "${HERDR_PANE_ID:-}" ]; then
        printf "%s" "$HERDR_PANE_ID"
        return 0
    fi
    if [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
        printf "%s" "$HERDR_PLUGIN_CONTEXT_JSON" \
            | grep -o '"[A-Za-z0-9_.-]*:p[A-Za-z0-9_.-]*"' | head -n 1 | tr -d '"'
        return 0
    fi
    return 1
}

ui_metadata() {
    # $1 = dopa state token, $2 = agent count (or ?). Always succeeds.
    hb="$(herdr_bin || true)"
    [ -n "$hb" ] || return 0
    pane="$(ui_pane_id)" || return 0
    [ -n "$pane" ] || return 0
    "$hb" pane report-metadata "$pane" --source "$PLUGIN_ID" \
        --title "dopa sleep guard" \
        --token "dopa=$1" --token "agents=$2" \
        --ttl-ms 600000 >/dev/null 2>&1 || true
    return 0
}

ui_transition() {
    # $1 = previous state, $2 = new state, $3 = session id or empty,
    # $4 = error text or empty
    [ "$1" = "$2" ] && return 0
    agents="$OBS_WORKING"
    case "$2" in
        on)
            if [ -n "$3" ]; then
                ui_notify "dopa guard: keeping Mac awake" \
                    "Agents working; owned dopa session $3."
            else
                ui_notify "dopa guard: keeping Mac awake" \
                    "Agents working; owned dopa session started."
            fi
            ui_metadata "guarding" "$agents"
            ;;
        off)
            ui_notify "dopa guard: idle" "Agents idle; owned dopa session ended."
            ui_metadata "idle" "$agents"
            ;;
        error)
            ui_notify "dopa guard: error" "${4:-see status}"
            ui_metadata "error" "$agents"
            ;;
    esac
}

# --- one locked iteration: load -> observe -> transition -> save ---

do_iterate() {
    lock
    load_config
    load_state
    PREV_STATE="$STATE"
    if observe; then
        WORKING="$OBS_WORKING"
        AGENTS="$OBS_TOTAL"
    else
        log "herdr unreachable; treating as no working agents."
        WORKING=0
        AGENTS="$AGENT_COUNT"
        case "$AGENTS" in
            ''|*[!0-9-]*) AGENTS=0 ;;
        esac
        [ "$AGENTS" -ge 0 ] 2>/dev/null || AGENTS=0
    fi
    if [ "$WORKING" -gt 0 ]; then
        if [ "$STATE" = "error" ]; then
            # Error carries no live session (it is only entered when no
            # session was acquired): reset and resume the normal flow.
            SESSION_ID=""
            HOLDER_PID=""
            STATE=off
        fi
        if [ "$STATE" = "off" ]; then
            if sid="$(dopa_acquire)"; then
                SESSION_ID="$sid"
                HOLDER_PID="$(cat "$(holder_dir)/pid" 2>/dev/null || true)"
                STATE=on
                LAST_ERROR=""
                log "Transition: off -> on (working=$WORKING)."
            else
                SESSION_ID=""
                HOLDER_PID=""
                STATE=error
                LAST_ERROR="dopa acquire failure"
                log "Transition off -> on failed; entering error state."
            fi
        elif ! dopa_session_alive "$SESSION_ID" || ! holder_matches_config; then
            log "Owned dopa session is gone or its options changed; restarting it."
            dopa_release
            if sid="$(dopa_acquire)"; then
                SESSION_ID="$sid"
                HOLDER_PID="$(cat "$(holder_dir)/pid" 2>/dev/null || true)"
                LAST_ERROR=""
                log "Restarted owned dopa session."
            else
                SESSION_ID=""
                HOLDER_PID=""
                STATE=error
                LAST_ERROR="dopa restart failure"
                log "Restart failed; entering error state."
            fi
        fi
    else
        if [ -n "$SESSION_ID" ] || holder_alive; then
            dopa_release
            log "Agents idle; ended owned dopa session."
        else
            log "Agents idle; nothing to stop."
        fi
        SESSION_ID=""
        HOLDER_PID=""
        STATE=off
        LAST_ERROR=""
    fi
    LAST_WORKING=false
    [ "$WORKING" -gt 0 ] && LAST_WORKING=true
    AGENT_COUNT="$AGENTS"
    save_state
    unlock
    ui_transition "$PREV_STATE" "$STATE" "$SESSION_ID" "$LAST_ERROR"
}

# Manual run while the plugin is disabled: never hold dopa — end the owned
# session instead.
reconcile_disabled() {
    lock
    load_state
    if [ -n "$SESSION_ID" ] || holder_alive; then
        dopa_release
        printf "Plugin disabled; ended owned dopa session.\n"
    else
        printf "Plugin disabled; nothing held.\n"
    fi
    SESSION_ID=""
    HOLDER_PID=""
    STATE=off
    LAST_ERROR=""
    save_state
    unlock
}

# True when this manual command must not observe (plugin disabled).
manual_blocked() {
    ! is_hook && [ "$(plugin_enabled)" = "false" ]
}
