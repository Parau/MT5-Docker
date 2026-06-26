FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV DISPLAY=:99
ENV PATH="/opt/wine-staging/bin:${PATH}"

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg2 \
        software-properties-common \
        xvfb \
        openbox \
        x11-utils \
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
        fonts-dejavu-core \
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

RUN wine --version && which wine

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /config/.wine

ENTRYPOINT ["/entrypoint.sh"]