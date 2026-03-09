$ErrorActionPreference = 'Stop'
$Command = @($args)

. (Join-Path (Split-Path -Parent $PSCommandPath) 'llama-models.ps1')

function Initialize-CodexConfig {
    param(
        [string]$CodexHome,
        [string]$OssBaseUrl,
        [string]$DefaultModel,
        [string]$ApprovalPolicy,
        [string]$SandboxMode
    )

    if (-not (Test-Path -LiteralPath $CodexHome)) {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    }

    $configPath = Join-Path $CodexHome 'config.toml'
    $managedHeader = '# Managed by local-codex-kit. Remove this line to stop auto-refresh.'
    $configContent = @(
        $managedHeader
        'model_provider = "oss"'
        'model = ' + (Convert-ToTomlString -Value $DefaultModel)
        'approval_policy = ' + (Convert-ToTomlString -Value $ApprovalPolicy)
        'sandbox_mode = ' + (Convert-ToTomlString -Value $SandboxMode)
        ''
        '[model_providers.oss]'
        'name = "Local llama.cpp"'
        'base_url = ' + (Convert-ToTomlString -Value $OssBaseUrl)
        ''
    ) -join "`n"

    $shouldWrite = $true
    if (Test-Path -LiteralPath $configPath) {
        $firstLine = Get-Content -LiteralPath $configPath -TotalCount 1 -ErrorAction SilentlyContinue
        $shouldWrite = ($firstLine -eq $managedHeader)
    }

    if ($shouldWrite) {
        Set-Content -LiteralPath $configPath -Value $configContent -NoNewline
    }
}

$env:LOCAL_CODEX_KIT_ROOT = if ($env:LOCAL_CODEX_KIT_ROOT) { $env:LOCAL_CODEX_KIT_ROOT } else { '/opt/local-codex-kit' }
$env:HOME = if ($env:HOME) { $env:HOME } else { '/home/codex' }
$env:LOCAL_CODEX_WORKSPACE = if ($env:LOCAL_CODEX_WORKSPACE) { $env:LOCAL_CODEX_WORKSPACE } else { '/workspace' }
$env:LOCAL_CODEX_LLAMACPP_MODELS = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }
$env:LOCAL_CODEX_LLAMACPP_PULL_MODELS = if ($env:LOCAL_CODEX_LLAMACPP_PULL_MODELS) { $env:LOCAL_CODEX_LLAMACPP_PULL_MODELS } else { '' }
$env:LOCAL_CODEX_LLAMACPP_PORT = if ($env:LOCAL_CODEX_LLAMACPP_PORT) { $env:LOCAL_CODEX_LLAMACPP_PORT } else { '8080' }
$env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH = if ($env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH) { $env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH } else { '65536' }
$env:LOCAL_CODEX_LLAMACPP_REQUIRE_READY = if ($env:LOCAL_CODEX_LLAMACPP_REQUIRE_READY) { $env:LOCAL_CODEX_LLAMACPP_REQUIRE_READY } else { '0' }
$env:LOCAL_CODEX_LLAMACPP_ENABLE = if ($env:LOCAL_CODEX_LLAMACPP_ENABLE) { $env:LOCAL_CODEX_LLAMACPP_ENABLE } else { '1' }
$env:CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { '/home/codex/.codex' }
$env:LOCAL_CODEX_CODEX_APPROVAL_POLICY = if ($env:LOCAL_CODEX_CODEX_APPROVAL_POLICY) { $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY } else { 'on-request' }
$env:LOCAL_CODEX_CODEX_SANDBOX_MODE = if ($env:LOCAL_CODEX_CODEX_SANDBOX_MODE) { $env:LOCAL_CODEX_CODEX_SANDBOX_MODE } else { 'danger-full-access' }

$defaultPulledModel = Get-FirstConfiguredLlamaModel -RawModels $env:LOCAL_CODEX_LLAMACPP_PULL_MODELS
$requestedModel = if ($env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS) {
    $env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS
} elseif ($defaultPulledModel) {
    $defaultPulledModel
} else {
    'gpt-oss-20b'
}

$env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS = Convert-ToCodexModelName -ModelName $requestedModel
$env:LOCAL_CODEX_CODEX_MODEL = if ($env:LOCAL_CODEX_CODEX_MODEL) {
    Convert-ToCodexModelName -ModelName $env:LOCAL_CODEX_CODEX_MODEL
} else {
    $env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS
}

$workspace = $env:LOCAL_CODEX_WORKSPACE
if (-not (Test-Path -LiteralPath $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

Set-Location $workspace

$llamaInfo = $null
$llamaStartupError = $null
if ($env:LOCAL_CODEX_LLAMACPP_ENABLE -ne '0') {
    $llamaStarterScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'start-llama-server.ps1'
    if (-not (Test-Path -LiteralPath $llamaStarterScript)) {
        throw "llama.cpp starter script not found: $llamaStarterScript"
    }

    try {
        $llamaInfo = & $llamaStarterScript
    } catch {
        $llamaStartupError = $_.Exception.Message
        $env:LOCAL_CODEX_LLAMACPP_ENABLE = '0'

        if ($env:LOCAL_CODEX_LLAMACPP_REQUIRE_READY -eq '1') {
            throw
        }

        Write-Warning 'Embedded llama.cpp failed to start. Continuing without a local runtime.'
        Write-Warning $llamaStartupError
    }
}

$llamaHost = if ($env:LOCAL_CODEX_LLAMACPP_HOST) { $env:LOCAL_CODEX_LLAMACPP_HOST } else { '127.0.0.1' }
$env:LOCAL_CODEX_LLAMACPP_BASE_URL = if ($llamaInfo) {
    $llamaInfo.llamaBaseUrl
} else {
    "http://$llamaHost`:$($env:LOCAL_CODEX_LLAMACPP_PORT)"
}
$env:CODEX_OSS_BASE_URL = $env:LOCAL_CODEX_LLAMACPP_BASE_URL.TrimEnd('/') + '/v1'

Initialize-CodexConfig `
    -CodexHome $env:CODEX_HOME `
    -OssBaseUrl $env:CODEX_OSS_BASE_URL `
    -DefaultModel $env:LOCAL_CODEX_CODEX_MODEL `
    -ApprovalPolicy $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY `
    -SandboxMode $env:LOCAL_CODEX_CODEX_SANDBOX_MODE

$profileScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'docker-profile.ps1'
if (Test-Path -LiteralPath $profileScript) {
    . $profileScript
}

Write-Host ''
Write-Host 'Local llama.cpp container'
Write-Host ("- Repo: {0}" -f $env:LOCAL_CODEX_KIT_ROOT)
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
Write-Host ("- Runtime user: {0}" -f $(if ($env:LOCAL_CODEX_RUNTIME_USER) { $env:LOCAL_CODEX_RUNTIME_USER } else { 'codex' }))
Write-Host ("- Codex home: {0}" -f $env:CODEX_HOME)
Write-Host ("- Workspace storage: {0}" -f 'Docker-managed volume mounted at /workspace')
if ($env:LOCAL_CODEX_LLAMACPP_PULL_MODELS -and ($env:LOCAL_CODEX_LLAMACPP_PULL_MODELS -ne 'none')) {
    Write-Host ("- Build-downloaded models: {0}" -f $env:LOCAL_CODEX_LLAMACPP_PULL_MODELS)
}
Write-Host ("- llama.cpp mode: {0}" -f $(if ($env:LOCAL_CODEX_LLAMACPP_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
Write-Host ("- llama.cpp model store: {0}" -f $env:LOCAL_CODEX_LLAMACPP_MODELS)
if ($llamaInfo) {
    Write-Host ("- llama.cpp endpoint: {0}" -f $llamaInfo.llamaBaseUrl)
    Write-Host ("- llama.cpp context length: {0}" -f $env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH)
    Write-Host ("- Default model alias: {0}" -f $llamaInfo.modelAlias)
    Write-Host ("- Model file: {0}" -f $llamaInfo.modelFile)
    if ($llamaInfo.started -and $llamaInfo.processId) {
        Write-Host ("- llama.cpp PID: {0}" -f $llamaInfo.processId)
    }
} elseif ($llamaStartupError) {
    Write-Host '- llama.cpp startup: failed; shell fallback enabled'
}
Write-Host ("- Codex OSS endpoint: {0}" -f $env:CODEX_OSS_BASE_URL)
Write-Host ("- Codex default model: {0}" -f $env:LOCAL_CODEX_CODEX_MODEL)
Write-Host ("- Codex sandbox: {0}" -f $env:LOCAL_CODEX_CODEX_SANDBOX_MODE)
Write-Host ("- Codex approvals: {0}" -f $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY)
Write-Host '- Container hardening: non-root user, read-only root filesystem, tmpfs-backed /tmp, no-new-privileges, all Linux capabilities dropped.'
Write-Host '- Linux-native tools: code, chromium, git, go, python, helm, zarf, node, gcc/clang, llama.cpp.'
Write-Host '- Windows-only tools such as Notepad++ and VS Build Tools are not available in this Ubuntu image.'
Write-Host '- The workspace and runtime state stay in Docker-managed volumes; /workspace/project remains the host bind mount.'
Write-Host '- The llama.cpp model store is baked into the image and selected at build time.'
Write-Host '- `code .` inside this headless container will not launch Windows VS Code.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: use `codex-local`, `codex`, or `llama-local`.'
pwsh -NoLogo
exit $LASTEXITCODE
