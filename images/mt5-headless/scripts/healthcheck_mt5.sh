#!/command/with-contenv bash
# Docker HEALTHCHECK: continuous operational health (not s6 startup readiness).
#
# Data flow: Docker invokes this on an interval. First checks RUN_MT5 and
# s6-svstat -u (process-up only — never s6 ready) for metatrader/bridge. Only
# when both longruns are up does it run a bounded Wine Python RPyC client
# against 127.0.0.1:RPYC_PORT calling root.health() on the already-initialized
# bridge (no MetaTrader5.initialize).
# Policy (04K-B): Docker health ≠ s6 ready. Bridge has no notification-fd;
# ready=false while up is expected and must not be treated as unhealthy alone.
# Limitations: unhealthy is observability only — never restarts services;
# mt5-only mode (RUN_BRIDGE!=1) reports metatrader-up liveness, not trade-server
# connection.
set -Eeuo pipefail

readonly LOG_PREFIX="[HEALTHCHECK]"

S6_SVSTAT_BIN="${S6_SVSTAT_BIN:-/command/s6-svstat}"
S6_SERVICE_ROOT="${S6_SERVICE_ROOT:-/run/service}"
HEALTHCHECK_WINE_BIN="${HEALTHCHECK_WINE_BIN:-wine}"
HEALTHCHECK_TIMEOUT_BIN="${HEALTHCHECK_TIMEOUT_BIN:-timeout}"
HEALTHCHECK_RPC_TIMEOUT_SECONDS="${HEALTHCHECK_RPC_TIMEOUT_SECONDS:-5}"
RPYC_PORT="${RPYC_PORT:-18812}"
RUN_MT5="${RUN_MT5:-1}"
RUN_BRIDGE="${RUN_BRIDGE:-1}"

log() {
    echo "${LOG_PREFIX} $*"
}

service_up() {
    local name="$1"
    local state
    state="$("${S6_SVSTAT_BIN}" -u "${S6_SERVICE_ROOT}/${name}" 2>/dev/null || true)"
    [ "${state}" = "true" ]
}

rpyc_port_valid() {
    local port="${1:-}"
    case "${port}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        return 1
    fi
    return 0
}

if [ "${RUN_MT5}" != "1" ]; then
    log "state=DISABLED reason=RUN_MT5"
    exit 0
fi

if ! service_up metatrader; then
    log "state=UNHEALTHY reason=metatrader-down"
    exit 1
fi

if [ "${RUN_BRIDGE}" != "1" ]; then
    log "state=HEALTHY mode=mt5-only evidence=metatrader-up"
    exit 0
fi

if ! service_up bridge; then
    log "state=UNHEALTHY reason=bridge-down"
    exit 1
fi

if ! rpyc_port_valid "${RPYC_PORT}"; then
    log "state=UNHEALTHY reason=invalid_rpyc_port"
    exit 1
fi

set +e
"${HEALTHCHECK_TIMEOUT_BIN}" "${HEALTHCHECK_RPC_TIMEOUT_SECONDS}s" \
    "${HEALTHCHECK_WINE_BIN}" python - "${RPYC_PORT}" "${HEALTHCHECK_RPC_TIMEOUT_SECONDS}" <<'PY'
import os
import socket
import sys

port = int(sys.argv[1])
timeout_s = float(sys.argv[2])
socket.setdefaulttimeout(timeout_s)

try:
    import rpyc
except Exception:
    sys.exit(1)

conn = None
try:
    conn = rpyc.connect(
        "127.0.0.1",
        port,
        config={"sync_request_timeout": timeout_s},
    )
    ok = bool(conn.root.health())
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
finally:
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
PY
rpc_status=$?
set -e

case "${rpc_status}" in
    0)
        log "state=HEALTHY mode=bridge evidence=rpyc+mt5-connected"
        exit 0
        ;;
    124)
        log "state=UNHEALTHY reason=timeout"
        exit 1
        ;;
    *)
        log "state=UNHEALTHY reason=rpyc-or-mt5-not-ready"
        exit 1
        ;;
esac
