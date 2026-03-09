$ErrorActionPreference = 'Stop'
$Command = @($args)

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

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
        'name = "Official gpt-oss (Transformers)"'
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
$env:LOCAL_CODEX_HF_CACHE_SEED = if ($env:LOCAL_CODEX_HF_CACHE_SEED) { $env:LOCAL_CODEX_HF_CACHE_SEED } else { '/opt/local-codex-kit/hf-cache-seed' }
$env:LOCAL_CODEX_HF_HOME = if ($env:LOCAL_CODEX_HF_HOME) { $env:LOCAL_CODEX_HF_HOME } else { '/home/codex/.cache/huggingface' }
$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:LOCAL_CODEX_OFFICIAL_PULL_MODELS = if ($env:LOCAL_CODEX_OFFICIAL_PULL_MODELS) { $env:LOCAL_CODEX_OFFICIAL_PULL_MODELS } else { '' }
$env:LOCAL_CODEX_TRANSFORMERS_PORT = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }
$env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY = if ($env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY) { $env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY } else { '0' }
$env:LOCAL_CODEX_TRANSFORMERS_ENABLE = if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE) { $env:LOCAL_CODEX_TRANSFORMERS_ENABLE } else { '1' }
$env:CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { '/home/codex/.codex' }
$env:LOCAL_CODEX_CODEX_APPROVAL_POLICY = if ($env:LOCAL_CODEX_CODEX_APPROVAL_POLICY) { $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY } else { 'on-request' }
$env:LOCAL_CODEX_CODEX_SANDBOX_MODE = if ($env:LOCAL_CODEX_CODEX_SANDBOX_MODE) { $env:LOCAL_CODEX_CODEX_SANDBOX_MODE } else { 'danger-full-access' }

$defaultPulledModel = Get-FirstConfiguredModel -RawModels $env:LOCAL_CODEX_OFFICIAL_PULL_MODELS
$requestedModel = if ($env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS) {
    $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS
} elseif ($defaultPulledModel) {
    $defaultPulledModel
} else {
    'openai/gpt-oss-20b'
}

$env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS = Convert-ToCanonicalModelName -ModelName $requestedModel
$env:LOCAL_CODEX_CODEX_MODEL = if ($env:LOCAL_CODEX_CODEX_MODEL) {
    Convert-ToCanonicalModelName -ModelName $env:LOCAL_CODEX_CODEX_MODEL
} else {
    $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS
}

$workspace = $env:LOCAL_CODEX_WORKSPACE
if (-not (Test-Path -LiteralPath $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

Set-Location $workspace

$transformersInfo = $null
$transformersStartupError = $null
if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE -ne '0') {
    $starterScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'start-transformers-server.ps1'
    if (-not (Test-Path -LiteralPath $starterScript)) {
        throw "Transformers starter script not found: $starterScript"
    }

    try {
        $transformersInfo = & $starterScript
    } catch {
        $transformersStartupError = $_.Exception.Message
        $env:LOCAL_CODEX_TRANSFORMERS_ENABLE = '0'

        if ($env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY -eq '1') {
            throw
        }

        Write-Warning 'Embedded Transformers server failed to start. Continuing without a local runtime.'
        Write-Warning $transformersStartupError
    }
}

$transformersHost = if ($env:LOCAL_CODEX_TRANSFORMERS_HOST) { $env:LOCAL_CODEX_TRANSFORMERS_HOST } else { '127.0.0.1' }
$env:LOCAL_CODEX_TRANSFORMERS_BASE_URL = if ($transformersInfo) {
    $transformersInfo.baseUrl
} else {
    "http://$transformersHost`:$($env:LOCAL_CODEX_TRANSFORMERS_PORT)"
}
$env:CODEX_OSS_BASE_URL = $env:LOCAL_CODEX_TRANSFORMERS_BASE_URL.TrimEnd('/') + '/v1'

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
Write-Host 'Local official gpt-oss container'
Write-Host ("- Repo: {0}" -f $env:LOCAL_CODEX_KIT_ROOT)
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
Write-Host ("- Runtime user: {0}" -f $(if ($env:LOCAL_CODEX_RUNTIME_USER) { $env:LOCAL_CODEX_RUNTIME_USER } else { 'codex' }))
Write-Host ("- Codex home: {0}" -f $env:CODEX_HOME)
Write-Host ("- Workspace storage: {0}" -f 'Docker-managed volume mounted at /workspace')
if ($env:LOCAL_CODEX_OFFICIAL_PULL_MODELS -and ($env:LOCAL_CODEX_OFFICIAL_PULL_MODELS -ne 'none')) {
    Write-Host ("- Build-downloaded official models: {0}" -f $env:LOCAL_CODEX_OFFICIAL_PULL_MODELS)
}
Write-Host ("- Hugging Face cache seed: {0}" -f $env:LOCAL_CODEX_HF_CACHE_SEED)
Write-Host ("- Runtime Hugging Face cache: {0}" -f $env:LOCAL_CODEX_HF_HOME)
Write-Host ("- Transformers mode: {0}" -f $(if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($transformersInfo) {
    Write-Host ("- Transformers endpoint: {0}" -f $transformersInfo.baseUrl)
    Write-Host ("- Default model repo: {0}" -f $transformersInfo.modelRepo)
    if ($transformersInfo.started -and $transformersInfo.processId) {
        Write-Host ("- Transformers PID: {0}" -f $transformersInfo.processId)
    }
} elseif ($transformersStartupError) {
    Write-Host '- Transformers startup: failed; shell fallback enabled'
}
Write-Host ("- Codex OSS endpoint: {0}" -f $env:CODEX_OSS_BASE_URL)
Write-Host ("- Codex default model: {0}" -f $env:LOCAL_CODEX_CODEX_MODEL)
Write-Host ("- Codex sandbox: {0}" -f $env:LOCAL_CODEX_CODEX_SANDBOX_MODE)
Write-Host ("- Codex approvals: {0}" -f $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY)
Write-Host '- Container hardening: non-root user, read-only root filesystem, tmpfs-backed /tmp, no-new-privileges, all Linux capabilities dropped.'
Write-Host '- Linux-native tools: code, chromium, git, go, python, helm, zarf, node, gcc/clang, transformers.'
Write-Host '- Official weights are seeded into the image and copied into a writable Hugging Face cache volume at runtime.'
Write-Host '- This path uses the official OpenAI Hugging Face weights, not GGUF conversions.'
Write-Host '- `code .` inside this headless container will not launch Windows VS Code.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: use `codex-local`, `codex`, or `transformers-local`.'
pwsh -NoLogo
exit $LASTEXITCODE
