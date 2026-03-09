ARG LOCAL_CODEX_BASE_IMAGE=ubuntu:22.04
FROM ${LOCAL_CODEX_BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LOCAL_CODEX_OFFICIAL_PULL_MODELS=openai/gpt-oss-20b
ARG LOCAL_CODEX_RUNTIME_USER=codex
ARG LOCAL_CODEX_RUNTIME_UID=1000
ARG LOCAL_CODEX_RUNTIME_GID=1000
ARG LOCAL_CODEX_HF_CACHE_SEED=/opt/local-codex-kit/hf-cache-seed
ARG LOCAL_CODEX_MODEL_MANIFEST=/opt/local-codex-kit/official-models.manifest.json
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
    && if [ ! -x /usr/bin/pwsh ] && [ -x /opt/microsoft/powershell/7/pwsh ]; then ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh; fi \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux \
    && curl -fsSL "${NODE_LINUX_ARCHIVE_URL}" | tar -xJ --strip-components=1 -C /usr/local \
    && npm install -g @openai/codex \
    && python -m pip install --no-cache-dir \
        'torch>=2.8.0' \
        'transformers[serving]>=5.2.0' \
        'huggingface_hub[hf_xet]>=0.32.0' \
        'accelerate>=1.10.0' \
        'safetensors>=0.6.0' \
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
    && python -c "import transformers; print(transformers.__version__)" \
    && helm version --short \
    && zarf version \
    && gcc --version \
    && clang --version \
    && nano --version \
    && node --version \
    && npm --version \
    && codex --version \
    && command -v transformers \
    && command -v huggingface-cli \
    && test -x /opt/microsoft/powershell/7/pwsh

ENV LOCAL_CODEX_RUNTIME_USER=${LOCAL_CODEX_RUNTIME_USER}
ENV HOME=/home/${LOCAL_CODEX_RUNTIME_USER}
ENV CODEX_HOME=/home/${LOCAL_CODEX_RUNTIME_USER}/.codex
ENV LOCAL_CODEX_HF_CACHE_SEED=${LOCAL_CODEX_HF_CACHE_SEED}
ENV LOCAL_CODEX_MODEL_MANIFEST=${LOCAL_CODEX_MODEL_MANIFEST}
ENV LOCAL_CODEX_OFFICIAL_PULL_MODELS=${LOCAL_CODEX_OFFICIAL_PULL_MODELS}

COPY . .

RUN set -eux \
    && if ! getent group "${LOCAL_CODEX_RUNTIME_GID}" >/dev/null; then groupadd --gid "${LOCAL_CODEX_RUNTIME_GID}" "${LOCAL_CODEX_RUNTIME_USER}"; fi \
    && if ! id -u "${LOCAL_CODEX_RUNTIME_USER}" >/dev/null 2>&1; then useradd --uid "${LOCAL_CODEX_RUNTIME_UID}" --gid "${LOCAL_CODEX_RUNTIME_GID}" --create-home --shell /bin/bash "${LOCAL_CODEX_RUNTIME_USER}"; fi \
    && install -d -m 0755 -o "${LOCAL_CODEX_RUNTIME_UID}" -g "${LOCAL_CODEX_RUNTIME_GID}" \
        /workspace \
        "${CODEX_HOME}" \
        "${HOME}/.cache/huggingface" \
        "${HOME}/.config/powershell" \
        "${LOCAL_CODEX_HF_CACHE_SEED}" \
    && cp /opt/local-codex-kit/docker-profile.ps1 "${HOME}/.config/powershell/Microsoft.PowerShell_profile.ps1" \
    && install -m 0755 /opt/local-codex-kit/docker-code-wrapper.sh /usr/local/bin/code

RUN set -eux \
    && HOME="${HOME}" LOCAL_CODEX_HF_CACHE_SEED="${LOCAL_CODEX_HF_CACHE_SEED}" LOCAL_CODEX_MODEL_MANIFEST="${LOCAL_CODEX_MODEL_MANIFEST}" /opt/microsoft/powershell/7/pwsh -NoLogo -NoProfile -File ./pull-official-models.ps1 -Models "${LOCAL_CODEX_OFFICIAL_PULL_MODELS}" \
    && chown -R "${LOCAL_CODEX_RUNTIME_UID}:${LOCAL_CODEX_RUNTIME_GID}" "${HOME}" /workspace "${LOCAL_CODEX_HF_CACHE_SEED}"

USER ${LOCAL_CODEX_RUNTIME_USER}

ENTRYPOINT ["/opt/microsoft/powershell/7/pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
