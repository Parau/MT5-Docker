#!/bin/bash
# Start RPyC bridge after MT5 terminal is reachable via MetaTrader5 Python API.
set -Eeuo pipefail

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

BRIDGE_DIR="${BRIDGE_DIR:-/opt/bridge}"
RPYC_PORT="${RPYC_PORT:-18812}"
BRIDGE_WAIT_SECONDS="${BRIDGE_WAIT_SECONDS:-180}"
BRIDGE_RETRY_SECONDS="${BRIDGE_RETRY_SECONDS:-5}"

if [ ! -f "$BRIDGE_DIR/mt5_bridge.py" ]; then
    echo "ERRO: bridge ausente em $BRIDGE_DIR/mt5_bridge.py"
    exit 1
fi

echo "START_BRIDGE: aguardando MT5 (até ${BRIDGE_WAIT_SECONDS}s)..."

deadline=$((SECONDS + BRIDGE_WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    if wine python - <<'PY' >/dev/null 2>&1
import MetaTrader5 as mt5
if not mt5.initialize():
    raise SystemExit(1)
info = mt5.terminal_info()
mt5.shutdown()
if info is None or not getattr(info, "connected", False):
    raise SystemExit(1)
PY
    then
        echo "START_BRIDGE: MT5 respondeu via MetaTrader5.initialize()."
        break
    fi
    sleep "$BRIDGE_RETRY_SECONDS"
done

if [ "$SECONDS" -ge "$deadline" ]; then
    echo "AVISO: MT5 não respondeu a tempo — bridge tentará mesmo assim."
fi

echo "START_BRIDGE: iniciando RPyC na porta ${RPYC_PORT}..."
cd "$BRIDGE_DIR"
exec wine python mt5_bridge.py
