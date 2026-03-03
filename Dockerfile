FROM ubuntu:22.04 AS base

WORKDIR /opt/local-codex-kit

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git ca-certificates wget apt-transport-https software-properties-common gnupg \
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

ENV ToolchainPath=/opt/toolchain-cache
ENV ToolchainRepo=/opt/toolchain-repo
ENV ToolchainPullPolicy=IfNotPresent

COPY . .

COPY --from=toolchain-seed /opt/powershell-modules /opt/powershell-modules

RUN mkdir -p /root/.config/powershell \
    && mkdir -p /opt/toolchain-repo \
    && cp /opt/local-codex-kit/docker-profile.ps1 /root/.config/powershell/Microsoft.PowerShell_profile.ps1 \
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
