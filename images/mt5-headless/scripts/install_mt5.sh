#!/command/with-contenv bash
# Install or skip MetaTrader 5 inside the Wine prefix (still invoked from CMD).
#
# Data flow: called by entrypoint after display/Openbox barriers and optional x11vnc;
# downstream consumers are deploy_mql5, configure_nt5, and mt5_lifecycle.
# Limitations: not an s6 oneshot yet; INSTALL_MT5!=1 is a no-op; does not start MT5.
set -Eeuo pipefail

readonly LOG_PREFIX="[INSTALL-MT5]"

log() {
    echo "${LOG_PREFIX} $*"
}

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

INSTALL_MT5="${INSTALL_MT5:-0}"
MT5_SETUP_URL="${MT5_SETUP_URL:-https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe}"
MT5_INSTALLER="${MT5_INSTALLER:-$WINEPREFIX/drive_c/mt5setup.exe}"
MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"
WEBVIEW_URL="${WEBVIEW_URL:-https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f2910a1e-e5a6-4f17-b52d-7faf525d17f8/MicrosoftEdgeWebview2Setup.exe}"
WEBVIEW_INSTALLER="${WEBVIEW_INSTALLER:-$WINEPREFIX/drive_c/webview2.exe}"
MT5_INSTALL_MODE="${MT5_INSTALL_MODE:-manual}"

if [ "$INSTALL_MT5" != "1" ]; then
    log "INSTALL_MT5=${INSTALL_MT5}. Etapa de instalação do MT5 ignorada."
    exit 0
fi

log "INSTALL_MT5=1. Iniciando etapa de instalação do MetaTrader 5..."

if [ -f "$MT5_EXE" ]; then
    log "MT5 já instalado:"
    ls -la "$MT5_EXE"
    exit 0
fi

log "MT5 ainda não encontrado em:"
log "$MT5_EXE"

log "Baixando MetaTrader e WebView2 Runtime, seguindo a ordem do setup oficial..."
curl "$MT5_SETUP_URL" --output "$MT5_INSTALLER"
curl "$WEBVIEW_URL" --output "$WEBVIEW_INSTALLER"

log "Instalador MT5 baixado:"
ls -lh "$MT5_INSTALLER" || true

log "Instalador WebView2 baixado:"
ls -lh "$WEBVIEW_INSTALLER" || true

log "Instalando WebView2 Runtime, como no setup oficial..."
set +e
wine "$WEBVIEW_INSTALLER" /silent /install
WEBVIEW_STATUS=$?
set -e

log "WebView2 retornou código: $WEBVIEW_STATUS"

log "Instalando MetaTrader 5. MT5_INSTALL_MODE=$MT5_INSTALL_MODE"
set +e

if [ "$MT5_INSTALL_MODE" = "auto" ]; then
    log "Modo auto: executando MT5 com /auto, estilo gmag11."
    wine "$MT5_INSTALLER" "/auto" &
    MT5_INSTALL_PID=$!
    wait "$MT5_INSTALL_PID"
    MT5_INSTALL_STATUS=$?
else
    log "Modo manual: executando MT5 sem /auto, como no setup oficial da MetaTrader."
    wine "$MT5_INSTALLER"
    MT5_INSTALL_STATUS=$?
fi

set -e

log "Instalador MT5 retornou código: $MT5_INSTALL_STATUS"

rm -f "$WEBVIEW_INSTALLER"
rm -f "$MT5_INSTALLER"

if [ ! -f "$MT5_EXE" ]; then
    log "ERRO: terminal64.exe não encontrado após instalação."
    log "Procurando terminal64.exe dentro do prefixo..."
    find "$WINEPREFIX/drive_c" -iname "terminal64.exe" 2>/dev/null || true
    exit 1
fi

log "MT5 instalado com sucesso:"
ls -la "$MT5_EXE"
exit 0
