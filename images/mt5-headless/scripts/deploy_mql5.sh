#!/command/with-contenv bash
# Deploy vendored MQL5 Service + Include tree into the MT5 portable data folder.
#
# Data flow: core deploy operation invoked by deploy_mql5_oneshot.sh (s6 oneshot
# deploy-mql5). Copies /vendor/mql5 (or VENDOR_MQL5_ROOT) into the Wine MT5 MQL5
# tree for NT5TickFeedService. Contract is frozen by tests/test_deploy_mql5.sh.
# Limitations: raw operational failures remain nonzero here; the s6 wrapper
# preserves the legacy container-level nonfatal policy. Missing .ex5 is
# warning-only; WebSocket copy errors are tolerated (|| true).
set -Eeuo pipefail

readonly LOG_PREFIX="[DEPLOY-MQL5]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"

DEPLOY_MQL5="${DEPLOY_MQL5:-1}"
VENDOR_ROOT="${VENDOR_MQL5_ROOT:-/vendor/mql5}"
MT5_MQL5_ROOT="${MT5_MQL5_ROOT:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/MQL5}"

if [ "$DEPLOY_MQL5" != "1" ]; then
    log "DEPLOY_MQL5=${DEPLOY_MQL5}. Deploy MQL5 ignorado."
    exit 0
fi

if [ ! -d "$VENDOR_ROOT" ]; then
    log "vendor tree ausente em $VENDOR_ROOT — ignorando."
    exit 0
fi

if [ ! -d "$WINEPREFIX/drive_c/Program Files/MetaTrader 5" ]; then
    log "MT5 ainda não instalado — ignorando deploy MQL5."
    exit 0
fi

log "sincronizando $VENDOR_ROOT -> $MT5_MQL5_ROOT"

mkdir -p "$MT5_MQL5_ROOT/Include/WebSocket" "$MT5_MQL5_ROOT/Services"

if [ -f "$VENDOR_ROOT/Include/NT5FeedWire.mqh" ]; then
    cp -f "$VENDOR_ROOT/Include/NT5FeedWire.mqh" "$MT5_MQL5_ROOT/Include/"
fi

if [ -d "$VENDOR_ROOT/Include/WebSocket" ]; then
    cp -f "$VENDOR_ROOT/Include/WebSocket/"*.mqh "$MT5_MQL5_ROOT/Include/WebSocket/" 2>/dev/null || true
fi

if [ -f "$VENDOR_ROOT/Services/NT5TickFeedService.mq5" ]; then
    cp -f "$VENDOR_ROOT/Services/NT5TickFeedService.mq5" "$MT5_MQL5_ROOT/Services/"
    log "NT5TickFeedService.mq5"
fi

if [ -f "$VENDOR_ROOT/Services/NT5TickFeedService.ex5" ]; then
    cp -f "$VENDOR_ROOT/Services/NT5TickFeedService.ex5" "$MT5_MQL5_ROOT/Services/"
    log "NT5TickFeedService.ex5 (compilado vendored)"
else
    log "AVISO — NT5TickFeedService.ex5 ausente; compile no VNC (MetaEditor F7) ou re-sync vendor com .ex5 do nt_mt5."
fi

log "concluído."
ls -la "$MT5_MQL5_ROOT/Services/" 2>/dev/null || true
