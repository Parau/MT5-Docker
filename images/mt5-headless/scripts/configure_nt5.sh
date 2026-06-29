#!/bin/bash
# Apply NT5TickFeedService inputs to MT5 Config/*.ini (UTF-16).
set -Eeuo pipefail

if [ "${CONFIGURE_NT5:-1}" != "1" ]; then
    echo "CONFIGURE_NT5=${CONFIGURE_NT5:-0}. Configuração NT5 ignorada."
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERRO: python3 ausente — não foi possível configurar NT5."
    exit 1
fi

python3 /scripts/configure_nt5_service.py
