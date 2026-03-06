FROM ubuntu:22.04

ARG LOCAL_CODEX_OLLAMA_PULL_MODELS=gpt-oss:20b
ARG OLLAMA_LINUX_ARCHIVE_URL=https://ollama.com/download/ollama-linux-amd64.tar.zst
ARG CODEX_LINUX_ARCHIVE_URL=https://github.com/openai/codex/releases/latest/download/codex-x86_64-unknown-linux-musl.tar.gz

WORKDIR /opt/local-codex-kit

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git ca-certificates wget apt-transport-https software-properties-common gnupg zstd \
    && wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && mkdir -p /usr/local/bin \
    && curl -fsSL "${OLLAMA_LINUX_ARCHIVE_URL}" | tar --zstd -x -C /usr \
    && curl -fsSL "${CODEX_LINUX_ARCHIVE_URL}" -o /tmp/codex-linux.tar.gz \
    && tar -xzf /tmp/codex-linux.tar.gz -C /usr/local/bin \
    && mv /usr/local/bin/codex-x86_64-unknown-linux-musl /usr/local/bin/codex \
    && chmod +x /usr/local/bin/codex \
    && ollama -v \
    && codex --version \
    && pwsh --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/codex-linux.tar.gz

ENV LOCAL_CODEX_OLLAMA_PULL_MODELS=${LOCAL_CODEX_OLLAMA_PULL_MODELS}

COPY . .

RUN mkdir -p /root/.config/powershell \
    && cp /opt/local-codex-kit/docker-profile.ps1 /root/.config/powershell/Microsoft.PowerShell_profile.ps1 \
    && pwsh -NoLogo -NoProfile -File ./pull-ollama-models.ps1 -Models "${LOCAL_CODEX_OLLAMA_PULL_MODELS}"

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
