FROM ubuntu:22.04

ARG LOCAL_CODEX_EMBEDDED_MODEL_FILE=qwen2.5-coder-7b-instruct-q4_k_m.gguf
ARG LOCAL_CODEX_EMBEDDED_MODEL_URL=
ARG LOCAL_CODEX_EMBEDDED_MODEL_SHA256=
ARG LOCAL_CODEX_OLLAMA_PULL_MODELS=qwen3-coder
ARG OLLAMA_LINUX_ARCHIVE_URL=https://ollama.com/download/ollama-linux-amd64.tar.zst

WORKDIR /opt/local-codex-kit

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git ca-certificates wget apt-transport-https software-properties-common gnupg zstd \
    && wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && curl -fsSL "${OLLAMA_LINUX_ARCHIVE_URL}" | tar --zstd -x -C /usr \
    && ollama -v \
    && pwsh --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV LOCAL_CODEX_EMBEDDED_MODEL_PATH=/opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}
ENV LOCAL_CODEX_OLLAMA_PULL_MODELS=${LOCAL_CODEX_OLLAMA_PULL_MODELS}

COPY . .

RUN mkdir -p /root/.config/powershell \
    && mkdir -p /opt/models \
    && cp /opt/local-codex-kit/docker-profile.ps1 /root/.config/powershell/Microsoft.PowerShell_profile.ps1 \
    && if [ -d /opt/local-codex-kit/.models ]; then cp -a /opt/local-codex-kit/.models/. /opt/models/; fi \
    && if [ -n "${LOCAL_CODEX_EMBEDDED_MODEL_URL}" ]; then curl -fL --retry 5 --retry-delay 2 "${LOCAL_CODEX_EMBEDDED_MODEL_URL}" -o "/opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}"; fi \
    && if [ -n "${LOCAL_CODEX_EMBEDDED_MODEL_SHA256}" ]; then echo "${LOCAL_CODEX_EMBEDDED_MODEL_SHA256}  /opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}" | sha256sum -c -; fi \
    && pwsh -NoLogo -NoProfile -File ./pull-ollama-models.ps1 -Models "${LOCAL_CODEX_OLLAMA_PULL_MODELS}"

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
