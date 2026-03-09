FROM ubuntu:22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LOCAL_CODEX_OLLAMA_PULL_MODELS=qwen2.5-coder:7b
ARG OLLAMA_LINUX_ARCHIVE_URL=https://ollama.com/download/ollama-linux-amd64.tar.zst
ARG NODE_LINUX_ARCHIVE_URL=https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz
ARG HELM_RELEASE_API_URL=https://api.github.com/repos/helm/helm/releases/latest
ARG ZARF_RELEASE_API_URL=https://api.github.com/repos/zarf-dev/zarf/releases/latest

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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux \
    && curl -fsSL "${NODE_LINUX_ARCHIVE_URL}" | tar -xJ --strip-components=1 -C /usr/local \
    && npm install -g @openai/codex \
    && curl -fsSL "${OLLAMA_LINUX_ARCHIVE_URL}" | tar --zstd -x -C /usr \
    && HELM_VERSION="$(curl -fsSL "${HELM_RELEASE_API_URL}" | jq -r '.tag_name')" \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && install /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64 \
    && ZARF_VERSION="$(curl -fsSL "${ZARF_RELEASE_API_URL}" | jq -r '.tag_name')" \
    && curl -fsSL "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_amd64" -o /usr/local/bin/zarf \
    && chmod +x /usr/local/bin/zarf \
    && ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chromium

RUN set -eux \
    && dpkg-query -W -f='${binary:Package} ${Version}\n' code \
    && google-chrome-stable --version \
    && chromium --version \
    && git --version \
    && go version \
    && python --version \
    && python -m pip --version \
    && helm version --short \
    && zarf version \
    && gcc --version \
    && clang --version \
    && nano --version \
    && node --version \
    && npm --version \
    && codex --version \
    && ollama -v \
    && pwsh --version

ENV CODEX_HOME=/root/.codex
ENV LOCAL_CODEX_OLLAMA_PULL_MODELS=${LOCAL_CODEX_OLLAMA_PULL_MODELS}

COPY . .

RUN mkdir -p /root/.codex /root/.config/powershell \
    && cp /opt/local-codex-kit/docker-profile.ps1 /root/.config/powershell/Microsoft.PowerShell_profile.ps1 \
    && pwsh -NoLogo -NoProfile -File ./pull-ollama-models.ps1 -Models "${LOCAL_CODEX_OLLAMA_PULL_MODELS}"

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
