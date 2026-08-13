#!/command/with-contenv bash
# s6 oneshot wrapper: invoke deploy_mql5.sh under the legacy nonfatal container policy.
#
# Data flow: executed by s6-rc service deploy-mql5 after install-mt5; may call
# deploy_mql5.sh then return 0 so stage2 does not fail. Downstream configure /
# mt5_lifecycle / Python / bridge remain in the CMD entrypoint.
# Limitations: preserves RUN_MT5=1 + MT5_EXE present + DEPLOY_MQL5=1 gates from
# the former CMD ownership; raw deploy failures stay nonfatal here.
set -Eeuo pipefail

readonly LOG_PREFIX="[DEPLOY-MQL5-ONESHOT]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"

RUN_MT5="${RUN_MT5:-1}"
DEPLOY_MQL5="${DEPLOY_MQL5:-1}"
MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"
DEPLOY_MQL5_SCRIPT="${DEPLOY_MQL5_SCRIPT:-/scripts/deploy_mql5.sh}"

if [ "$RUN_MT5" != "1" ]; then
    log "state=SKIPPED reason=run_mt5_disabled"
    exit 0
fi

if [ ! -f "$MT5_EXE" ]; then
    log "state=SKIPPED reason=mt5_exe_missing_before_cmd_validation"
    exit 0
fi

if [ "$DEPLOY_MQL5" != "1" ]; then
    log "state=SKIPPED reason=deploy_disabled"
    exit 0
fi

set +e
bash "$DEPLOY_MQL5_SCRIPT"
DEPLOY_STATUS=$?
set -e

if [ "$DEPLOY_STATUS" -eq 0 ]; then
    log "state=COMPLETED raw_status=0"
    exit 0
fi

echo "AVISO: deploy MQL5 falhou (continuando)."
log "state=WARNING raw_status=${DEPLOY_STATUS} policy=legacy_nonfatal"
exit 0
