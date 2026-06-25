FROM ubuntu:22.04

# Evita prompts interativos durante a instalação de pacotes
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV DISPLAY=:1

# 1. Instalar dependências essenciais do sistema e X11 virtual
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg2 \
    software-properties-common \
    xvfb \
    x11vnc \
    supervisor \
    winbind \
    cabextract \
    & apt-get clean

# 2. Adicionar arquitetura i386 (obrigatória para o Wine) e chaves oficiais da WineHQ
RUN dpkg --add-architecture i386 && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources && \
    apt-get update && \
    apt-get install --install-recommends -y winehq-stable && \
    rm -rf /var/lib/apt/lists/*

# 3. Baixar e instalar Wine Gecko e Mono em modo silencioso 
# (Evita que o contêiner trave pedindo download de interface gráfica na primeira execução)
RUN mkdir -p /usr/share/wine/gecko /usr/share/wine/mono && \
    wget -O /usr/share/wine/gecko/wine-gecko-2.47.4-x86_64.msi https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.msi && \
    wget -O /usr/share/wine/mono/wine-mono-9.3.0-x86.msi https://dl.winehq.org/wine/wine-mono/9.3.0/wine-mono-9.3.0-x86.msi

# 4. Preparar o diretório de trabalho e baixar o instalador oficial do MT5
WORKDIR /opt/mt5
RUN wget https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

# 5. Copiar arquivos de configuração da orquestração interna
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Define o volume para persistência de dados do MT5 e credenciais salvas do Wine
VOLUME /config/.wine

ENTRYPOINT ["/entrypoint.sh"]