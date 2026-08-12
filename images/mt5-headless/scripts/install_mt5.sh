#!/command/with-contenv bash
# Install or skip MetaTrader 5 inside the Wine prefix (s6 oneshot install-mt5).
#
# Data flow: executed by s6-rc oneshot install-mt5 after vnc-access is up; logical
# dependency on VNC readiness for real installs. Downstream runtime (deploy MQL5,
# configure NT5, mt5_lifecycle, Python, bridge) remains in the CMD entrypoint.
# Limitations: does not start MT5; longrun VNC dependency is not TCP readiness —
# this script waits for VNC only when INSTALL_MT5=1 and MT5_EXE is absent.
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
ENABLE_VNC="${ENABLE_VNC:-1}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-xvnc}"
VNC_PORT="${VNC_PORT:-5900}"
INSTALL_MT5_VNC_TIMEOUT_SECONDS="${INSTALL_MT5_VNC_TIMEOUT_SECONDS:-30}"
VNC_LOG_FILE="${VNC_LOG_FILE:-/tmp/x11vnc.log}"
XVNC_LOG_FILE="${XVNC_LOG_FILE:-/tmp/xvnc.log}"

vnc_port_ready() {
    local port="$1"
    (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

diagnose_vnc_failure() {
    log "Diagnóstico serviço s6 vnc-access:"
    /command/s6-svstat /run/service/vnc-access 2>/dev/null || true

    log "Diagnóstico serviço s6 display:"
    /command/s6-svstat /run/service/display 2>/dev/null || true

    log "Diagnóstico serviço s6 window-manager:"
    /command/s6-svstat /run/service/window-manager 2>/dev/null || true

    if [ "$DISPLAY_BACKEND" = "xvnc" ]; then
        log "Processos Xvnc/Xtigervnc:"
        ps -eo pid,comm | grep -E "Xvnc|Xtigervnc" | grep -v grep || true
        log "Log Xvnc:"
        cat "$XVNC_LOG_FILE" 2>/dev/null || true
    else
        log "Processos x11vnc:"
        ps -C x11vnc -o pid=,comm= 2>/dev/null || true
        log "Log x11vnc:"
        cat "$VNC_LOG_FILE" 2>/dev/null || true
    fi
}

wait_for_vnc_access_for_install() {
    if [ "$ENABLE_VNC" != "1" ]; then
        log "ENABLE_VNC=${ENABLE_VNC}. Barrier VNC omitido para instalação."
        return 0
    fi

    local provider="x11vnc"
    if [ "$DISPLAY_BACKEND" = "xvnc" ]; then
        provider="xvnc"
    fi

    log "state=WAITING_VNC provider=${provider} port=${VNC_PORT}"

    local i
    for i in $(seq 1 "$INSTALL_MT5_VNC_TIMEOUT_SECONDS"); do
        if [ "$DISPLAY_BACKEND" = "xvnc" ]; then
            if vnc_port_ready "$VNC_PORT"; then
                log "state=VNC_READY provider=xvnc"
                return 0
            fi
        else
            if pgrep -x x11vnc >/dev/null 2>&1 && vnc_port_ready "$VNC_PORT"; then
                log "state=VNC_READY provider=x11vnc"
                return 0
            fi
        fi
        sleep 1
    done

    log "state=FAILED reason=vnc_not_ready"
    diagnose_vnc_failure
    exit 1
}

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

wait_for_vnc_access_for_install

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
