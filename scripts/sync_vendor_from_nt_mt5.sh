#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NT_MT5="${NT_MT5_ROOT:-$(dirname "$ROOT")/nt_mt5}"

if [ ! -d "$NT_MT5/MQL5/refactoring" ]; then
    echo "ERRO: nt_mt5 não encontrado em $NT_MT5"
    exit 1
fi

mkdir -p "$ROOT/vendor/bridge" "$ROOT/vendor/mql5/Include/WebSocket" "$ROOT/vendor/mql5/Services"

cp -f "$NT_MT5/MQL5/refactoring/bridge/mt5_bridge.py" \
      "$NT_MT5/MQL5/refactoring/bridge/history_args.py" \
      "$ROOT/vendor/bridge/"
cp -f "$NT_MT5/MQL5/refactoring/Include/NT5FeedWire.mqh" "$ROOT/vendor/mql5/Include/"
cp -f "$NT_MT5/MQL5/refactoring/Include/WebSocket/"*.mqh "$ROOT/vendor/mql5/Include/WebSocket/"
cp -f "$NT_MT5/MQL5/refactoring/Services/NT5TickFeedService.mq5" \
      "$NT_MT5/MQL5/refactoring/Services/NT5TickFeedService.ex5" \
      "$ROOT/vendor/mql5/Services/"

echo "vendor/ synced from $NT_MT5"
