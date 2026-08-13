#!/command/with-contenv bash
# Apply NT5TickFeedService inputs to MT5 Config/*.ini (UTF-16).
#
# Data flow: still invoked from CMD after deploy-mql5; runs
# configure_nt5_service.py against the Wine MT5 Config tree.
# Limitations: not an s6 oneshot yet; raw failures remain nonzero;
# container-level nonfatal policy stays in the entrypoint wrapper;
# a future oneshot promotion needs an explicit policy wrapper.
# python3 is required only when CONFIGURE_NT5=1.
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
