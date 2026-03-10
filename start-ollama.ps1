param(
    [string]$BindHost = $(if ([string]::IsNullOrWhiteSpace($env:LOCAL_OLLAMA_HOST)) { '127.0.0.1' } else { $env:LOCAL_OLLAMA_HOST }),
    [int]$Port = 0,
    [string]$ModelAlias = $env:LOCAL_OLLAMA_MODEL_ALIAS,
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

function Get-LogTail {
    param(
        [string]$Path,
        [int]$Lines = 40
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return ((Get-Content -LiteralPath $Path -Tail $Lines) -join "`n").Trim()
}

function Test-OllamaEndpointReady {
    param(
        [string]$BaseUrl
    )

    $base = $BaseUrl.TrimEnd('/')
    $candidates = @(
        "$base/api/tags",
        "$base/v1/models"
    ) | Select-Object -Unique

    foreach ($uri in $candidates) {
        try {
            $null = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 2
            return $true
        } catch {
            if ($_.Exception.Response -ne $null) {
                return $true
            }
        }
    }

    return $false
}

if ($Port -le 0) {
    $Port = Get-EnvInt -Name 'LOCAL_OLLAMA_PORT' -DefaultValue 11434
}
if ($StartupTimeoutSec -le 0) {
    $StartupTimeoutSec = Get-EnvInt -Name 'LOCAL_OLLAMA_STARTUP_TIMEOUT_SEC' -DefaultValue 300
}

$contextLength = Get-EnvInt -Name 'LOCAL_OLLAMA_CONTEXT_LENGTH' -DefaultValue 65536
if ($contextLength -gt 0) {
    $env:OLLAMA_CONTEXT_LENGTH = "$contextLength"
}

$env:OLLAMA_MODELS = if ($env:LOCAL_OLLAMA_MODELS) { $env:LOCAL_OLLAMA_MODELS } elseif ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { '/opt/local-ollama-kit/ollama-models' }
if (-not (Test-Path -LiteralPath $env:OLLAMA_MODELS)) {
    throw "Configured Ollama model store does not exist: $($env:OLLAMA_MODELS)"
}

$baseUrl = "http://$BindHost`:$Port"

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    throw 'Ollama was not found in PATH.'
}

$logDir = if ([string]::IsNullOrWhiteSpace($env:LOCAL_OLLAMA_LOG_DIR)) { '/tmp/local-ollama-kit' } else { $env:LOCAL_OLLAMA_LOG_DIR }
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$env:OLLAMA_HOST = "$BindHost`:$Port"

$outLog = Join-Path $logDir 'ollama.out.log'
$errLog = Join-Path $logDir 'ollama.err.log'
$started = $false
$processId = $null

if (-not (Test-OllamaEndpointReady -BaseUrl $baseUrl)) {
    $proc = Start-Process -FilePath $ollama.Source -ArgumentList @('serve') -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            break
        }

        if (Test-OllamaEndpointReady -BaseUrl $baseUrl) {
            $started = $true
            $processId = $proc.Id
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $started) {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }

        $stdoutTail = Get-LogTail -Path $outLog -Lines 40
        $stderrTail = Get-LogTail -Path $errLog -Lines 40
        $message = "Ollama failed to become ready at $baseUrl within $StartupTimeoutSec seconds."
        $message += "`n`nCommand: $($ollama.Source) serve"
        $message += "`nStdout log: $outLog"
        $message += "`nStderr log: $errLog"
        if ($stdoutTail) {
            $message += "`n`nRecent stdout:`n$stdoutTail"
        }
        if ($stderrTail) {
            $message += "`n`nRecent stderr:`n$stderrTail"
        }

        throw $message
    }
}

[pscustomobject]@{
    started = $started
    contextLength = $contextLength
    modelAlias = $ModelAlias
    ollamaBaseUrl = $baseUrl
    processId = $processId
    outLog = $outLog
    errLog = $errLog
}
