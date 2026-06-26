FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV DISPLAY=:99
ENV WINEDEBUG=-all
ENV PATH="/opt/wine-stable/bin:${PATH}"

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg2 \
        xvfb \
        openbox \
        x11-utils \
        x11vnc \
        procps \
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
        tigervnc-standalone-server \
        tigervnc-tools \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install --install-recommends -y \
        winehq-stable=10.0.0.0~bookworm-1 \
        wine-stable=10.0.0.0~bookworm-1 \
        wine-stable-amd64=10.0.0.0~bookworm-1 \
        wine-stable-i386:i386=10.0.0.0~bookworm-1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN wine --version && which wine

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /config/.wine

ENTRYPOINT ["/entrypoint.sh"]