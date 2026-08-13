#!/command/with-contenv bash
# s6 oneshot wrapper: invoke configure_nt5.sh under the legacy nonfatal container policy.
#
# Data flow: executed by s6-rc service configure-nt5 after deploy-mql5; may call
# configure_nt5.sh then return 0 so stage2 does not fail. Downstream
# mt5_lifecycle / Python / bridge remain in the CMD entrypoint.
# Limitations: preserves RUN_MT5=1 + MT5_EXE present + CONFIGURE_NT5=1 gates from
# the former CMD ownership; raw configure failures stay nonfatal here.
set -Eeuo pipefail

readonly LOG_PREFIX="[CONFIGURE-NT5-ONESHOT]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"

RUN_MT5="${RUN_MT5:-1}"
CONFIGURE_NT5="${CONFIGURE_NT5:-1}"
MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"
CONFIGURE_NT5_SCRIPT="${CONFIGURE_NT5_SCRIPT:-/scripts/configure_nt5.sh}"

if [ "$RUN_MT5" != "1" ]; then
    log "state=SKIPPED reason=run_mt5_disabled"
    exit 0
fi

if [ ! -f "$MT5_EXE" ]; then
    log "state=SKIPPED reason=mt5_exe_missing_before_cmd_validation"
    exit 0
fi

if [ "$CONFIGURE_NT5" != "1" ]; then
    log "state=SKIPPED reason=configure_disabled"
    exit 0
fi

set +e
bash "$CONFIGURE_NT5_SCRIPT"
CONFIGURE_STATUS=$?
set -e

if [ "$CONFIGURE_STATUS" -eq 0 ]; then
    log "state=COMPLETED raw_status=0"
    exit 0
fi

echo "AVISO: configure NT5 falhou (continuando)."
log "state=WARNING raw_status=${CONFIGURE_STATUS} policy=legacy_nonfatal"
exit 0
