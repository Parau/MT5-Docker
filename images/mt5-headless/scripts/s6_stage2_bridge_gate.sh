#!/command/with-contenv bash
# Stage2 hook: include or exclude the bridge longrun from the user bundle.
#
# Data flow: S6_STAGE2_HOOK runs before s6-rc-compile. Enabled only when
# RUN_MT5=1 and RUN_BRIDGE=1; otherwise removes contents.d/bridge. Does not
# replace /init and does not use S6_RUNTIME_BUNDLEDIR. with-contenv is required
# because stage2 hooks do not inherit Docker -e values in the process environ.
# Premises: disabled != finish125; packaging gaps must fail the hook nonzero
# so S6_BEHAVIOUR_IF_STAGE2_FAILS=2 can stop the container.
# Limitations: mutates the live user-bundles tree in the container filesystem.
# Unit tests may invoke this script with plain `bash` and exported vars.
set -Eeuo pipefail

readonly LOG_PREFIX="[S6-STAGE2-BRIDGE-GATE]"

log() {
    echo "${LOG_PREFIX} $*"
}

RUN_MT5="${RUN_MT5:-1}"
RUN_BRIDGE="${RUN_BRIDGE:-1}"

BRIDGE_GATE_BUNDLE_DIR="${BRIDGE_GATE_BUNDLE_DIR:-/etc/s6-overlay/user-bundles.d/user/contents.d}"
BRIDGE_GATE_MARKER="${BRIDGE_GATE_MARKER:-${BRIDGE_GATE_BUNDLE_DIR}/bridge}"
BRIDGE_GATE_SERVICE_DIR="${BRIDGE_GATE_SERVICE_DIR:-/etc/s6-overlay/s6-rc.d/bridge}"

fail_packaging() {
    local reason="$1"
    log "state=FAILED run_mt5=${RUN_MT5} run_bridge=${RUN_BRIDGE} reason=${reason}"
    exit 1
}

if [ "${RUN_MT5}" = "1" ] && [ "${RUN_BRIDGE}" = "1" ]; then
    if [ ! -d "${BRIDGE_GATE_SERVICE_DIR}" ]; then
        fail_packaging "bridge_service_dir_missing"
    fi
    if [ ! -f "${BRIDGE_GATE_SERVICE_DIR}/type" ] || [ ! -x "${BRIDGE_GATE_SERVICE_DIR}/run" ]; then
        fail_packaging "bridge_service_definition_incomplete"
    fi
    if [ ! -d "${BRIDGE_GATE_BUNDLE_DIR}" ]; then
        fail_packaging "bundle_dir_missing"
    fi
    : >"${BRIDGE_GATE_MARKER}"
    log "state=ENABLED run_mt5=1 run_bridge=1"
    exit 0
fi

rm -f "${BRIDGE_GATE_MARKER}"

reason="run_bridge_disabled"
if [ "${RUN_MT5}" != "1" ] && [ "${RUN_BRIDGE}" != "1" ]; then
    reason="run_mt5_and_run_bridge_disabled"
elif [ "${RUN_MT5}" != "1" ]; then
    reason="run_mt5_disabled"
fi

log "state=DISABLED run_mt5=${RUN_MT5} run_bridge=${RUN_BRIDGE} reason=${reason}"
exit 0
