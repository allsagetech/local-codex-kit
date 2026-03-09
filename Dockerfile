ARG LOCAL_CODEX_BASE_IMAGE=ubuntu:22.04
FROM ${LOCAL_CODEX_BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LOCAL_CODEX_LLAMACPP_PULL_MODELS=gpt-oss-20b
ARG LOCAL_CODEX_RUNTIME_USER=codex
ARG LOCAL_CODEX_RUNTIME_UID=1000
ARG LOCAL_CODEX_RUNTIME_GID=1000
ARG LOCAL_CODEX_LLAMACPP_MODELS=/opt/local-codex-kit/llama-models
ARG LLAMACPP_REPO_URL=https://github.com/ggml-org/llama.cpp.git
ARG LLAMACPP_REPO_REF=master
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
        cmake \
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
    && git clone --depth 1 --branch "${LLAMACPP_REPO_REF}" "${LLAMACPP_REPO_URL}" /tmp/llama.cpp \
    && cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF \
    && cmake --build /tmp/llama.cpp/build --config Release -j"$(nproc)" --target llama-server llama-cli llama-bench \
    && install /tmp/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server \
    && install /tmp/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli \
    && install /tmp/llama.cpp/build/bin/llama-bench /usr/local/bin/llama-bench \
    && rm -rf /tmp/llama.cpp \
    && python -m pip install --no-cache-dir 'huggingface_hub[cli]>=0.31.0' \
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
    && command -v llama-server \
    && command -v llama-cli \
    && pwsh --version

ENV LOCAL_CODEX_RUNTIME_USER=${LOCAL_CODEX_RUNTIME_USER}
ENV HOME=/home/${LOCAL_CODEX_RUNTIME_USER}
ENV CODEX_HOME=/home/${LOCAL_CODEX_RUNTIME_USER}/.codex
ENV LOCAL_CODEX_LLAMACPP_MODELS=${LOCAL_CODEX_LLAMACPP_MODELS}
ENV LOCAL_CODEX_LLAMACPP_PULL_MODELS=${LOCAL_CODEX_LLAMACPP_PULL_MODELS}

COPY . .

RUN groupadd --gid "${LOCAL_CODEX_RUNTIME_GID}" "${LOCAL_CODEX_RUNTIME_USER}" \
    && useradd --uid "${LOCAL_CODEX_RUNTIME_UID}" --gid "${LOCAL_CODEX_RUNTIME_GID}" --create-home --shell /bin/bash "${LOCAL_CODEX_RUNTIME_USER}" \
    && install -d -m 0755 -o "${LOCAL_CODEX_RUNTIME_USER}" -g "${LOCAL_CODEX_RUNTIME_USER}" \
        /workspace \
        "${CODEX_HOME}" \
        "${HOME}/.config/powershell" \
        "${LOCAL_CODEX_LLAMACPP_MODELS}" \
    && cp /opt/local-codex-kit/docker-profile.ps1 "${HOME}/.config/powershell/Microsoft.PowerShell_profile.ps1" \
    && install -m 0755 /opt/local-codex-kit/docker-code-wrapper.sh /usr/local/bin/code \
    && HOME="${HOME}" LOCAL_CODEX_LLAMACPP_MODELS="${LOCAL_CODEX_LLAMACPP_MODELS}" pwsh -NoLogo -NoProfile -File ./pull-llama-models.ps1 -Models "${LOCAL_CODEX_LLAMACPP_PULL_MODELS}" \
    && chown -R "${LOCAL_CODEX_RUNTIME_USER}:${LOCAL_CODEX_RUNTIME_USER}" "${HOME}" /workspace "${LOCAL_CODEX_LLAMACPP_MODELS}"

USER ${LOCAL_CODEX_RUNTIME_USER}

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
