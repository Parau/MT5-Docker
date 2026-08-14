#!/bin/bash
# MT5 terminal lifecycle wrapper: preserve LiveUpdate handoff without wineserver -k.
#
# Data flow: still owned by CMD after python-bootstrap; entrypoint waits this
# process for container liveness, then start_bridge.sh runs in background.
# LiveUpdate handoff is supported (updater / skipupdate → RUNNING_RELAUNCHED).
# Crash autorestart does not exist: one wine spawn, then handoff or fatal exit.
# RUNNING is process/lifecycle liveness only, not MT5/API/RPyC readiness.
# TERM/INT currently stop the wrapper with exit 0 and do not forward to the
# Wine child; caller entrypoint cleanup still runs wineserver -k on EXIT.
# Promotion to s6 longrun requires an explicit exit/shutdown policy first.
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

is_relaunch_marker_cmdline() {
    local lower="$1"
    case "$lower" in
        *skipupdate*) return 0 ;;
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

lifecycle_sleep() {
    sleep "$1"
}

scan_process_candidates() {
    local -n _updaters="$1"
    local -n _terminals="$2"
    local -n _relaunch="$3"

    _updaters=()
    _terminals=()
    _relaunch=()

    local proc pid cmd lower
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        cmd="$(read_cmdline "$pid" || true)"
        [ -n "$cmd" ] || continue
        lower="${cmd,,}"

        if is_updater_cmdline "$lower"; then
            _updaters+=("$pid")
            continue
        fi

        if is_normal_terminal_cmdline "$lower"; then
            _terminals+=("$pid")
            if is_relaunch_marker_cmdline "$lower"; then
                _relaunch+=("$pid")
            fi
        fi
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

record_handoff_poll_evidence() {
    local -n _updater_pids="$1"
    local -n _terminal_pids="$2"
    local -n _relaunch_pids="$3"
    local -n _updater_seen="$4"
    local -n _relaunch_marker_seen="$5"
    local -n _updating_logged="$6"
    local -n _relaunch_logged="$7"

    if [ "${#_updater_pids[@]}" -gt 0 ]; then
        _updater_seen=1
        if [ "$_updating_logged" -eq 0 ]; then
            set_state "UPDATING" "updater_pids=$(pids_to_csv "${_updater_pids[@]}")"
            _updating_logged=1
        fi
    fi

    if [ "${#_relaunch_pids[@]}" -gt 0 ]; then
        _relaunch_marker_seen=1
        if [ "$_relaunch_logged" -eq 0 ]; then
            log "handoff_evidence relaunch_marker_seen=1 terminal_pids=$(pids_to_csv "${_relaunch_pids[@]}")"
            _relaunch_logged=1
        fi
    fi
}

wait_for_stable_terminals() {
    local required_seconds="$1"
    local stable_for=0
    local updater_pids=()
    local terminal_pids=()
    local relaunch_pids=()

    while [ "$stable_for" -lt "$required_seconds" ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi

        scan_process_candidates updater_pids terminal_pids relaunch_pids
        if [ "${#terminal_pids[@]}" -eq 0 ]; then
            stable_for=0
        else
            stable_for=$((stable_for + MT5_POLL_SECONDS))
        fi
        lifecycle_sleep "$MT5_POLL_SECONDS"
    done
    return 0
}

wait_for_updater_phase_complete() {
    local timeout_seconds="$1"
    local deadline=$((SECONDS + timeout_seconds))
    local updater_pids=()
    local terminal_pids=()
    local relaunch_pids=()
    local last_log_at=0

    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi

        scan_process_candidates updater_pids terminal_pids relaunch_pids

        if [ "${#updater_pids[@]}" -gt 0 ]; then
            if [ "$SECONDS" -ge "$((last_log_at + 5))" ]; then
                log "state=UPDATING updater_pids=$(pids_to_csv "${updater_pids[@]}") terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
                last_log_at=$SECONDS
            fi
        elif [ "${#terminal_pids[@]}" -gt 0 ]; then
            return 0
        fi

        lifecycle_sleep "$MT5_POLL_SECONDS"
    done

    scan_process_candidates updater_pids terminal_pids relaunch_pids
    if [ "${#updater_pids[@]}" -gt 0 ]; then
        log "state=FAILED reason=update_timeout"
        return "$EXIT_UPDATE_TIMEOUT"
    fi

    if [ "${#terminal_pids[@]}" -eq 0 ]; then
        log "state=FAILED reason=relaunch_not_observed"
        return "$EXIT_RELAUNCH_NOT_OBSERVED"
    fi

    return 0
}

handle_handoff() {
    local child_status="${1:-0}"
    local reason="${2:-child_exit}"

    local updater_seen=0
    local relaunch_marker_seen=0
    local updating_logged=0
    local relaunch_logged=0
    local grace_elapsed=0
    local updater_pids=()
    local terminal_pids=()
    local relaunch_pids=()

    set_state "HANDOFF_DETECT" "reason=${reason} grace_seconds=${MT5_HANDOFF_GRACE_SECONDS}"

    while [ "$grace_elapsed" -lt "$MT5_HANDOFF_GRACE_SECONDS" ] && [ "$updater_seen" -eq 0 ]; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi

        scan_process_candidates updater_pids terminal_pids relaunch_pids
        record_handoff_poll_evidence updater_pids terminal_pids relaunch_pids \
            updater_seen relaunch_marker_seen updating_logged relaunch_logged

        if [ "$updater_seen" -eq 1 ]; then
            break
        fi

        if [ "$relaunch_marker_seen" -eq 1 ] && [ "${#terminal_pids[@]}" -gt 0 ]; then
            if wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
                set_state "RUNNING_RELAUNCHED" "evidence=skipupdate_fallback terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
                return 0
            fi
            return "$EXIT_RELAUNCH_NOT_OBSERVED"
        fi

        lifecycle_sleep "$MT5_POLL_SECONDS"
        grace_elapsed=$((grace_elapsed + MT5_POLL_SECONDS))
    done

    if [ "$updater_seen" -eq 1 ]; then
        local phase_status=0
        wait_for_updater_phase_complete "$MT5_UPDATE_TIMEOUT_SECONDS" || phase_status=$?
        if [ "$phase_status" -ne 0 ]; then
            return "$phase_status"
        fi
        if ! wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
            log "state=FAILED reason=relaunch_not_observed"
            return "$EXIT_RELAUNCH_NOT_OBSERVED"
        fi
        scan_process_candidates updater_pids terminal_pids relaunch_pids
        set_state "RUNNING_RELAUNCHED" "evidence=updater_seen terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
        return 0
    fi

    scan_process_candidates updater_pids terminal_pids relaunch_pids
    record_handoff_poll_evidence updater_pids terminal_pids relaunch_pids \
        updater_seen relaunch_marker_seen updating_logged relaunch_logged

    if [ "$relaunch_marker_seen" -eq 1 ] && [ "${#terminal_pids[@]}" -gt 0 ]; then
        if wait_for_stable_terminals "$MT5_RELAUNCH_STABLE_SECONDS"; then
            set_state "RUNNING_RELAUNCHED" "evidence=skipupdate_fallback terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
            return 0
        fi
        log "state=FAILED reason=relaunch_not_observed"
        return "$EXIT_RELAUNCH_NOT_OBSERVED"
    fi

    if [ "${#terminal_pids[@]}" -gt 0 ]; then
        log "state=FAILED reason=terminal_without_update_evidence terminal_pids=$(pids_to_csv "${terminal_pids[@]}")"
        return "$EXIT_CLASSIFICATION_INCONSISTENT"
    fi

    if [ "$child_status" -ne 0 ]; then
        log "state=FAILED reason=child_nonzero_exit code=${child_status}"
        return "$child_status"
    fi

    log "state=FAILED reason=no_updater_or_terminal_after_handoff code=${EXIT_UNEXPECTED_EXIT}"
    return "$EXIT_UNEXPECTED_EXIT"
}

monitor_running_relaunched() {
    local updater_pids=()
    local terminal_pids=()
    local relaunch_pids=()

    while [ "$STOP_REQUESTED" -eq 0 ]; do
        scan_process_candidates updater_pids terminal_pids relaunch_pids
        if [ "${#terminal_pids[@]}" -gt 0 ]; then
            lifecycle_sleep "$MT5_POLL_SECONDS"
            continue
        fi

        local handoff_status=0
        handle_handoff 0 "terminal_disappeared" || handoff_status=$?
        if [ "$handoff_status" -ne 0 ]; then
            return "$handoff_status"
        fi
    done
    return 0
}

main() {
    trap 'on_term INT' INT
    trap 'on_term TERM' TERM

    if [ ! -f "$MT5_EXE" ]; then
        log "state=FAILED reason=mt5_exe_missing path=${MT5_EXE}"
        exit 1
    fi

    set_state "STARTING" "exe=${MT5_EXE}"

    wine "$MT5_EXE" $MT5_CMD_OPTIONS &
    local child_pid=$!
    set_state "RUNNING" "child_pid=${child_pid}"

    set +e
    wait "$child_pid"
    local child_status=$?
    set -e

    log "child_exit code=${child_status}"

    local handoff_status=0
    handle_handoff "$child_status" "child_exit" || handoff_status=$?
    if [ "$handoff_status" -ne 0 ]; then
        exit "$handoff_status"
    fi

    local monitor_status=0
    monitor_running_relaunched || monitor_status=$?
    exit "$monitor_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
