#!/bin/bash
set -Eeuo pipefail

echo "Iniciando teste Debian Bookworm + WineHQ com fluxo inspirado no gmag11 e no setup oficial da MetaTrader..."

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"

ENABLE_VNC="${ENABLE_VNC:-1}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_LOG_FILE="${VNC_LOG_FILE:-/tmp/x11vnc.log}"

DISPLAY_BACKEND="${DISPLAY_BACKEND:-xvnc}"
XVNC_LOG_FILE="${XVNC_LOG_FILE:-/tmp/xvnc.log}"

cleanup() {
    echo "Finalizando processos temporários..."
    wineserver -k || true
}

trap cleanup EXIT

vnc_port_ready() {
    local port="$1"
    (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

wait_for_vnc_access() {
    if [ "$ENABLE_VNC" != "1" ]; then
        echo "Acesso VNC desabilitado por ENABLE_VNC=${ENABLE_VNC}."
        return 0
    fi

    echo "Acesso VNC é gerenciado pelo serviço s6 'vnc-access'."
    echo "Aguardando acesso VNC em 127.0.0.1:${VNC_PORT}..."

    local i
    for i in $(seq 1 30); do
        if [ "$DISPLAY_BACKEND" = "xvnc" ]; then
            if vnc_port_ready "$VNC_PORT"; then
                echo "Acesso VNC via Xvnc pronto."
                return 0
            fi
        else
            if pgrep -x x11vnc >/dev/null 2>&1 && vnc_port_ready "$VNC_PORT"; then
                echo "Acesso VNC via x11vnc pronto."
                return 0
            fi
        fi

        echo "Aguardando acesso VNC... tentativa $i/30"
        sleep 1
    done

    echo "ERRO: Acesso VNC não ficou disponível na porta ${VNC_PORT}."

    echo "Diagnóstico serviço s6 vnc-access:"
    /command/s6-svstat /run/service/vnc-access 2>/dev/null || true

    echo "Diagnóstico serviço s6 display:"
    /command/s6-svstat /run/service/display 2>/dev/null || true

    if [ "$DISPLAY_BACKEND" != "xvnc" ]; then
        echo "Diagnóstico serviço s6 window-manager:"
        /command/s6-svstat /run/service/window-manager 2>/dev/null || true
        echo "Processos x11vnc:"
        pgrep -a -x x11vnc 2>/dev/null || true
        echo "Log x11vnc:"
        cat "$VNC_LOG_FILE" 2>/dev/null || true
    else
        echo "Processos Xvnc/Xtigervnc:"
        ps -eo pid,comm | grep -E "Xvnc|Xtigervnc" | grep -v grep || true
        echo "Log Xvnc:"
        cat "$XVNC_LOG_FILE" 2>/dev/null || true
    fi

    exit 1
}

echo "WINEPREFIX=$WINEPREFIX"
echo "WINEARCH=$WINEARCH"
echo "DISPLAY=$DISPLAY"
echo "WINEDEBUG=$WINEDEBUG"
echo "MT5_EXE=$MT5_EXE"

echo "Backend gráfico é gerenciado pelo serviço s6 'display'."
echo "Aguardando DISPLAY=$DISPLAY ficar disponível..."
for i in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "X server pronto."
        break
    fi

    echo "Aguardando X server... tentativa $i/30"
    sleep 1
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "ERRO: X server não ficou disponível em $DISPLAY."

    echo "Diagnóstico serviço s6 display:"
    /command/s6-svstat /run/service/display 2>/dev/null || true

    echo "Processos gráficos:"
    ps -ef | grep -E "Xvnc|Xtigervnc|Xvfb" | grep -v grep || true

    echo "Log Xvnc:"
    cat "$XVNC_LOG_FILE" 2>/dev/null || true

    exit 1
fi

echo "Window manager é gerenciado pelo serviço s6 'window-manager'."
echo "Aguardando Openbox ficar disponível..."
for i in $(seq 1 30); do
    if pgrep -x openbox >/dev/null 2>&1; then
        echo "Openbox pronto."
        break
    fi

    echo "Aguardando Openbox... tentativa $i/30"
    sleep 1
done

if ! pgrep -x openbox >/dev/null 2>&1; then
    echo "ERRO: Openbox não ficou disponível."

    echo "Diagnóstico serviço s6 window-manager:"
    /command/s6-svstat /run/service/window-manager 2>/dev/null || true

    echo "Diagnóstico serviço s6 display:"
    /command/s6-svstat /run/service/display 2>/dev/null || true

    echo "Processos gráficos:"
    ps -ef | grep -E "openbox|Xvnc|Xtigervnc|Xvfb" | grep -v grep || true

    echo "Log Openbox:"
    cat /tmp/openbox.log 2>/dev/null || true

    exit 1
fi

echo "Processos gráficos ativos:"
ps -ef | grep -E "Xvnc|Xtigervnc|Xvfb|x11vnc|openbox" | grep -v grep || true

wait_for_vnc_access

echo "Wine bootstrap é gerenciado pelo oneshot s6 'wine-bootstrap' e já foi concluído antes do CMD."

echo "Etapa de instalação/validação do MT5 é gerenciada pelo oneshot s6 'install-mt5' e já foi processada antes do CMD."

##########################

RUN_MT5="${RUN_MT5:-1}"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"

if [ "$RUN_MT5" = "1" ]; then
    echo "RUN_MT5=1. Iniciando MetaTrader 5..."
    echo "MT5_EXE=$MT5_EXE"
    echo "MT5_CMD_OPTIONS=$MT5_CMD_OPTIONS"

    if [ ! -f "$MT5_EXE" ]; then
        echo "ERRO: RUN_MT5=1, mas MT5_EXE não foi encontrado:"
        echo "$MT5_EXE"
        echo "Execute antes com INSTALL_MT5=1 MT5_INSTALL_MODE=manual."
        exit 1
    fi

    echo "Deploy MQL5 é gerenciado pelo oneshot s6 'deploy-mql5' e já foi processado antes do CMD."
    echo "Configuração NT5 é gerenciada pelo oneshot s6 'configure-nt5' e já foi processada antes do CMD."
    echo "Bootstrap Python é gerenciado pelo oneshot s6 'python-bootstrap' e já foi processado antes do CMD."

    MT5_EXE="$MT5_EXE" \
    MT5_CMD_OPTIONS="$MT5_CMD_OPTIONS" \
    /scripts/mt5_lifecycle.sh &

    MT5_LIFECYCLE_PID=$!
    echo "MT5 lifecycle iniciado com PID=$MT5_LIFECYCLE_PID"

    if [ "${RUN_BRIDGE:-1}" = "1" ]; then
        echo "RUN_BRIDGE=1. Bridge RPyC será iniciada em background após MT5 responder."
        /scripts/start_bridge.sh &
        BRIDGE_PID=$!
        echo "Bridge RPyC PID=$BRIDGE_PID (porta ${RPYC_PORT:-18812})"
    else
        echo "RUN_BRIDGE=${RUN_BRIDGE:-0}. Bridge não será iniciada."
    fi

    echo "Container permanecerá ativo enquanto o MT5 lifecycle estiver ativo."
    set +e
    wait "$MT5_LIFECYCLE_PID"
    MT5_LIFECYCLE_STATUS=$?
    set -e

    echo "MT5 lifecycle terminou com código: $MT5_LIFECYCLE_STATUS"

    if [ "$MT5_LIFECYCLE_STATUS" -ne 0 ]; then
        exit "$MT5_LIFECYCLE_STATUS"
    fi
else
    echo "RUN_MT5=$RUN_MT5. MT5 instalado/validado, mas não iniciado."
fi

echo "Finalizando entrypoint."
exit 0
