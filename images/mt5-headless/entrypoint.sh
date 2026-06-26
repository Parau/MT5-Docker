#!/bin/bash
set -e

echo "Iniciando preparação do ambiente MetaTrader 5 Headless..."

: "${MT5_LOGIN:?MT5_LOGIN is required}"
: "${MT5_PASSWORD:?MT5_PASSWORD is required}"
: "${MT5_SERVER:?MT5_SERVER is required}"

export WINEDEBUG=-all

MT5_EXECUTABLE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
MT5_INSTALLER="$WINEPREFIX/drive_c/mt5setup.exe"
MT5_READY_MARKER="$WINEPREFIX/.tu_mt5_installed"

# 1. Instala/recupera o ambiente MT5 se ele ainda não estiver pronto
if [ ! -f "$MT5_EXECUTABLE" ]; then
    echo "MetaTrader 5 ainda não encontrado. Preparando instalação limpa..."

    mkdir -p "$WINEPREFIX"

    # Como não há MT5 instalado, limpamos qualquer prefixo parcial anterior.
    find "$WINEPREFIX" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    echo "Iniciando Xvfb temporário para bootstrap e instalação..."
    export DISPLAY=:99
    export XDG_RUNTIME_DIR=/tmp/runtime-root

    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    Xvfb :99 -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
    XVFB_PID=$!

    cleanup_bootstrap() {
        echo "Finalizando processos temporários..."
        wineserver -k || true
        kill "$XVFB_PID" || true
        wait "$XVFB_PID" 2>/dev/null || true
    }

    trap cleanup_bootstrap EXIT

    sleep 3

    echo "Configurando Wine para Windows 10..."
    timeout 90s wine reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d win10 /f || true

    echo "Aguardando processos iniciais do Wine terminarem..."
    for i in $(seq 1 180); do
        if ! pgrep -f "wineboot.exe|winedevice.exe|rundll32.exe setupapi" >/dev/null; then
            echo "Processos iniciais do Wine finalizados."
            break
        fi

        echo "Wine ainda inicializando... tentativa $i/180"
        sleep 2
    done

    if pgrep -f "wineboot.exe|winedevice.exe|rundll32.exe setupapi" >/dev/null; then
        echo "ERRO: Wine bootstrap não terminou dentro do tempo esperado."
        ps -ef | grep -E "wineboot|winedevice|rundll32|wineserver" | grep -v grep || true
        exit 1
    fi

    WINE_KERNEL32_64="$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
    WINE_KERNEL32_32="$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll"

    echo "Validando Wine prefix 64-bit e 32-bit..."
    if [ ! -f "$WINE_KERNEL32_64" ] || [ ! -f "$WINE_KERNEL32_32" ]; then
        echo "ERRO: Wine prefix incompleto."
        echo "64-bit: $WINE_KERNEL32_64"
        echo "32-bit: $WINE_KERNEL32_32"
        exit 1
    fi

    echo "Validando execução básica do Wine..."
    timeout 60s wine cmd /c ver || {
        echo "ERRO: Wine prefix existe, mas ainda não executa comandos básicos."
        exit 1
    }

    echo "Copiando instalador do MT5 para o drive_c..."
    mkdir -p "$(dirname "$MT5_INSTALLER")"
    cp /opt/mt5/mt5setup.exe "$MT5_INSTALLER"

    echo "Executando instalação silenciosa do MetaTrader 5..."
    timeout 600s wine "$MT5_INSTALLER" /auto || echo "Instalador retornou erro/timeout; verificando instalação..."

    echo "Aguardando finalização curta do Wine..."
    timeout 120s wineserver -w || true

    rm -f "$MT5_INSTALLER"

    if [ ! -f "$MT5_EXECUTABLE" ]; then
        echo "ERRO: MetaTrader 5 não foi instalado. terminal64.exe não encontrado."
        exit 1
    fi

    touch "$MT5_READY_MARKER"

    trap - EXIT
    cleanup_bootstrap

    sleep 5
else
    echo "MetaTrader 5 já instalado."
fi

# 2. Criar estrutura de caminhos para injetar a configuração do MT5
WINE_MT5_DIR="$WINEPREFIX/drive_c/mt5"
mkdir -p "$WINE_MT5_DIR"

echo "Injetando parâmetros de inicialização automatizada (config.ini)..."
cat <<EOF > "$WINE_MT5_DIR/config.ini"
[Common]
Login=$MT5_LOGIN
Password=$MT5_PASSWORD
Server=$MT5_SERVER
ProxyEnable=0
KeepPassword=1
[Charts]
Profile=default
MaxBars=50000
EOF

chmod 600 "$WINE_MT5_DIR/config.ini"

# 3. Bypass opcional do LiveUpdate
if [ "${MT5_DISABLE_LIVEUPDATE:-1}" = "1" ]; then
    UPDATE_DIR="$WINEPREFIX/drive_c/users/root/AppData/Roaming/MetaQuotes/WebInstall/Updates"
    mkdir -p "$UPDATE_DIR"
    rm -f "$UPDATE_DIR/LiveUpdate.exe"
    ln -sf /dev/null "$UPDATE_DIR/LiveUpdate.exe"
    echo "Bypass do LiveUpdate configurado com sucesso."
else
    echo "Bypass do LiveUpdate desativado."
fi

# 4. Passa o controle para o Supervisor orquestrar os processos internos
echo "Repassando controle de processos para o Supervisor..."
exec supervisord -c /etc/supervisor/supervisord.conf