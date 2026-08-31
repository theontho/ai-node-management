FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG ORCA_VERSION=1.4.192
ARG ORCA_APPIMAGE_SHA256=9003e78c6c0287c5173569bc91529da4a9963b2d4245fd23701651799abca77c
ARG UBUNTU_SNAPSHOT=20260829T000000Z

ENV DEBIAN_FRONTEND=noninteractive

ADD https://snapshot.ubuntu.com/ubuntu/20260829T000000Z/pool/main/c/ca-certificates/ca-certificates_20240203_all.deb /tmp/ca-certificates.deb

RUN echo "641de77d8f142cfd62a1a6f964ba67b20754d3337c480efb529d086075a06c9a  /tmp/ca-certificates.deb" \
      | sha256sum --check --strict \
    && install -d -m 0755 /tmp/ca-root /etc/ssl/certs \
    && dpkg-deb --extract /tmp/ca-certificates.deb /tmp/ca-root \
    && find /tmp/ca-root/usr/share/ca-certificates -type f -name '*.crt' -print0 \
      | sort -z \
      | xargs -0 cat \
      > /etc/ssl/certs/ca-certificates.crt \
    && rm -rf /tmp/ca-root /tmp/ca-certificates.deb

RUN sed -i -E \
      "s#https?://(archive|security).ubuntu.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#g" \
      /etc/apt/sources.list.d/ubuntu.sources \
    && printf 'Acquire::Check-Valid-Until "false";\n' \
      > /etc/apt/apt.conf.d/99snapshot \
    && test "$(dpkg --print-architecture)" = amd64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dbus-x11 \
      file \
      git \
      gnome-keyring \
      jq \
      libasound2t64 \
      libatk-bridge2.0-0t64 \
      libatk1.0-0t64 \
      libcups2t64 \
      libgtk-3-0t64 \
      libgbm1 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libatspi2.0-0t64 \
      libcairo2 \
      libdrm2 \
      libx11-xcb1 \
      libxcb-dri3-0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxrender1 \
      libxss1 \
      libxtst6 \
      libsecret-tools \
      openssh-client \
      tini \
      xvfb \
      zlib1g-dev \
    && install -d -o root -g root -m 0755 /opt/orca \
    && curl --fail --location --show-error --retry 3 \
      "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-linux.AppImage" \
      --output /opt/orca/orca-linux.AppImage \
    && echo "${ORCA_APPIMAGE_SHA256}  /opt/orca/orca-linux.AppImage" \
      | sha256sum --check --strict \
    && chmod 0755 /opt/orca/orca-linux.AppImage \
    && cd /opt/orca \
    && ./orca-linux.AppImage --appimage-extract >/dev/null \
    && chmod -R a+rX /opt/orca/squashfs-root \
    && rm -f /opt/orca/orca-linux.AppImage \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /var/lib/dbus/machine-id \
    && truncate -s 0 /etc/machine-id

RUN groupmod --new-name orca ubuntu \
    && usermod --login orca --home /home/orca --move-home --gid orca ubuntu \
    && install -d -o orca -g orca -m 0755 /workspaces \
    && install -d -o orca -g orca -m 0700 /home/orca/.local/share/keyrings \
    && rm -f /etc/machine-id \
    && ln -s /home/orca/.local/state/machine-id /etc/machine-id \
    && install -d -o root -g root -m 1777 /tmp/.X11-unix

COPY assets/orca-entrypoint /usr/local/bin/orca-entrypoint
RUN chmod 0755 /usr/local/bin/orca-entrypoint

ENV HOME=/home/orca \
    DISPLAY=:99 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    PATH=/home/orca/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    XDG_CACHE_HOME=/home/orca/.cache \
    XDG_CONFIG_HOME=/home/orca/.config \
    XDG_CURRENT_DESKTOP=GNOME \
    XDG_STATE_HOME=/home/orca/.local/state

LABEL org.opencontainers.image.source="https://github.com/stablyai/orca" \
      org.opencontainers.image.version="${ORCA_VERSION}" \
      org.opencontainers.image.base.snapshot="20260829T000000Z" \
      org.opencontainers.image.description="Headless Orca runtime for a reproducible remote development node"

USER orca
WORKDIR /workspaces

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/orca-entrypoint"]
