FROM ubuntu:22.04

# Evita prompts interativos durante a instalação de pacotes
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV DISPLAY=:1
ENV PATH="/opt/wine-staging/bin:${PATH}"

# 1. Dependências base + suporte gráfico + repositórios
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg2 \
        software-properties-common \
        xvfb \
        x11vnc \
        supervisor \
        winbind \
        cabextract \
        dbus-x11 \
        libvulkan1 \
        libgl1 \
        libxrender1 \
        libxext6 \
        libxi6 \
        libxrandr2 \
        libxinerama1 \
        libxcursor1 \
        libxcomposite1 \
        libasound2 \
        fonts-liberation \
        procps \
    && add-apt-repository -y multiverse \
    && echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends ttf-mscorefonts-installer \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources \
    && apt-get update \
    && apt-get install --install-recommends -y winehq-staging \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Validação explícita do Wine no build
RUN wine --version && which wine

# 3. Baixar Wine Gecko e Mono em modo silencioso
RUN mkdir -p /usr/share/wine/gecko /usr/share/wine/mono && \
    wget -O /usr/share/wine/gecko/wine-gecko-2.47.4-x86_64.msi https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.msi && \
    wget -O /usr/share/wine/mono/wine-mono-9.3.0-x86.msi https://dl.winehq.org/wine/wine-mono/9.3.0/wine-mono-9.3.0-x86.msi

# 4. Preparar o diretório de trabalho e baixar o instalador oficial do MT5
WORKDIR /opt/mt5
RUN wget -O mt5setup.exe https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

# 5. Copiar arquivos de configuração da orquestração interna
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /config/.wine

ENTRYPOINT ["/entrypoint.sh"]