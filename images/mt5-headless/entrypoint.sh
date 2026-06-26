#!/bin/bash
set -e

echo "Iniciando preparação do ambiente MetaTrader 5 Headless..."

# 1. Inicializa o prefixo do Wine se ele não existir no volume persistente
WINE_READY_MARKER="$WINEPREFIX/.tu_wine_initialized"

if [ ! -f "$WINE_READY_MARKER" ]; then
    echo "Configurando prefixo do Wine pela primeira vez..."

    mkdir -p "$WINEPREFIX"

    # Limpa conteúdo anterior incompleto, sem remover o mountpoint do volume Docker.
    find "$WINEPREFIX" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    echo "Iniciando Xvfb temporário para inicialização do Wine..."
    export DISPLAY=:99
    export XDG_RUNTIME_DIR=/tmp/runtime-root

    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    Xvfb :99 -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
    XVFB_PID=$!

    sleep 3

    echo "Inicializando Wine prefix..."
    timeout 120s wineboot --init || echo "wineboot retornou erro/timeout; validando prefixo mesmo assim..."
    timeout 120s wineserver -w || true

    echo "Configurando Wine para Windows 10..."
    wine reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d win10 /f || true
    wineserver -w || true

    echo "Finalizando Xvfb temporário..."
    kill "$XVFB_PID" || true
    wait "$XVFB_PID" 2>/dev/null || true

    if [ ! -f "$WINEPREFIX/drive_c/windows/system32/kernel32.dll" ]; then
        echo "ERRO: Wine prefix não foi criado corretamente. kernel32.dll não encontrado."
        exit 1
    fi

    touch "$WINE_READY_MARKER"
    sleep 5
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

# 3. Executar o instalador silencioso se o terminal ainda não estiver instalado
MT5_EXECUTABLE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXECUTABLE" ]; then
    echo "Executando instalação silenciosa do MetaTrader 5..."
    # Garante que a tela virtual fique aberta até o instalador do MT5 concluir e fechar o servidor
    xvfb-run -a sh -c "wine /opt/mt5/mt5setup.exe /auto && wineserver -w"
    sleep 10
fi

# 4. DRIBLE DO LIVEUPDATE: Sabota o atualizador automático criando um link simbólico falso.
UPDATE_DIR="$WINEPREFIX/drive_c/users/root/AppData/Roaming/MetaQuotes/WebInstall/Updates"
mkdir -p "$UPDATE_DIR"
rm -f "$UPDATE_DIR/LiveUpdate.exe"
ln -sf /dev/null "$UPDATE_DIR/LiveUpdate.exe"
echo "Bypass do LiveUpdate configurado com sucesso."

# 5. Passa o controle para o Supervisor orquestrar os processos internos
echo "Repassando controle de processos para o Supervisor..."
exec supervisord -c /etc/supervisor/supervisord.conf