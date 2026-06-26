#!/bin/bash
set -Eeuo pipefail

echo "Iniciando teste Debian Bookworm + WineHQ com fluxo inspirado no gmag11 e no setup oficial da MetaTrader..."

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

RESET_WINEPREFIX="${RESET_WINEPREFIX:-0}"
BOOTSTRAP_TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT_SECONDS:-420}"

MONO_URL="${MONO_URL:-https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi}"
INSTALL_MT5="${INSTALL_MT5:-0}"
MT5_SETUP_URL="${MT5_SETUP_URL:-https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe}"
MT5_INSTALLER="$WINEPREFIX/drive_c/mt5setup.exe"
MT5_EXE="${MT5_EXE:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe}"

WEBVIEW_URL="${WEBVIEW_URL:-https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f2910a1e-e5a6-4f17-b52d-7faf525d17f8/MicrosoftEdgeWebview2Setup.exe}"
WEBVIEW_INSTALLER="$WINEPREFIX/drive_c/webview2.exe"
MT5_INSTALL_MODE="${MT5_INSTALL_MODE:-manual}"

ENABLE_VNC="${ENABLE_VNC:-1}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_LOG_FILE="${VNC_LOG_FILE:-/tmp/x11vnc.log}"

XVFB_PID=""
OPENBOX_PID=""

cleanup() {
    echo "Finalizando processos temporários..."
    wineserver -k || true

    if [ -n "${OPENBOX_PID}" ]; then
        kill "${OPENBOX_PID}" 2>/dev/null || true
        wait "${OPENBOX_PID}" 2>/dev/null || true
    fi

    if [ -n "${XVFB_PID}" ]; then
        kill "${XVFB_PID}" 2>/dev/null || true
        wait "${XVFB_PID}" 2>/dev/null || true
    fi

    pkill x11vnc 2>/dev/null || true
}

trap cleanup EXIT

run_wine_nonfatal() {
    local label="$1"
    shift

    echo "$label"

    set +e
    timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" "$@"
    local status=$?
    set -e

    echo "$label retornou código: $status"

    if [ "$status" -eq 124 ]; then
        echo "AVISO: comando atingiu timeout, mas não vamos abortar imediatamente."
    elif [ "$status" -ne 0 ]; then
        echo "AVISO: comando retornou erro, mas não vamos abortar imediatamente."
    fi

    echo "Processos Wine após: $label"
    ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true

    echo "kernel32.dll encontrados após: $label"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
}

wait_for_wine_bootstrap() {
    echo "Aguardando estabilização dos processos iniciais do Wine..."

    for i in $(seq 1 "$BOOTSTRAP_TIMEOUT_SECONDS"); do
        HAS_64=0
        HAS_32=0
        HAS_BOOT_PROCS=0

        [ -f "$WINEPREFIX/drive_c/windows/system32/kernel32.dll" ] && HAS_64=1
        [ -f "$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll" ] && HAS_32=1

        if pgrep -f "wineboot.exe|winedevice.exe|rundll32.exe setupapi" >/dev/null; then
            HAS_BOOT_PROCS=1
        fi

        if [ "$HAS_64" = "1" ] && [ "$HAS_32" = "1" ] && [ "$HAS_BOOT_PROCS" = "0" ]; then
            echo "Bootstrap do Wine parece concluído."
            return 0
        fi

        if [ $((i % 10)) -eq 0 ]; then
            echo "Aguardando Wine... ${i}/${BOOTSTRAP_TIMEOUT_SECONDS}s | kernel32_64=$HAS_64 kernel32_32=$HAS_32 boot_procs=$HAS_BOOT_PROCS"
            ps -ef | grep -E "wineboot|winedevice|rundll32|wineserver" | grep -v grep || true
            find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
        fi

        sleep 1
    done

    echo "AVISO: Wine não atingiu estado totalmente estável dentro do tempo esperado."
    return 1
}

start_vnc() {
    if [ "$ENABLE_VNC" != "1" ]; then
        echo "ENABLE_VNC=$ENABLE_VNC. VNC não será iniciado."
        return 0
    fi

    echo "Iniciando x11vnc na porta interna $VNC_PORT..."

    pkill x11vnc 2>/dev/null || true
    rm -f "$VNC_LOG_FILE"

    if [ -n "$VNC_PASSWORD" ]; then
        echo "VNC com senha habilitada."
        x11vnc \
            -display "$DISPLAY" \
            -listen 0.0.0.0 \
            -forever \
            -shared \
            -passwd "$VNC_PASSWORD" \
            -rfbport "$VNC_PORT" \
            -noxdamage \
            >"$VNC_LOG_FILE" 2>&1 &
    else
        echo "VNC sem senha habilitado. Use apenas com porta publicada em localhost."
        x11vnc \
            -display "$DISPLAY" \
            -listen 0.0.0.0 \
            -forever \
            -shared \
            -nopw \
            -rfbport "$VNC_PORT" \
            -noxdamage \
            >"$VNC_LOG_FILE" 2>&1 &
    fi

    VNC_PID=$!
    sleep 1

    if kill -0 "$VNC_PID" 2>/dev/null; then
        echo "x11vnc iniciado com PID=$VNC_PID"
        echo "VNC disponível na porta interna $VNC_PORT"
    else
        echo "ERRO: x11vnc não iniciou corretamente. Log:"
        cat "$VNC_LOG_FILE" || true
        return 1
    fi
}

echo "Wine:"
wine --version
which wine

echo "WINEPREFIX=$WINEPREFIX"
echo "WINEARCH=$WINEARCH"
echo "DISPLAY=$DISPLAY"
echo "WINEDEBUG=$WINEDEBUG"
echo "BOOTSTRAP_TIMEOUT_SECONDS=$BOOTSTRAP_TIMEOUT_SECONDS"
echo "INSTALL_MT5=$INSTALL_MT5"
echo "MT5_INSTALL_MODE=$MT5_INSTALL_MODE"
echo "MT5_EXE=$MT5_EXE"

mkdir -p "$WINEPREFIX"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

if [ "$RESET_WINEPREFIX" = "1" ]; then
    echo "RESET_WINEPREFIX=1. Limpando conteúdo do prefixo Wine..."
    find "$WINEPREFIX" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
    echo "RESET_WINEPREFIX=$RESET_WINEPREFIX. Preservando prefixo existente."
fi

echo "Iniciando Xvfb..."
Xvfb "$DISPLAY" -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
XVFB_PID=$!

echo "Aguardando X server responder..."
for i in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "X server pronto."
        break
    fi

    echo "Aguardando X server... tentativa $i/30"
    sleep 1
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "ERRO: Xvfb não ficou disponível em $DISPLAY."
    exit 1
fi

echo "Iniciando openbox como window manager mínimo..."
openbox >/tmp/openbox.log 2>&1 &
OPENBOX_PID=$!

sleep 2

echo "Processos gráficos ativos:"
ps -ef | grep -E "Xvfb|openbox" | grep -v grep || true

start_vnc

if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
    echo "Wine Mono não encontrado. Baixando Wine Mono..."
    curl -fL --retry 3 -o /tmp/wine-mono.msi "$MONO_URL"

    run_wine_nonfatal \
        "Instalando Wine Mono para disparar bootstrap do prefixo..." \
        env WINEDLLOVERRIDES=mscoree=d wine msiexec /i /tmp/wine-mono.msi /qn

    echo "Aguardando wineserver após Mono..."
    timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineserver -w || true

    rm -f /tmp/wine-mono.msi
else
    echo "Wine Mono já instalado."
fi

echo "Configurando Wine para Windows 11, seguindo o setup oficial da MetaTrader..."
set +e
winecfg -v=win11
WINECFG_STATUS=$?
set -e

echo "winecfg win11 retornou código: $WINECFG_STATUS"

echo "Aguardando wineserver após winecfg win11..."
timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineserver -w || true

wait_for_wine_bootstrap || true

echo "Estado final dos processos Wine:"
ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true

echo "Arquivos kernel32 encontrados:"
find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true

WINE_KERNEL32_64="$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
WINE_KERNEL32_32="$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll"

echo "Validando kernel32.dll 64-bit e 32-bit..."
if [ ! -f "$WINE_KERNEL32_64" ]; then
    echo "ERRO: kernel32.dll 64-bit não encontrado em $WINE_KERNEL32_64"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

if [ ! -f "$WINE_KERNEL32_32" ]; then
    echo "ERRO: kernel32.dll 32-bit não encontrado em $WINE_KERNEL32_32"
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

echo "kernel32.dll 64-bit encontrado:"
ls -la "$WINE_KERNEL32_64"

echo "kernel32.dll 32-bit encontrado:"
ls -la "$WINE_KERNEL32_32"

echo "Validando execução básica do Wine..."
timeout 60s wine cmd /c ver

echo "Validando comando simples no Wine..."
timeout 60s wine cmd /c echo Wine bootstrap OK

if [ "$INSTALL_MT5" = "1" ]; then
    echo "INSTALL_MT5=1. Iniciando etapa de instalação do MetaTrader 5..."

    if [ -f "$MT5_EXE" ]; then
        echo "MT5 já instalado:"
        ls -la "$MT5_EXE"
    else
        echo "MT5 ainda não encontrado em:"
        echo "$MT5_EXE"

        echo "Baixando MetaTrader e WebView2 Runtime, seguindo a ordem do setup oficial..."
        curl "$MT5_SETUP_URL" --output "$MT5_INSTALLER"
        curl "$WEBVIEW_URL" --output "$WEBVIEW_INSTALLER"

        echo "Instalador MT5 baixado:"
        ls -lh "$MT5_INSTALLER" || true

        echo "Instalador WebView2 baixado:"
        ls -lh "$WEBVIEW_INSTALLER" || true

        echo "Instalando WebView2 Runtime, como no setup oficial..."
        set +e
        wine "$WEBVIEW_INSTALLER" /silent /install
        WEBVIEW_STATUS=$?
        set -e

        echo "WebView2 retornou código: $WEBVIEW_STATUS"

        echo "Instalando MetaTrader 5. MT5_INSTALL_MODE=$MT5_INSTALL_MODE"
        set +e

        if [ "$MT5_INSTALL_MODE" = "auto" ]; then
            echo "Modo auto: executando MT5 com /auto, estilo gmag11."
            wine "$MT5_INSTALLER" "/auto" &
            MT5_INSTALL_PID=$!
            wait "$MT5_INSTALL_PID"
            MT5_INSTALL_STATUS=$?
        else
            echo "Modo manual: executando MT5 sem /auto, como no setup oficial da MetaTrader."
            wine "$MT5_INSTALLER"
            MT5_INSTALL_STATUS=$?
        fi

        set -e

        echo "Instalador MT5 retornou código: $MT5_INSTALL_STATUS"

        rm -f "$WEBVIEW_INSTALLER"
        rm -f "$MT5_INSTALLER"

        if [ ! -f "$MT5_EXE" ]; then
            echo "ERRO: terminal64.exe não encontrado após instalação."
            echo "Procurando terminal64.exe dentro do prefixo..."
            find "$WINEPREFIX/drive_c" -iname "terminal64.exe" 2>/dev/null || true
            exit 1
        fi

        echo "MT5 instalado com sucesso:"
        ls -la "$MT5_EXE"
    fi
else
    echo "INSTALL_MT5=$INSTALL_MT5. Etapa de instalação do MT5 ignorada."
fi

# ATE AQUI FOI PARA INSTALAR AGORA COMENTO PARA INICIAR O MT5
# echo "SUCESSO: Debian Bookworm + WineHQ validado e etapa MT5 concluída. O MT5 ainda não foi iniciado como serviço."
# exit 0

##########################

RUN_MT5="${RUN_MT5:-1}"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"

if [ "$RUN_MT5" = "1" ]; then
    echo "RUN_MT5=1. Iniciando MetaTrader 5..."
    echo "MT5_EXE=$MT5_EXE"
    echo "MT5_CMD_OPTIONS=$MT5_CMD_OPTIONS"

    wine "$MT5_EXE" $MT5_CMD_OPTIONS &

    MT5_PID=$!
    echo "MetaTrader 5 iniciado com PID=$MT5_PID"
    echo "Container permanecerá ativo enquanto o MT5 estiver rodando."

    wait "$MT5_PID"
else
    echo "RUN_MT5=$RUN_MT5. MT5 instalado/validado, mas não iniciado."
fi

echo "Finalizando entrypoint."
exit 0