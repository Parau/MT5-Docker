#!/bin/bash
# RPyC bridge lifecycle wrapper: readiness polling then one Wine Python child.
#
# Data flow: CMD-owned background process after metatrader longrun is up.
# RUN_BRIDGE gate is caller-owned (entrypoint); this script never reads it.
# Readiness probe = mt5.initialize() True AND terminal_info() connected True.
# Probe and server are spawn+wait children tracked as CURRENT_BRIDGE_CHILD_PID.
# CMD TERMs this wrapper; the wrapper TERMs only its current child.
# Consumers: entrypoint.sh (BRIDGE_PID). Input: WINEPREFIX, RPYC_PORT, BRIDGE_DIR.
# Premises: timeout_policy=best_effort (deadline is admission for new probes,
# not a hard abort). One server execution, no restart. TERM/INT always forward
# TERM to the child; timeout yields fallback_required then wrapper exit 0.
# Limitations: not s6-owned; crash is nonfatal to the container; initialize()
# may launch the terminal (MetaQuotes); no SIGKILL/pkill/wineserver-k here.
set -Eeuo pipefail

readonly LOG_PREFIX="[BRIDGE-LIFECYCLE]"

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

BRIDGE_DIR="${BRIDGE_DIR:-/opt/bridge}"
RPYC_PORT="${RPYC_PORT:-18812}"
BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"
BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}"
BRIDGE_SHUTDOWN_TIMEOUT_SECONDS="${BRIDGE_SHUTDOWN_TIMEOUT_SECONDS:-8}"
BRIDGE_SHUTDOWN_POLL_SECONDS="${BRIDGE_SHUTDOWN_POLL_SECONDS:-1}"

CURRENT_BRIDGE_CHILD_PID=""
CURRENT_BRIDGE_CHILD_KIND=""
MT5_READY_OBSERVED=0
STOP_REQUESTED=0
SHUTDOWN_IN_PROGRESS=0

log() {
    echo "${LOG_PREFIX} $*"
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
    SHUTDOWN_IN_PROGRESS=1
    trap '' INT TERM
    STOP_REQUESTED=1
    shutdown_bridge_child "${source_signal}" || true
    exit 0
}

run_readiness_probe() {
    wine python - <<'PY' >/dev/null 2>&1 &
import MetaTrader5 as mt5
if not mt5.initialize():
    raise SystemExit(1)
info = mt5.terminal_info()
mt5.shutdown()
if info is None or not getattr(info, "connected", False):
    raise SystemExit(1)
PY
    CURRENT_BRIDGE_CHILD_PID=$!
    CURRENT_BRIDGE_CHILD_KIND="probe"
    set +e
    wait "${CURRENT_BRIDGE_CHILD_PID}"
    local probe_status=$?
    set -e
    clear_bridge_child
    return "${probe_status}"
}

start_bridge_server() {
    cd "${BRIDGE_DIR}"
    log "state=STARTING_RPYC port=${RPYC_PORT}"
    wine python mt5_bridge.py &
    CURRENT_BRIDGE_CHILD_PID=$!
    CURRENT_BRIDGE_CHILD_KIND="server"
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

    log "state=WAITING_FOR_MT5 timeout_seconds=${BRIDGE_WAIT_SECONDS} retry_seconds=${BRIDGE_RETRY_SECONDS} timeout_policy=best_effort"

    local deadline=$((SECONDS + BRIDGE_WAIT_SECONDS))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ "${STOP_REQUESTED}" -eq 1 ]; then
            exit 0
        fi
        if run_readiness_probe; then
            MT5_READY_OBSERVED=1
            log "state=MT5_READY readiness=initialize+terminal_info.connected"
            break
        fi
        if [ "${STOP_REQUESTED}" -eq 1 ]; then
            exit 0
        fi
        sleep "${BRIDGE_RETRY_SECONDS}" || true
    done

    if [ "${MT5_READY_OBSERVED}" != "1" ]; then
        log "state=READINESS_TIMEOUT timeout_policy=best_effort action=start_bridge"
    fi

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
