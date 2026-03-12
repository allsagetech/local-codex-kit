$ErrorActionPreference = 'Stop'
$Command = @($args)

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

function Initialize-CodexConfig {
    param(
        [string]$CodexHome,
        [string]$OssBaseUrl,
        [string]$DefaultModel,
        [string]$ApprovalPolicy,
        [string]$SandboxMode,
        [string]$ProviderName,
        [string]$ProviderDisplayName,
        [string]$ProviderWireApi,
        [string]$ProviderEnvKey
    )

    if (-not (Test-Path -LiteralPath $CodexHome)) {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    }

    $configPath = Join-Path $CodexHome 'config.toml'
    $managedHeader = '# Managed by local-codex-kit. Remove this line to stop auto-refresh.'
    $configContent = @(
        $managedHeader
        'model_provider = ' + (Convert-ToTomlString -Value $ProviderName)
        'model = ' + (Convert-ToTomlString -Value $DefaultModel)
        'approval_policy = ' + (Convert-ToTomlString -Value $ApprovalPolicy)
        'sandbox_mode = ' + (Convert-ToTomlString -Value $SandboxMode)
        ''
        ('[model_providers.{0}]' -f $ProviderName)
        'name = ' + (Convert-ToTomlString -Value $ProviderDisplayName)
        'base_url = ' + (Convert-ToTomlString -Value $OssBaseUrl)
        'wire_api = ' + (Convert-ToTomlString -Value $ProviderWireApi)
        'env_key = ' + (Convert-ToTomlString -Value $ProviderEnvKey)
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

function Start-CodexOpenAIProxy {
    param(
        [string]$ProxyScriptPath,
        [string]$ListenHost,
        [string]$ListenPort,
        [string]$UpstreamBaseUrl,
        [string]$PrimaryModel,
        [string]$StartupTimeoutSec
    )

    if (-not (Test-Path -LiteralPath $ProxyScriptPath)) {
        throw "Codex proxy script not found: $ProxyScriptPath"
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        throw '`python` is required to start the Codex OpenAI proxy.'
    }

    $logDir = '/tmp/local-codex-kit'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $outLog = Join-Path $logDir 'codex-openai-proxy.out.log'
    $errLog = Join-Path $logDir 'codex-openai-proxy.err.log'
    $argumentList = @(
        $ProxyScriptPath,
        '--listen-host', $ListenHost,
        '--listen-port', $ListenPort,
        '--upstream-base', $UpstreamBaseUrl,
        '--model-id', $PrimaryModel
    )

    $proc = Start-Process -FilePath $python.Source -ArgumentList $argumentList -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $baseUrl = "http://$ListenHost`:$ListenPort"
    $deadline = (Get-Date).AddSeconds([int]$StartupTimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            throw ("Codex OpenAI proxy exited before becoming ready.`n`nstdout: {0}`nstderr: {1}" -f $outLog, $errLog)
        }

        try {
            $health = Invoke-RestMethod -Uri ($baseUrl + '/healthz') -TimeoutSec 3
            if ($health.status -eq 'ok') {
                return [pscustomobject]@{
                    started       = $true
                    processId     = $proc.Id
                    baseUrl       = $baseUrl
                    stdoutLogPath = $outLog
                    stderrLogPath = $errLog
                }
            }
        } catch {
        }

        Start-Sleep -Milliseconds 500
    }

    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {
    }

    throw ("Timed out waiting for the Codex OpenAI proxy. stdout: {0} stderr: {1}" -f $outLog, $errLog)
}

$env:LOCAL_CODEX_KIT_ROOT = if ($env:LOCAL_CODEX_KIT_ROOT) { $env:LOCAL_CODEX_KIT_ROOT } else { '/opt/local-codex-kit' }
$env:HOME = if ($env:HOME) { $env:HOME } else { '/home/codex' }
$env:LOCAL_CODEX_WORKSPACE = if ($env:LOCAL_CODEX_WORKSPACE) { $env:LOCAL_CODEX_WORKSPACE } else { '/workspace' }
$env:LOCAL_CODEX_TOOLCHAIN_PATH = if ($env:LOCAL_CODEX_TOOLCHAIN_PATH) { $env:LOCAL_CODEX_TOOLCHAIN_PATH } else { '/opt/local-codex-kit/toolchain-store' }
$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:LOCAL_CODEX_OFFICIAL_PULL_MODELS = if ($env:LOCAL_CODEX_OFFICIAL_PULL_MODELS) { $env:LOCAL_CODEX_OFFICIAL_PULL_MODELS } else { '' }
$env:LOCAL_CODEX_TRANSFORMERS_PORT = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }
$env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY = if ($env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY) { $env:LOCAL_CODEX_TRANSFORMERS_REQUIRE_READY } else { '0' }
$env:LOCAL_CODEX_TRANSFORMERS_ENABLE = if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE) { $env:LOCAL_CODEX_TRANSFORMERS_ENABLE } else { '1' }
$env:LOCAL_CODEX_OSS_PROXY_ENABLE = if ($env:LOCAL_CODEX_OSS_PROXY_ENABLE) { $env:LOCAL_CODEX_OSS_PROXY_ENABLE } else { '1' }
$env:LOCAL_CODEX_OSS_PROXY_PORT = if ($env:LOCAL_CODEX_OSS_PROXY_PORT) { $env:LOCAL_CODEX_OSS_PROXY_PORT } else { '8001' }
$env:CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { '/home/codex/.codex' }
$env:LOCAL_CODEX_CODEX_APPROVAL_POLICY = if ($env:LOCAL_CODEX_CODEX_APPROVAL_POLICY) { $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY } else { 'on-request' }
$env:LOCAL_CODEX_CODEX_SANDBOX_MODE = if ($env:LOCAL_CODEX_CODEX_SANDBOX_MODE) { $env:LOCAL_CODEX_CODEX_SANDBOX_MODE } else { 'danger-full-access' }
$env:LOCAL_CODEX_CODEX_PROVIDER = if ($env:LOCAL_CODEX_CODEX_PROVIDER) { $env:LOCAL_CODEX_CODEX_PROVIDER } else { 'transformers' }
$env:LOCAL_CODEX_TRANSFORMERS_API_KEY = if ($env:LOCAL_CODEX_TRANSFORMERS_API_KEY) { $env:LOCAL_CODEX_TRANSFORMERS_API_KEY } else { 'local-codex' }
$env:HF_HOME = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Path $env:HOME '.cache/huggingface' }
$env:HF_HUB_CACHE = if ($env:HF_HUB_CACHE) { $env:HF_HUB_CACHE } else { Join-Path $env:HF_HOME 'hub' }

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

foreach ($path in @($env:HF_HOME, $env:HF_HUB_CACHE)) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

Set-Location $workspace

$transformersInfo = $null
$transformersStartupError = $null
$proxyInfo = $null
$proxyStartupError = $null
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

if (($env:LOCAL_CODEX_OSS_PROXY_ENABLE -ne '0') -and $transformersInfo) {
    $proxyScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'codex-openai-proxy.py'
    try {
        $proxyInfo = Start-CodexOpenAIProxy `
            -ProxyScriptPath $proxyScript `
            -ListenHost '127.0.0.1' `
            -ListenPort $env:LOCAL_CODEX_OSS_PROXY_PORT `
            -UpstreamBaseUrl $env:LOCAL_CODEX_TRANSFORMERS_BASE_URL `
            -PrimaryModel $env:LOCAL_CODEX_CODEX_MODEL `
            -StartupTimeoutSec $env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC
    } catch {
        $proxyStartupError = $_.Exception.Message
        Write-Warning 'Codex OpenAI proxy failed to start. Falling back to the raw transformers endpoint.'
        Write-Warning $proxyStartupError
    }
}

$env:CODEX_OSS_BASE_URL = if ($proxyInfo) {
    $proxyInfo.baseUrl.TrimEnd('/') + '/v1'
} else {
    $env:LOCAL_CODEX_TRANSFORMERS_BASE_URL.TrimEnd('/') + '/v1'
}

Initialize-CodexConfig `
    -CodexHome $env:CODEX_HOME `
    -OssBaseUrl $env:CODEX_OSS_BASE_URL `
    -DefaultModel $env:LOCAL_CODEX_CODEX_MODEL `
    -ApprovalPolicy $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY `
    -SandboxMode $env:LOCAL_CODEX_CODEX_SANDBOX_MODE `
    -ProviderName $env:LOCAL_CODEX_CODEX_PROVIDER `
    -ProviderDisplayName 'Official gpt-oss (Transformers)' `
    -ProviderWireApi 'responses' `
    -ProviderEnvKey 'LOCAL_CODEX_TRANSFORMERS_API_KEY'

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
Write-Host ("- Toolchain model store: {0}" -f $env:LOCAL_CODEX_TOOLCHAIN_PATH)
Write-Host ("- Transformers mode: {0}" -f $(if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($transformersInfo) {
    Write-Host ("- Transformers endpoint: {0}" -f $transformersInfo.baseUrl)
    Write-Host ("- Default model repo: {0}" -f $transformersInfo.modelRepo)
    Write-Host ("- Default model path: {0}" -f $transformersInfo.modelPath)
    if ($transformersInfo.started -and $transformersInfo.processId) {
        Write-Host ("- Transformers PID: {0}" -f $transformersInfo.processId)
    }
} elseif ($transformersStartupError) {
    Write-Host '- Transformers startup: failed; shell fallback enabled'
}
if ($proxyInfo) {
    Write-Host ("- Codex proxy endpoint: {0}" -f $proxyInfo.baseUrl)
    if ($proxyInfo.started -and $proxyInfo.processId) {
        Write-Host ("- Codex proxy PID: {0}" -f $proxyInfo.processId)
    }
} elseif ($proxyStartupError) {
    Write-Host '- Codex proxy startup: failed; using raw transformers endpoint'
}
Write-Host ("- Codex OSS endpoint: {0}" -f $env:CODEX_OSS_BASE_URL)
Write-Host ("- Codex default model: {0}" -f $env:LOCAL_CODEX_CODEX_MODEL)
Write-Host ("- Codex sandbox: {0}" -f $env:LOCAL_CODEX_CODEX_SANDBOX_MODE)
Write-Host ("- Codex approvals: {0}" -f $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY)
Write-Host '- Container hardening: non-root user, read-only root filesystem, tmpfs-backed /tmp, no-new-privileges, all Linux capabilities dropped.'
Write-Host '- Linux-native tools: code, chromium, git, go, python, helm, zarf, node, gcc/clang, transformers.'
Write-Host '- Official weights are pulled into the image as Toolchain packages and served from their extracted model path.'
Write-Host '- This path uses packaged official OpenAI weights, not GGUF conversions.'
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
