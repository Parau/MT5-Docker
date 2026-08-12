#!/bin/bash
# MT5 terminal lifecycle wrapper: preserve LiveUpdate handoff without wineserver -k.
#
# Data flow: invoked by entrypoint after Wine/display bootstrap; owns terminal spawn,
# LiveUpdate detection via /proc, and post-update relaunch monitoring only.
# Limitations: no crash autorestart, no bridge/VNC/Wine bootstrap, no wineserver -k.
set -Eeuo pipefail

readonly LOG_PREFIX="[MT5-LIFECYCLE]"
readonly EXIT_UPDATE_TIMEOUT=70
readonly EXIT_RELAUNCH_NOT_OBSERVED=71
readonly EXIT_CLASSIFICATION_INCONSISTENT=72
readonly EXIT_TERMINAL_DISAPPEARED=73
readonly EXIT_UNEXPECTED_EXIT=74

MT5_EXE="${MT5_EXE:-${WINEPREFIX:-/config/.wine}/drive_c/Program Files/MetaTrader 5/terminal64.exe}"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
MT5_HANDOFF_GRACE_SECONDS="${MT5_HANDOFF_GRACE_SECONDS:-8}"
MT5_UPDATE_TIMEOUT_SECONDS="${MT5_UPDATE_TIMEOUT_SECONDS:-180}"
MT5_RELAUNCH_STABLE_SECONDS="${MT5_RELAUNCH_STABLE_SECONDS:-5}"
MT5_POLL_SECONDS="${MT5_POLL_SECONDS:-1}"

STOP_REQUESTED=0
CURRENT_STATE="INIT"

log() {
    echo "${LOG_PREFIX} $*"
}

set_state() {
    CURRENT_STATE="$1"
    shift
    if [ $# -gt 0 ]; then
        log "state=${CURRENT_STATE} $*"
    else
        log "state=${CURRENT_STATE}"
    fi
}

on_term() {
    STOP_REQUESTED=1
    set_state "STOPPING" "signal=${1:-TERM}"
    exit 0
}

trap 'on_term INT' INT
trap 'on_term TERM' TERM

read_cmdline() {
    local pid="$1"
    local proc_cmdline="/proc/${pid}/cmdline"
    if [ ! -r "$proc_cmdline" ]; then
        return 1
    fi
    tr '\0' ' ' < "$proc_cmdline" 2>/dev/null || true
}

is_terminal64_cmdline() {
    local lower="$1"
    case "$lower" in
        *terminal64.exe*) return 0 ;;
        *) return 1 ;;
    esac
}

is_updater_cmdline() {
    local lower="$1"
    if ! is_terminal64_cmdline "$lower"; then
        return 1
    fi
    case "$lower" in
        */update*|*"/update"*|*liveupdate*) return 0 ;;
        *) return 1 ;;
    esac
}

is_normal_terminal_cmdline() {
    local lower="$1"
    if ! is_terminal64_cmdline "$lower"; then
        return 1
    fi
    if is_updater_cmdline "$lower"; then
        return 1
    fi
    return 0
}

collect_pids() {
    local kind="$1"
    local -n _out="$2"
    _out=()
    local proc pid cmd lower
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        cmd="$(read_cmdline "$pid" || true)"
        [ -n "$cmd" ] || continue
        lower="${cmd,,}"
        case "$kind" in
            updater)
                if is_updater_cmdline "$lower"; then
                    _out+=("$pid")
                fi
                ;;
            terminal)
                if is_normal_terminal_cmdline "$lower"; then
                    _out+=("$pid")
                fi
                ;;
        esac
    done
}

pids_to_csv() {
    local joined=""
    local pid
    for pid in "$@"; do
        if [ -z "$joined" ]; then
            joined="$pid"
        else
            joined="${joined},${pid}"
        fi
    done
    printf '%s' "$joined"
}

log_candidates_once() {
    local label="$1"
    local updater_pids=()
    local terminal_pids=()
    collect_pids updater updater_pids
    collect_pids terminal terminal_pids
    log "${label} updater_pids=$(pids_to_csv "${updater_pids[@]}") terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
}

wait_seconds() {
    local seconds="$1"
    local end=$((SECONDS + seconds))
    while [ "$SECONDS" -lt "$end" ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi
        sleep "$MT5_POLL_SECONDS"
    done
    return 0
}

wait_for_stable_terminals() {
    local required_seconds="$1"
    local stable_for=0
    local terminal_pids=()

    while [ "$stable_for" -lt "$required_seconds" ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi

        collect_pids terminal terminal_pids
        if [ "${#terminal_pids[@]}" -eq 0 ]; then
            stable_for=0
        else
            stable_for=$((stable_for + MT5_POLL_SECONDS))
        fi
        sleep "$MT5_POLL_SECONDS"
    done
    return 0
}

wait_for_updater_clear() {
    local timeout_seconds="$1"
    local deadline=$((SECONDS + timeout_seconds))
    local updater_pids=()
    local terminal_pids=()
    local last_log_at=0

    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi

        collect_pids updater updater_pids
        collect_pids terminal terminal_pids

        if [ "$SECONDS" -ge "$((last_log_at + 5))" ]; then
            log "state=UPDATING updater_pids=$(pids_to_csv "${updater_pids[@]}") terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
            last_log_at=$SECONDS
        fi

        if [ "${#updater_pids[@]}" -eq 0 ] && [ "${#terminal_pids[@]}" -gt 0 ]; then
            return 0
        fi

        sleep "$MT5_POLL_SECONDS"
    done

    return 1
}

monitor_running_relaunched() {
    local terminal_pids=()
    local updater_pids=()

    while [ "$STOP_REQUESTED" -eq 0 ]; do
        collect_pids terminal terminal_pids
        if [ "${#terminal_pids[@]}" -gt 0 ]; then
            sleep "$MT5_POLL_SECONDS"
            continue
        fi

        set_state "HANDOFF_DETECT" "reason=terminal_disappeared"
        if ! wait_seconds "$MT5_HANDOFF_GRACE_SECONDS"; then
            return 1
        fi

        collect_pids updater updater_pids
        collect_pids terminal terminal_pids
        if [ "${#updater_pids[@]}" -gt 0 ]; then
            set_state "UPDATING" "updater_pids=$(pids_to_csv "${updater_pids[@]}")"
            if ! wait_for_updater_clear "$MT5_UPDATE_TIMEOUT_SECONDS"; then
                log "state=FAILED reason=update_timeout"
                exit "$EXIT_UPDATE_TIMEOUT"
            fi
            if ! wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
                log "state=FAILED reason=relaunch_not_observed"
                exit "$EXIT_RELAUNCH_NOT_OBSERVED"
            fi
            set_state "RUNNING_RELAUNCHED"
            continue
        fi

        if [ "${#terminal_pids[@]}" -gt 0 ]; then
            set_state "RUNNING_RELAUNCHED"
            continue
        fi

        log "state=FAILED reason=terminal_disappeared_without_update"
        exit "$EXIT_TERMINAL_DISAPPEARED"
    done
}

if [ ! -f "$MT5_EXE" ]; then
    log "state=FAILED reason=mt5_exe_missing path=${MT5_EXE}"
    exit 1
fi

set_state "STARTING" "exe=${MT5_EXE}"

wine "$MT5_EXE" $MT5_CMD_OPTIONS &
child_pid=$!
set_state "RUNNING" "child_pid=${child_pid}"

set +e
wait "$child_pid"
child_status=$?
set -e

log "child_exit code=${child_status}"

set_state "HANDOFF_DETECT" "grace_seconds=${MT5_HANDOFF_GRACE_SECONDS}"
if ! wait_seconds "$MT5_HANDOFF_GRACE_SECONDS"; then
    exit 0
fi

updater_pids=()
terminal_pids=()
collect_pids updater updater_pids
collect_pids terminal terminal_pids
log_candidates_once "handoff_scan"

if [ "${#updater_pids[@]}" -gt 0 ]; then
    set_state "UPDATING" "updater_pids=$(pids_to_csv "${updater_pids[@]}")"
    if ! wait_for_updater_clear "$MT5_UPDATE_TIMEOUT_SECONDS"; then
        log "state=FAILED reason=update_timeout"
        exit "$EXIT_UPDATE_TIMEOUT"
    fi
    if ! wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
        log "state=FAILED reason=relaunch_not_observed"
        exit "$EXIT_RELAUNCH_NOT_OBSERVED"
    fi
    set_state "RUNNING_RELAUNCHED"
    monitor_running_relaunched
    exit 0
fi

if [ "${#terminal_pids[@]}" -gt 0 ]; then
    if wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
        set_state "RUNNING_RELAUNCHED" "terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
        monitor_running_relaunched
        exit 0
    fi
fi

if [ "$child_status" -ne 0 ]; then
    log "state=FAILED reason=child_nonzero_exit code=${child_status}"
    exit "$child_status"
fi

log "state=FAILED reason=no_updater_or_terminal_after_handoff code=${EXIT_UNEXPECTED_EXIT}"
exit "$EXIT_UNEXPECTED_EXIT"
