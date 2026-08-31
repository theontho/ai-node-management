FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG ORCA_VERSION=1.4.192
ARG ORCA_APPIMAGE_SHA256=9003e78c6c0287c5173569bc91529da4a9963b2d4245fd23701651799abca77c
ARG UBUNTU_SNAPSHOT=20260829T000000Z
ARG NODE_VERSION=22.23.2
ARG NODE_LINUX_X64_SHA256=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307
ARG COPILOT_CLI_VERSION=1.0.82
ARG GH_VERSION=2.98.0
ARG GH_LINUX_AMD64_SHA256=3b8ac6b30336802fc1a858d7c084e11cdf24ac1a761ca90b68022d7d729208de

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
      python3 \
      python3-pip \
      python3-venv \
      python-is-python3 \
      tini \
      xz-utils \
      xvfb \
      zlib1g-dev \
    && curl --fail --location --show-error --retry 3 \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      --output /tmp/node.tar.xz \
    && echo "${NODE_LINUX_X64_SHA256}  /tmp/node.tar.xz" \
      | sha256sum --check --strict \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && npm install --global --ignore-scripts=false \
      "@github/copilot@${COPILOT_CLI_VERSION}" \
    && npm cache clean --force \
    && curl --fail --location --show-error --retry 3 \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      --output /tmp/gh.tar.gz \
    && echo "${GH_LINUX_AMD64_SHA256}  /tmp/gh.tar.gz" \
      | sha256sum --check --strict \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -o root -g root -m 0755 \
      "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64" \
    && python --version \
    && python -m venv /tmp/python-smoke \
    && /tmp/python-smoke/bin/pip --version \
    && rm -rf /tmp/python-smoke \
    && node --version \
    && npm --version \
    && copilot --version \
    && gh --version \
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
      org.opencontainers.image.node.version="${NODE_VERSION}" \
      org.opencontainers.image.copilot-cli.version="${COPILOT_CLI_VERSION}" \
      org.opencontainers.image.gh.version="${GH_VERSION}" \
      org.opencontainers.image.description="Headless Orca runtime for a reproducible remote development node"

USER orca
WORKDIR /workspaces

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/orca-entrypoint"]
