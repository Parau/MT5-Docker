#!/bin/bash
set -Eeuo pipefail

echo "Iniciando teste Debian Bookworm + WineHQ stable..."

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

RESET_WINEPREFIX="${RESET_WINEPREFIX:-1}"
BOOTSTRAP_TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT_SECONDS:-420}"

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
}

trap cleanup EXIT

echo "Wine:"
wine --version
which wine

echo "WINEPREFIX=$WINEPREFIX"
echo "WINEARCH=$WINEARCH"
echo "DISPLAY=$DISPLAY"

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

echo "Inicializando Wine prefix com wineboot --init..."
if ! timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineboot --init; then
    echo "ERRO: wineboot --init falhou ou atingiu timeout."
    ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

echo "Aguardando wineserver finalizar operações pendentes..."
if ! timeout "${BOOTSTRAP_TIMEOUT_SECONDS}s" wineserver -w; then
    echo "ERRO: wineserver -w não finalizou dentro do tempo esperado."
    ps -ef | grep -E "wine|wineserver|wineboot|winedevice|rundll32" | grep -v grep || true
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

echo "Verificando se ainda há processos iniciais do Wine..."
if pgrep -f "wineboot.exe|winedevice.exe|rundll32.exe setupapi" >/dev/null; then
    echo "ERRO: ainda há processos iniciais do Wine ativos."
    ps -ef | grep -E "wineboot|winedevice|rundll32|wineserver" | grep -v grep || true
    find "$WINEPREFIX/drive_c/windows" -iname "kernel32.dll" 2>/dev/null || true
    exit 1
fi

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

echo "Configurando Wine para Windows 10..."
timeout 60s wine reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d win10 /f

echo "Validando execução básica do Wine..."
timeout 60s wine cmd /c ver

echo "Validando comando simples no Wine..."
timeout 60s wine cmd /c echo Wine bootstrap OK

echo "SUCESSO: Debian Bookworm + WineHQ stable validado. Nenhuma instalação do MT5 foi executada."
exit 0