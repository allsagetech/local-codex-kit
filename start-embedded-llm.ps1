param(
    [string]$ModelPath = $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH,
    [string]$BindHost = $(if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_EMBEDDED_HOST)) { '127.0.0.1' } else { $env:LOCAL_CODEX_EMBEDDED_HOST }),
    [int]$Port = 0,
    [string]$ModelAlias = $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS,
    [int]$ContextSize = 0,
    [int]$Threads = 0,
    [int]$GpuLayers = 0,
    [int]$StartupTimeoutSec = 0
)

$ErrorActionPreference = 'Stop'

function Get-EnvInt {
    param(
        [string]$Name,
        [int]$DefaultValue
    )

    $raw = [System.Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Test-EmbeddedEndpointReady {
    param(
        [string]$BaseUrl
    )

    try {
        $uri = $BaseUrl.TrimEnd('/') + '/models'
        $null = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 2
        return $true
    } catch {
        return $false
    }
}

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = '/opt/models/qwen2.5-coder-7b-instruct-q4_k_m.gguf'
}

if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw ("Embedded model file not found: {0}" -f $ModelPath)
}

if ($Port -le 0) {
    $Port = Get-EnvInt -Name 'LOCAL_CODEX_EMBEDDED_PORT' -DefaultValue 8000
}
if ($ContextSize -le 0) {
    $ContextSize = Get-EnvInt -Name 'LOCAL_CODEX_EMBEDDED_CONTEXT' -DefaultValue 8192
}
if ($Threads -le 0) {
    $Threads = Get-EnvInt -Name 'LOCAL_CODEX_EMBEDDED_THREADS' -DefaultValue ([Math]::Max([System.Environment]::ProcessorCount, 1))
}
if ($GpuLayers -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_EMBEDDED_GPU_LAYERS)) {
    $GpuLayers = Get-EnvInt -Name 'LOCAL_CODEX_EMBEDDED_GPU_LAYERS' -DefaultValue 0
}
if ($StartupTimeoutSec -le 0) {
    $StartupTimeoutSec = Get-EnvInt -Name 'LOCAL_CODEX_EMBEDDED_STARTUP_TIMEOUT_SEC' -DefaultValue 120
}

if ([string]::IsNullOrWhiteSpace($ModelAlias)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLVM_MODEL)) {
        $ModelAlias = $env:LOCAL_CODEX_LLVM_MODEL
    } else {
        $ModelAlias = [System.IO.Path]::GetFileNameWithoutExtension($ModelPath)
    }
}

$baseUrl = "http://$BindHost`:$Port/v1"
if (Test-EmbeddedEndpointReady -BaseUrl $baseUrl) {
    return [pscustomobject]@{
        started = $false
        modelPath = $ModelPath
        modelAlias = $ModelAlias
        baseUrl = $baseUrl
        processId = $null
        outLog = $null
        errLog = $null
    }
}

$llamaServer = Get-Command llama-server -ErrorAction SilentlyContinue
if (-not $llamaServer) {
    throw "Embedded llama.cpp server binary 'llama-server' not found in PATH."
}

$logDir = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LOG_DIR)) { '/tmp/local-codex-kit' } else { $env:LOCAL_CODEX_LOG_DIR }
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$outLog = Join-Path $logDir 'llama-server.out.log'
$errLog = Join-Path $logDir 'llama-server.err.log'

$argumentList = @(
    '--host', $BindHost,
    '--port', $Port,
    '--model', $ModelPath,
    '--ctx-size', $ContextSize,
    '--threads', $Threads,
    '--alias', $ModelAlias
)

if ($GpuLayers -gt 0) {
    $argumentList += @('--n-gpu-layers', $GpuLayers)
}

$proc = Start-Process -FilePath $llamaServer.Source -ArgumentList $argumentList -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog

$deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        break
    }

    if (Test-EmbeddedEndpointReady -BaseUrl $baseUrl) {
        return [pscustomobject]@{
            started = $true
            modelPath = $ModelPath
            modelAlias = $ModelAlias
            baseUrl = $baseUrl
            processId = $proc.Id
            outLog = $outLog
            errLog = $errLog
        }
    }

    Start-Sleep -Milliseconds 500
}

if (-not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

$stderrTail = ''
if (Test-Path -LiteralPath $errLog) {
    $stderrTail = ((Get-Content -LiteralPath $errLog -Tail 40) -join "`n").Trim()
}

$message = "Embedded llama-server failed to become ready at $baseUrl within $StartupTimeoutSec seconds."
if ($stderrTail) {
    $message += "`n`nRecent stderr:`n$stderrTail"
}

throw $message
