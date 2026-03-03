FROM ubuntu:22.04 AS base

WORKDIR /opt/local-codex-kit

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git ca-certificates wget apt-transport-https software-properties-common gnupg libgomp1 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && npm install -g @openai/codex \
    && npm --version \
    && node --version \
    && pwsh --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

FROM ubuntu:22.04 AS llama-server-builder

ARG LLAMA_CPP_REPO_URL=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_CPP_REPO_REF=master

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git cmake build-essential \
    && git clone --depth 1 --branch "${LLAMA_CPP_REPO_REF}" "${LLAMA_CPP_REPO_URL}" /tmp/llama.cpp \
    && cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_SERVER=ON \
    && cmake --build /tmp/llama.cpp/build --config Release -j"$(nproc)" \
    && test -x /tmp/llama.cpp/build/bin/llama-server \
    && install -Dm755 /tmp/llama.cpp/build/bin/llama-server /opt/llama-server/llama-server \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/llama.cpp

FROM base AS toolchain-seed

ARG TOOLCHAIN_REPO_URL=https://github.com/allsagetech/Toolchain.git
ARG TOOLCHAIN_REPO_REF=main

RUN git clone --depth 1 --branch "${TOOLCHAIN_REPO_REF}" "${TOOLCHAIN_REPO_URL}" /tmp/Toolchain \
    && pwsh -NoLogo -NoProfile -Command "\
        \$ErrorActionPreference = 'Stop'; \
        Set-Location /tmp/Toolchain; \
        ./build.ps1; \
        \$version = (Get-Content ./VERSION -Raw).Trim(); \
        \$moduleRoot = '/opt/powershell-modules/Toolchain/' + \$version; \
        New-Item -ItemType Directory -Path \$moduleRoot -Force | Out-Null; \
        Copy-Item ./build/Toolchain/* \$moduleRoot -Recurse -Force; \
        \$env:PSModulePath = '/opt/powershell-modules:' + \$env:PSModulePath; \
        Import-Module Toolchain -Force; \
        toolchain version | Out-Host \
    " \
    && rm -rf /tmp/Toolchain

FROM base AS final

ARG LOCAL_CODEX_EMBEDDED_MODEL_FILE=qwen2.5-coder-7b-instruct-q4_k_m.gguf
ARG LOCAL_CODEX_EMBEDDED_MODEL_URL=
ARG LOCAL_CODEX_EMBEDDED_MODEL_SHA256=

ENV ToolchainPath=/opt/toolchain-cache
ENV ToolchainRepo=/opt/toolchain-repo
ENV ToolchainPullPolicy=IfNotPresent
ENV LOCAL_CODEX_EMBEDDED_MODEL_PATH=/opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}

COPY . .

COPY --from=toolchain-seed /opt/powershell-modules /opt/powershell-modules
COPY --from=llama-server-builder /opt/llama-server/llama-server /usr/local/bin/llama-server

RUN mkdir -p /root/.config/powershell \
    && mkdir -p /opt/models \
    && mkdir -p /opt/toolchain-repo \
    && cp /opt/local-codex-kit/docker-profile.ps1 /root/.config/powershell/Microsoft.PowerShell_profile.ps1 \
    && if [ -d /opt/local-codex-kit/.models ]; then cp -a /opt/local-codex-kit/.models/. /opt/models/; fi \
    && if [ -n "${LOCAL_CODEX_EMBEDDED_MODEL_URL}" ]; then curl -fL --retry 5 --retry-delay 2 "${LOCAL_CODEX_EMBEDDED_MODEL_URL}" -o "/opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}"; fi \
    && if [ -n "${LOCAL_CODEX_EMBEDDED_MODEL_SHA256}" ]; then echo "${LOCAL_CODEX_EMBEDDED_MODEL_SHA256}  /opt/models/${LOCAL_CODEX_EMBEDDED_MODEL_FILE}" | sha256sum -c -; fi \
    && if [ -d /opt/local-codex-kit/.toolchain-offline ]; then cp -a /opt/local-codex-kit/.toolchain-offline/. /opt/toolchain-repo/; fi \
    && pwsh -NoLogo -NoProfile -Command "\
        \$ErrorActionPreference = 'Stop'; \
        \$env:PSModulePath = '/opt/powershell-modules:' + \$env:PSModulePath; \
        \$env:ToolchainPath = '/opt/toolchain-cache'; \
        \$env:ToolchainRepo = '/opt/toolchain-repo'; \
        Import-Module Toolchain -Force; \
        toolchain version | Out-Host; \
        toolchain remote list | Out-Host \
    "

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/opt/local-codex-kit/docker-entrypoint.ps1"]
