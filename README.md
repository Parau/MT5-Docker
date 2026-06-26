
# Primeira instalação / reprovisionamento
RESET_WINEPREFIX=1 \
INSTALL_MT5=1 \
RUN_MT5=0 \
MT5_INSTALL_MODE=manual \
ENABLE_VNC=1 \
docker compose up mt5-server

# Uso normal
RESET_WINEPREFIX=0 \
INSTALL_MT5=0 \
RUN_MT5=1 \
ENABLE_VNC=1 \
docker compose up mt5-server