#!/command/with-contenv bash
# s6 oneshot wrapper: invoke bootstrap_python.sh under the legacy nonfatal container policy.
#
# Data flow: executed by s6-rc service python-bootstrap after configure-nt5; may call
# bootstrap_python.sh then return 0 so stage2 does not fail. Downstream
# metatrader / bridge are dedicated s6 longruns and start only after this
# oneshot completes (intentional temporal change vs former CMD-era ordering).
# Limitations: preserves RUN_MT5=1 + MT5_EXE present + BOOTSTRAP_PYTHON=1 gates from
# the former CMD ownership; raw bootstrap failures stay nonfatal here.
set -Eeuo pipefail

readonly LOG_PREFIX="[PYTHON-BOOTSTRAP-ONESHOT]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"

RUN_MT5="${RUN_MT5:-1}"
BOOTSTRAP_PYTHON="${BOOTSTRAP_PYTHON:-1}"
MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"
BOOTSTRAP_PYTHON_SCRIPT="${BOOTSTRAP_PYTHON_SCRIPT:-/scripts/bootstrap_python.sh}"

if [ "$RUN_MT5" != "1" ]; then
    log "state=SKIPPED reason=run_mt5_disabled"
    exit 0
fi

if [ ! -f "$MT5_EXE" ]; then
    log "state=SKIPPED reason=mt5_exe_missing_before_cmd_validation"
    exit 0
fi

if [ "$BOOTSTRAP_PYTHON" != "1" ]; then
    log "state=SKIPPED reason=bootstrap_disabled"
    exit 0
fi

set +e
bash "$BOOTSTRAP_PYTHON_SCRIPT"
BOOTSTRAP_STATUS=$?
set -e

if [ "$BOOTSTRAP_STATUS" -eq 0 ]; then
    log "state=COMPLETED raw_status=0"
    exit 0
fi

echo "AVISO: bootstrap Python falhou (continuando)."
log "state=WARNING raw_status=${BOOTSTRAP_STATUS} policy=legacy_nonfatal"
exit 0
