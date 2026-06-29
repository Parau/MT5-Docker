#!/usr/bin/env bash
# Start NT5 WS feed test server on the Docker host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NT_MT5="${NT_MT5_ROOT:-$ROOT/../nt_mt5}"
SCRIPT="$NT_MT5/MQL5/refactoring/tools/ws_feed_test_server.py"
PORT="${WS_PORT:-8765}"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERRO: não encontrado: $SCRIPT" >&2
  echo "Defina NT_MT5_ROOT ou clone nt_mt5 ao lado de MT5-Docker." >&2
  exit 1
fi

exec python3 "$SCRIPT" --host 0.0.0.0 --port "$PORT" -v "$@"
