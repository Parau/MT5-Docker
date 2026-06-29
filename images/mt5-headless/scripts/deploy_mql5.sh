#!/bin/bash
# Deploy vendored MQL5 Service + Include tree into the MT5 portable data folder.
set -Eeuo pipefail

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"

VENDOR_ROOT="${VENDOR_MQL5_ROOT:-/vendor/mql5}"
MT5_MQL5_ROOT="${MT5_MQL5_ROOT:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/MQL5}"

if [ ! -d "$VENDOR_ROOT" ]; then
    echo "DEPLOY_MQL5: vendor tree ausente em $VENDOR_ROOT — ignorando."
    exit 0
fi

if [ ! -d "$WINEPREFIX/drive_c/Program Files/MetaTrader 5" ]; then
    echo "DEPLOY_MQL5: MT5 ainda não instalado — ignorando deploy MQL5."
    exit 0
fi

echo "DEPLOY_MQL5: sincronizando $VENDOR_ROOT -> $MT5_MQL5_ROOT"

mkdir -p "$MT5_MQL5_ROOT/Include/WebSocket" "$MT5_MQL5_ROOT/Services"

if [ -f "$VENDOR_ROOT/Include/NT5FeedWire.mqh" ]; then
    cp -f "$VENDOR_ROOT/Include/NT5FeedWire.mqh" "$MT5_MQL5_ROOT/Include/"
fi

if [ -d "$VENDOR_ROOT/Include/WebSocket" ]; then
    cp -f "$VENDOR_ROOT/Include/WebSocket/"*.mqh "$MT5_MQL5_ROOT/Include/WebSocket/" 2>/dev/null || true
fi

if [ -f "$VENDOR_ROOT/Services/NT5TickFeedService.mq5" ]; then
    cp -f "$VENDOR_ROOT/Services/NT5TickFeedService.mq5" "$MT5_MQL5_ROOT/Services/"
    echo "DEPLOY_MQL5: NT5TickFeedService.mq5"
fi

if [ -f "$VENDOR_ROOT/Services/NT5TickFeedService.ex5" ]; then
    cp -f "$VENDOR_ROOT/Services/NT5TickFeedService.ex5" "$MT5_MQL5_ROOT/Services/"
    echo "DEPLOY_MQL5: NT5TickFeedService.ex5 (compilado vendored)"
else
    echo "DEPLOY_MQL5: AVISO — NT5TickFeedService.ex5 ausente; compile no VNC (MetaEditor F7) ou re-sync vendor com .ex5 do nt_mt5."
fi

echo "DEPLOY_MQL5: concluído."
ls -la "$MT5_MQL5_ROOT/Services/" 2>/dev/null || true
