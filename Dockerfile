ARG LOCAL_CODEX_BASE_IMAGE=ubuntu:22.04
FROM ${LOCAL_CODEX_BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LOCAL_CODEX_OFFICIAL_PULL_MODELS=openai/gpt-oss-20b
ARG LOCAL_CODEX_RUNTIME_USER=codex
ARG LOCAL_CODEX_RUNTIME_UID=1000
ARG LOCAL_CODEX_RUNTIME_GID=1000
ARG LOCAL_CODEX_TOOLCHAIN_PATH=/opt/local-codex-kit/toolchain-store
ARG LOCAL_CODEX_MODEL_MANIFEST=/opt/local-codex-kit/official-models.manifest.json
ARG LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B=openai-gpt-oss-20b:1.0.0
ARG LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B=
ARG TOOLCHAIN_MODULE_VERSION=2.0.6
ARG TOOLCHAIN_TOKEN=
ARG TOOLCHAIN_USERNAME=
ARG TOOLCHAIN_PASSWORD=
ARG NODE_LINUX_ARCHIVE_URL=https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz
ARG HELM_VERSION=v4.1.1
ARG ZARF_VERSION=v0.73.1

WORKDIR /opt/local-codex-kit

RUN set -eux \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        build-essential \
        ca-certificates \
        clang \
        curl \
        git \
        gnupg \
        golang-go \
        jq \
        nano \
        python-is-python3 \
        python3 \
        python3-pip \
        python3-venv \
        software-properties-common \
        unzip \
        vim-tiny \
        wget \
        xz-utils \
        zstd \
    && install -d -m 0755 /etc/apt/keyrings /usr/local/bin \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --batch --yes --dearmor > /etc/apt/keyrings/microsoft.gpg \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --batch --yes --dearmor > /etc/apt/keyrings/google-chrome.gpg \
    && chmod 0644 /etc/apt/keyrings/microsoft.gpg /etc/apt/keyrings/google-chrome.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && wget -qO /tmp/packages-microsoft-prod.deb https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends code google-chrome-stable powershell \
    && PWSH_BIN="$(command -v pwsh || true)" \
    && if [ -z "$PWSH_BIN" ]; then PWSH_BIN="$(find /opt/microsoft -type f -name pwsh 2>/dev/null | head -n 1 || true)"; fi \
    && test -n "$PWSH_BIN" \
    && ln -sf "$PWSH_BIN" /usr/local/bin/pwsh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux \
    && fetch() { curl --fail --show-error --silent --location --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 --max-time 600 "$@"; } \
    && fetch "${NODE_LINUX_ARCHIVE_URL}" | tar -xJ --strip-components=1 -C /usr/local \
    && npm install -g @openai/codex \
    && /usr/local/bin/pwsh -NoLogo -NoProfile -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module Toolchain -RequiredVersion '${TOOLCHAIN_MODULE_VERSION}' -Scope AllUsers -Force"

RUN set -eux \
    && python -m pip install --no-cache-dir \
        'torch>=2.8.0' \
        'transformers[serving]>=5.2.0' \
        'accelerate>=1.10.0' \
        'safetensors>=0.6.0'

RUN set -eux \
    && fetch() { curl --fail --show-error --silent --location --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 --max-time 600 "$@"; } \
    && fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && install /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64 \
    && fetch "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_amd64" -o /usr/local/bin/zarf \
    && chmod +x /usr/local/bin/zarf \
    && ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chromium

ENV LOCAL_CODEX_RUNTIME_USER=${LOCAL_CODEX_RUNTIME_USER}
ENV HOME=/home/${LOCAL_CODEX_RUNTIME_USER}
ENV CODEX_HOME=/home/${LOCAL_CODEX_RUNTIME_USER}/.codex
ENV LOCAL_CODEX_TOOLCHAIN_PATH=${LOCAL_CODEX_TOOLCHAIN_PATH}
ENV LOCAL_CODEX_MODEL_MANIFEST=${LOCAL_CODEX_MODEL_MANIFEST}
ENV LOCAL_CODEX_OFFICIAL_PULL_MODELS=${LOCAL_CODEX_OFFICIAL_PULL_MODELS}
ENV LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B=${LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B}
ENV LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B=${LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B}

COPY . .

RUN set -eux \
    && if ! getent group "${LOCAL_CODEX_RUNTIME_GID}" >/dev/null; then groupadd --gid "${LOCAL_CODEX_RUNTIME_GID}" "${LOCAL_CODEX_RUNTIME_USER}"; fi \
    && if ! id -u "${LOCAL_CODEX_RUNTIME_USER}" >/dev/null 2>&1; then useradd --uid "${LOCAL_CODEX_RUNTIME_UID}" --gid "${LOCAL_CODEX_RUNTIME_GID}" --create-home --shell /bin/bash "${LOCAL_CODEX_RUNTIME_USER}"; fi \
    && install -d -m 0755 -o "${LOCAL_CODEX_RUNTIME_UID}" -g "${LOCAL_CODEX_RUNTIME_GID}" \
        /workspace \
        "${CODEX_HOME}" \
        "${HOME}/.cache" \
        "${HOME}/.config/powershell" \
        "${LOCAL_CODEX_TOOLCHAIN_PATH}" \
    && cp /opt/local-codex-kit/docker-profile.ps1 "${HOME}/.config/powershell/Microsoft.PowerShell_profile.ps1" \
    && install -m 0755 /opt/local-codex-kit/docker-code-wrapper.sh /usr/local/bin/code

RUN set -eux \
    && HOME="${HOME}" LOCAL_CODEX_TOOLCHAIN_PATH="${LOCAL_CODEX_TOOLCHAIN_PATH}" LOCAL_CODEX_MODEL_MANIFEST="${LOCAL_CODEX_MODEL_MANIFEST}" LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B="${LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B}" LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B="${LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B}" TOOLCHAIN_TOKEN="${TOOLCHAIN_TOKEN}" TOOLCHAIN_USERNAME="${TOOLCHAIN_USERNAME}" TOOLCHAIN_PASSWORD="${TOOLCHAIN_PASSWORD}" /usr/local/bin/pwsh -NoLogo -NoProfile -File ./pull-official-models.ps1 -Models "${LOCAL_CODEX_OFFICIAL_PULL_MODELS}" \
    && chown -R "${LOCAL_CODEX_RUNTIME_UID}:${LOCAL_CODEX_RUNTIME_GID}" "${HOME}" /workspace "${LOCAL_CODEX_TOOLCHAIN_PATH}"

USER ${LOCAL_CODEX_RUNTIME_USER}

ENTRYPOINT ["/usr/local/bin/pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
