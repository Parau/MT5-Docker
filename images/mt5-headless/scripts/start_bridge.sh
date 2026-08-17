#!/bin/bash
# RPyC bridge lifecycle wrapper: local MT5 process gate then one Wine Python child.
#
# Data flow: owned by the s6 longrun `bridge` (bridge/run execs this script).
# RUN_BRIDGE gating is stage2-hook owned; this script never reads RUN_BRIDGE.
# Admission gate (NOT s6 readiness, NOT broker connectivity) = the same
# verified normal MT5 process identity (PID + /proc stat starttime) remains
# valid for the stability window with no verified updater active, then one
# server launch. Shell/python helpers that only mention terminal64.exe are
# rejected via /proc exe basename (Wine loader), not cmdline substring.
# The server child is spawn+wait, tracked as CURRENT_BRIDGE_CHILD_PID.
# s6 TERMs this wrapper; the wrapper TERMs only its current child. bridge/finish
# is the hard quiescence net (old PGID) before any supervised restart.
# Consumers: s6-supervise via bridge/run. Input: WINEPREFIX, RPYC_PORT, BRIDGE_DIR.
# Premises: BRIDGE_WAIT_SECONDS is a warning interval while waiting; the wrapper
# never launches the server without a stable normal terminal, never exits 0
# just to retry the wait, and does not consume the failure budget by waiting.
# One server execution, no internal restart (s6 restarts). TERM/INT always
# forward TERM to the child when one exists; timeout yields fallback_required
# then wrapper exit 0. Spawn→PID registration is race-closed via SPAWN_IN_PROGRESS.
# Policy (04K-B): this gate is wrapper-local only — it is not notification-fd,
# not mt5-ready, and must not block s6-rc stage2. Operational health after start
# remains Docker HEALTHCHECK via RPyC.
# Limitations: the real server process still performs the Python API attach;
# observing a terminal first reduces ownership ambiguity but is not a stronger
# guarantee than the official API. No SIGKILL/pkill/wineserver-k here (finish
# may SIGKILL the old bridge PGID only).
set -Eeuo pipefail

readonly LOG_PREFIX="[BRIDGE-LIFECYCLE]"

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

BRIDGE_DIR="${BRIDGE_DIR:-/opt/bridge}"
RPYC_PORT="${RPYC_PORT:-18812}"
BRIDGE_PROC_ROOT="${BRIDGE_PROC_ROOT:-/proc}"
# BRIDGE_RETRY_SECONDS is a deprecated alias for BRIDGE_PROCESS_POLL_SECONDS.
BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"
BRIDGE_PROCESS_POLL_SECONDS="${BRIDGE_PROCESS_POLL_SECONDS:-${BRIDGE_RETRY_SECONDS:-1}}"
BRIDGE_MT5_PROCESS_STABLE_SECONDS="${BRIDGE_MT5_PROCESS_STABLE_SECONDS:-5}"
BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}"
BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}"

CURRENT_BRIDGE_CHILD_PID=""
CURRENT_BRIDGE_CHILD_KIND=""
STOP_REQUESTED=0
SHUTDOWN_IN_PROGRESS=0
SPAWN_IN_PROGRESS=0
PENDING_STOP_SIGNAL=""

# Scan output (set by scan_mt5_processes; not via command substitution).
SCAN_UPDATER_COUNT=0
SCAN_NORMAL_COUNT=0
SCAN_VERIFIED_NORMAL_IDS=()
SCAN_VERIFIED_NORMAL_PIDS=()

log() {
    echo "${LOG_PREFIX} $*"
}

parse_positive_int() {
    local raw="${1:-}"
    local default="$2"
    local name="$3"
    local n
    case "${raw}" in
        ''|*[!0-9]*)
            echo "${LOG_PREFIX} warning: invalid ${name}=${raw:-<empty>} using default=${default}" >&2
            printf '%s\n' "${default}"
            return 0
            ;;
    esac
    n="$((10#${raw}))"
    if [ "${n}" -lt 1 ]; then
        echo "${LOG_PREFIX} warning: invalid ${name}=${raw} using default=${default}" >&2
        printf '%s\n' "${default}"
        return 0
    fi
    printf '%s\n' "${n}"
}

BRIDGE_WAIT_SECONDS="$(parse_positive_int "${BRIDGE_WAIT_SECONDS}" 180 BRIDGE_WAIT_SECONDS)"
BRIDGE_PROCESS_POLL_SECONDS="$(parse_positive_int "${BRIDGE_PROCESS_POLL_SECONDS}" 1 BRIDGE_PROCESS_POLL_SECONDS)"
BRIDGE_MT5_PROCESS_STABLE_SECONDS="$(parse_positive_int "${BRIDGE_MT5_PROCESS_STABLE_SECONDS}" 5 BRIDGE_MT5_PROCESS_STABLE_SECONDS)"

# Test seam: invoked after child spawn + $! capture, before PID registration.
# Production default is a no-op. Deterministic race tests may block here while
# SPAWN_IN_PROGRESS=1 so TERM can arrive before CURRENT_BRIDGE_CHILD_PID is set.
bridge_after_spawn_before_register() {
    :
}

process_is_active() {
    local pid="${1:-}"
    case "${pid}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "${pid}" -le 1 ] || [ "${pid}" -eq "$$" ]; then
        return 1
    fi
    local status_file="/proc/${pid}/status"
    if [ ! -r "${status_file}" ]; then
        return 1
    fi
    local state
    state="$(awk '/^State:/ { print $2; exit }' "${status_file}" 2>/dev/null || true)"
    if [ "${state}" = "Z" ]; then
        return 1
    fi
    kill -0 "${pid}" 2>/dev/null || return 1
    return 0
}

bridge_kill_term() {
    local pid="$1"
    kill -TERM "${pid}" 2>/dev/null || true
}

reap_bridge_child() {
    local pid="${1:-}"
    if [ -z "${pid}" ]; then
        return 0
    fi
    if process_is_active "${pid}"; then
        return 0
    fi
    wait "${pid}" 2>/dev/null || true
}

clear_bridge_child() {
    CURRENT_BRIDGE_CHILD_PID=""
    CURRENT_BRIDGE_CHILD_KIND=""
}

shutdown_bridge_child() {
    local source_signal="${1:-TERM}"
    local child_signal="TERM"
    local timeout_seconds="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS}"
    local poll_seconds="${BRIDGE_SHUTDOWN_POLL_SECONDS}"
    local pid="${CURRENT_BRIDGE_CHILD_PID:-}"
    local kind="${CURRENT_BRIDGE_CHILD_KIND:-}"
    local elapsed=0

    log "state=STOPPING source_signal=${source_signal} child_signal=${child_signal} child_pid=${pid:-none} child_kind=${kind:-none}"

    if ! process_is_active "${pid}"; then
        reap_bridge_child "${pid}"
        clear_bridge_child
        log "shutdown_result=completed"
        return 0
    fi

    bridge_kill_term "${pid}"

    while [ "${elapsed}" -lt "${timeout_seconds}" ]; do
        if ! process_is_active "${pid}"; then
            reap_bridge_child "${pid}"
            clear_bridge_child
            log "shutdown_result=completed"
            return 0
        fi
        sleep "${poll_seconds}" || true
        elapsed=$((elapsed + poll_seconds))
    done

    log "shutdown_result=fallback_required reason=timeout child_pid=${pid} child_kind=${kind}"
    return 1
}

on_term() {
    local source_signal="${1:-TERM}"
    if [ "${SHUTDOWN_IN_PROGRESS}" -eq 1 ]; then
        return 0
    fi
    if [ "${SPAWN_IN_PROGRESS}" -eq 1 ]; then
        STOP_REQUESTED=1
        PENDING_STOP_SIGNAL="${source_signal}"
        log "state=STOP_DEFERRED reason=spawn_in_progress"
        return 0
    fi
    SHUTDOWN_IN_PROGRESS=1
    trap '' INT TERM
    STOP_REQUESTED=1
    shutdown_bridge_child "${source_signal}" || true
    exit 0
}

register_bridge_child() {
    local pid="$1"
    local kind="$2"
    CURRENT_BRIDGE_CHILD_PID="${pid}"
    CURRENT_BRIDGE_CHILD_KIND="${kind}"
    SPAWN_IN_PROGRESS=0
    if [ -n "${PENDING_STOP_SIGNAL}" ]; then
        local pending="${PENDING_STOP_SIGNAL}"
        PENDING_STOP_SIGNAL=""
        on_term "${pending}"
    fi
}

read_bridge_cmdline() {
    local pid="$1"
    local proc_cmdline="${BRIDGE_PROC_ROOT}/${pid}/cmdline"
    if [ ! -r "${proc_cmdline}" ]; then
        return 1
    fi
    tr '\0' ' ' < "${proc_cmdline}" 2>/dev/null || true
}

bridge_is_terminal64_cmdline() {
    local lower="$1"
    case "$lower" in
        *terminal64.exe*) return 0 ;;
        *) return 1 ;;
    esac
}

bridge_is_updater_cmdline() {
    local lower="$1"
    if ! bridge_is_terminal64_cmdline "$lower"; then
        return 1
    fi
    case "$lower" in
        */update*|*"/update"*|*liveupdate*) return 0 ;;
        *) return 1 ;;
    esac
}

bridge_is_normal_terminal_cmdline() {
    local lower="$1"
    if ! bridge_is_terminal64_cmdline "$lower"; then
        return 1
    fi
    if bridge_is_updater_cmdline "$lower"; then
        return 1
    fi
    return 0
}

bridge_proc_is_zombie() {
    local pid="$1"
    local status_file="${BRIDGE_PROC_ROOT}/${pid}/status"
    if [ ! -r "${status_file}" ]; then
        return 1
    fi
    local state
    state="$(awk '/^State:/ { print $2; exit }' "${status_file}" 2>/dev/null || true)"
    [ "${state}" = "Z" ]
}

# /proc/<pid>/stat field 22 (starttime) sits after comm, which is parenthesized
# and may contain spaces. Parse from the last ')' so field 3 of the original
# record (state) is the first non-empty token and starttime is the 20th.
bridge_proc_starttime() {
    local pid="$1"
    local stat_file="${BRIDGE_PROC_ROOT}/${pid}/stat"
    if [ ! -r "${stat_file}" ]; then
        return 1
    fi
    awk '{
        start = 0
        for (i = length($0); i > 0; i--) {
            if (substr($0, i, 1) == ")") {
                start = i + 1
                break
            }
        }
        if (start == 0) {
            exit 1
        }
        n = split(substr($0, start), a, " ")
        idx = 0
        for (i = 1; i <= n; i++) {
            if (a[i] != "") {
                idx++
                if (idx == 20) {
                    print a[i]
                    exit 0
                }
            }
        }
        exit 1
    }' "${stat_file}"
}

bridge_process_identity() {
    local pid="$1"
    local starttime
    starttime="$(bridge_proc_starttime "${pid}")" || return 1
    case "${starttime}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s:%s' "${pid}" "${starttime}"
}

bridge_proc_exe_basename() {
    local pid="$1"
    local exe_link="${BRIDGE_PROC_ROOT}/${pid}/exe"
    if [ ! -L "${exe_link}" ] && [ ! -e "${exe_link}" ]; then
        return 1
    fi
    if [ -L "${exe_link}" ] && [ ! -e "${exe_link}" ]; then
        return 1
    fi
    local path
    path="$(readlink "${exe_link}" 2>/dev/null || true)"
    [ -n "${path}" ] || return 1
    local base="${path##*/}"
    base="${base%% (deleted)}"
    [ -n "${base}" ] || return 1
    printf '%s' "${base}"
}

bridge_proc_comm() {
    local pid="$1"
    local comm_file="${BRIDGE_PROC_ROOT}/${pid}/comm"
    if [ ! -r "${comm_file}" ]; then
        printf ''
        return 0
    fi
    tr -d '\0\n' < "${comm_file}" 2>/dev/null || true
}

# Textual terminal64 classifier plus Wine/MT5 /proc metadata. Observed on
# AMP/Tickmill/XP: exe basename wine64-preloader. Helpers (bash/python) that
# only mention terminal64.exe are rejected. comm=main is not required.
bridge_is_verified_mt5_process() {
    local pid="$1"
    local lower="$2"
    if ! bridge_is_terminal64_cmdline "${lower}"; then
        return 1
    fi
    if bridge_proc_is_zombie "${pid}"; then
        return 1
    fi
    local exe_base comm
    exe_base="$(bridge_proc_exe_basename "${pid}")" || return 1
    comm="$(bridge_proc_comm "${pid}")"
    case "${exe_base}" in
        bash|sh|dash|python|python3) return 1 ;;
    esac
    case "${comm}" in
        bash|sh|python|python3) return 1 ;;
    esac
    case "${exe_base}" in
        wine64-preloader|wine-preloader|wine64|wine) return 0 ;;
        *) return 1 ;;
    esac
}

scan_mt5_processes() {
    SCAN_UPDATER_COUNT=0
    SCAN_NORMAL_COUNT=0
    SCAN_VERIFIED_NORMAL_IDS=()
    SCAN_VERIFIED_NORMAL_PIDS=()

    local had_nullglob=0
    if shopt -q nullglob; then
        had_nullglob=1
    else
        had_nullglob=0
    fi
    shopt -s nullglob

    local proc pid cmd lower identity
    for proc in "${BRIDGE_PROC_ROOT}"/[0-9]*; do
        pid="${proc##*/}"
        cmd="$(read_bridge_cmdline "${pid}" || true)"
        [ -n "${cmd}" ] || continue
        lower="${cmd,,}"
        if ! bridge_is_terminal64_cmdline "${lower}"; then
            continue
        fi
        if ! bridge_is_verified_mt5_process "${pid}" "${lower}"; then
            continue
        fi
        identity="$(bridge_process_identity "${pid}" || true)"
        [ -n "${identity}" ] || continue
        if bridge_is_updater_cmdline "${lower}"; then
            SCAN_UPDATER_COUNT=$((SCAN_UPDATER_COUNT + 1))
            continue
        fi
        if bridge_is_normal_terminal_cmdline "${lower}"; then
            SCAN_NORMAL_COUNT=$((SCAN_NORMAL_COUNT + 1))
            SCAN_VERIFIED_NORMAL_IDS+=("${identity}")
            SCAN_VERIFIED_NORMAL_PIDS+=("${pid}")
        fi
    done

    if [ "${had_nullglob}" -eq 0 ]; then
        shopt -u nullglob
    fi
}

choose_verified_identity() {
    if [ "${#SCAN_VERIFIED_NORMAL_IDS[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local best_pid="" best_id="" id pid
    for id in "${SCAN_VERIFIED_NORMAL_IDS[@]}"; do
        pid="${id%%:*}"
        case "${pid}" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ -z "${best_pid}" ] || [ "${pid}" -lt "${best_pid}" ]; then
            best_pid="${pid}"
            best_id="${id}"
        fi
    done
    printf '%s' "${best_id}"
}

identity_is_present() {
    local wanted="$1"
    local id
    [ -n "${wanted}" ] || return 1
    if [ "${#SCAN_VERIFIED_NORMAL_IDS[@]}" -eq 0 ]; then
        return 1
    fi
    for id in "${SCAN_VERIFIED_NORMAL_IDS[@]}"; do
        if [ "${id}" = "${wanted}" ]; then
            return 0
        fi
    done
    return 1
}

wait_for_stable_mt5_process() {
    local wait_seconds="${BRIDGE_WAIT_SECONDS}"
    local poll_seconds="${BRIDGE_PROCESS_POLL_SECONDS}"
    local stable_needed="${BRIDGE_MT5_PROCESS_STABLE_SECONDS}"
    local started="${SECONDS}"
    local last_warn_cycle=0
    local stable_identity=""
    local stable_since=0
    local stable_for=0
    local last_updater=-1
    local chosen pid

    log "state=WAITING_FOR_MT5_PROCESS wait_seconds=${wait_seconds} poll_seconds=${poll_seconds} stable_seconds=${stable_needed} launch_allowed=0"

    while true; do
        if [ "${STOP_REQUESTED}" -eq 1 ]; then
            exit 0
        fi

        local elapsed=$((SECONDS - started))
        if [ "${elapsed}" -ge "${wait_seconds}" ]; then
            local warn_cycle=$((elapsed / wait_seconds))
            if [ "${warn_cycle}" -gt "${last_warn_cycle}" ]; then
                last_warn_cycle="${warn_cycle}"
                log "state=WAITING_FOR_MT5_PROCESS wait_seconds=${wait_seconds} action=continue_waiting launch_allowed=0"
            fi
        fi

        scan_mt5_processes

        if [ "${SCAN_UPDATER_COUNT}" -gt 0 ]; then
            if [ "${last_updater}" != "${SCAN_UPDATER_COUNT}" ] || [ -n "${stable_identity}" ]; then
                log "state=WAITING_FOR_MT5_PROCESS updater_count=${SCAN_UPDATER_COUNT} candidate_count=${SCAN_NORMAL_COUNT} action=wait reason=updater_active launch_allowed=0"
            fi
            last_updater="${SCAN_UPDATER_COUNT}"
            stable_identity=""
            stable_since=0
            stable_for=0
            sleep "${poll_seconds}" || true
            continue
        fi
        last_updater=0

        if identity_is_present "${stable_identity}"; then
            stable_for=$((SECONDS - stable_since))
        else
            chosen="$(choose_verified_identity)"
            if [ -n "${chosen}" ]; then
                pid="${chosen%%:*}"
                log "state=WAITING_FOR_MT5_PROCESS candidate_pid=${pid} candidate_identity_changed=1 stable_for=0 candidate_count=${SCAN_NORMAL_COUNT} action=wait launch_allowed=0"
                stable_identity="${chosen}"
                stable_since="${SECONDS}"
                stable_for=0
            else
                if [ -n "${stable_identity}" ]; then
                    log "state=WAITING_FOR_MT5_PROCESS candidate_count=0 stable_for=0 action=wait launch_allowed=0"
                fi
                stable_identity=""
                stable_since=0
                stable_for=0
            fi
        fi

        if [ "${SCAN_UPDATER_COUNT}" -eq 0 ] \
            && [ -n "${stable_identity}" ] \
            && identity_is_present "${stable_identity}" \
            && [ "${stable_for}" -ge "${stable_needed}" ]; then
            pid="${stable_identity%%:*}"
            log "state=MT5_PROCESS_READY candidate_pid=${pid} candidate_count=${SCAN_NORMAL_COUNT} stable_seconds=${stable_needed} action=start_bridge launch_allowed=1"
            return 0
        fi

        sleep "${poll_seconds}" || true
        if [ "${STOP_REQUESTED}" -eq 1 ]; then
            exit 0
        fi
    done
}

start_bridge_server() {
    cd "${BRIDGE_DIR}"
    log "state=STARTING_RPYC port=${RPYC_PORT}"
    SPAWN_IN_PROGRESS=1
    wine python mt5_bridge.py &
    local server_pid=$!
    bridge_after_spawn_before_register "${server_pid}" "server"
    register_bridge_child "${server_pid}" "server"
    log "state=RUNNING child_pid=${CURRENT_BRIDGE_CHILD_PID}"
    set +e
    wait "${CURRENT_BRIDGE_CHILD_PID}"
    local server_status=$?
    set -e
    log "state=BRIDGE_EXIT code=${server_status}"
    clear_bridge_child
    return "${server_status}"
}

main() {
    trap 'on_term INT' INT
    trap 'on_term TERM' TERM

    if [ ! -f "${BRIDGE_DIR}/mt5_bridge.py" ]; then
        echo "ERRO: bridge ausente em ${BRIDGE_DIR}/mt5_bridge.py"
        exit 1
    fi

    wait_for_stable_mt5_process

    if [ "${STOP_REQUESTED}" -eq 1 ]; then
        exit 0
    fi

    local server_status=0
    start_bridge_server || server_status=$?
    exit "${server_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
