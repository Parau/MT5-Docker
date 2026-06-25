#!/bin/bash
set -e

echo "Iniciando preparação do ambiente MetaTrader 5 Headless..."

# 1. Inicializa o prefixo do Wine se ele não existir no volume persistente
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    echo "Configurando prefixo do Wine pela primeira vez..."
    winecfg /v win10
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
    xvfb-run -a wine64 /opt/mt5/mt5setup.exe /auto
    sleep 10
fi

# 4. DRIBLE DO LIVEUPDATE: Sabota o atualizador automático criando um link simbólico falso.
# Isso impede que o MT5 tente rodar um instalador visual em background que travaria o container.
UPDATE_DIR="$WINEPREFIX/drive_c/users/root/AppData/Roaming/MetaQuotes/WebInstall/Updates"
mkdir -p "$UPDATE_DIR"
rm -f "$UPDATE_DIR/LiveUpdate.exe"
ln -sf /dev/null "$UPDATE_DIR/LiveUpdate.exe"
echo "Bypass do LiveUpdate configurado com sucesso."

# 5. Passa o controle para o Supervisor orquestrar os processos internos
echo "Repassando controle de processos para o Supervisor..."
exec supervisord -c /etc/supervisor/supervisord.conf