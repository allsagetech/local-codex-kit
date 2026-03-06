param(
    [string]$ModelPath = $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH,
    [string]$BindHost = $(if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OLLAMA_HOST)) { '127.0.0.1' } else { $env:LOCAL_CODEX_OLLAMA_HOST }),
    [int]$Port = 0,
    [string]$ModelAlias = $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS,
    [int]$ContextSize = 0,
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

function Test-OllamaModelPresent {
    param(
        [string]$BaseUrl,
        [string]$ModelAlias
    )

    try {
        $response = Invoke-RestMethod -Method Get -Uri ($BaseUrl.TrimEnd('/') + '/api/tags') -TimeoutSec 5
    } catch {
        return $false
    }

    foreach ($model in @($response.models)) {
        foreach ($candidate in @($model.name, $model.model)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            if (($candidate -eq $ModelAlias) -or ($candidate -like "${ModelAlias}:*")) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-OllamaModel {
    param(
        [string]$OllamaPath,
        [string]$BaseUrl,
        [string]$ModelAlias,
        [string]$ModelPath,
        [int]$ContextSize,
        [string]$LogDir
    )

    if (Test-OllamaModelPresent -BaseUrl $BaseUrl -ModelAlias $ModelAlias) {
        return
    }

    $modelfileDir = Join-Path $LogDir 'ollama'
    if (-not (Test-Path -LiteralPath $modelfileDir)) {
        New-Item -ItemType Directory -Path $modelfileDir -Force | Out-Null
    }

    $safeAlias = ($ModelAlias -replace '[^A-Za-z0-9._-]', '_')
    $modelfilePath = Join-Path $modelfileDir ("{0}.Modelfile" -f $safeAlias)
    $modelfileLines = @("FROM $ModelPath")
    if ($ContextSize -gt 0) {
        $modelfileLines += "PARAMETER num_ctx $ContextSize"
    }
    Set-Content -LiteralPath $modelfilePath -Value $modelfileLines

    $createOutLog = Join-Path $LogDir 'ollama-create.out.log'
    $createErrLog = Join-Path $LogDir 'ollama-create.err.log'
    $createProc = Start-Process -FilePath $OllamaPath -ArgumentList @('create', $ModelAlias, '-f', $modelfilePath) -Wait -PassThru -RedirectStandardOutput $createOutLog -RedirectStandardError $createErrLog
    if ($createProc.ExitCode -ne 0) {
        $stdoutTail = Get-LogTail -Path $createOutLog -Lines 40
        $stderrTail = Get-LogTail -Path $createErrLog -Lines 40
        $message = "Ollama failed to import local model '$ModelAlias' from $ModelPath."
        $message += "`n`nCommand: $OllamaPath create $ModelAlias -f $modelfilePath"
        $message += "`nStdout log: $createOutLog"
        $message += "`nStderr log: $createErrLog"
        if ($stdoutTail) {
            $message += "`n`nRecent stdout:`n$stdoutTail"
        }
        if ($stderrTail) {
            $message += "`n`nRecent stderr:`n$stderrTail"
        }

        throw $message
    }

    if (-not (Test-OllamaModelPresent -BaseUrl $BaseUrl -ModelAlias $ModelAlias)) {
        throw "Ollama create completed but model '$ModelAlias' is still missing from $BaseUrl/api/tags."
    }
}

$hasLocalModel = $false
if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = '/opt/models/qwen2.5-coder-7b-instruct-q4_k_m.gguf'
}
if (-not [string]::IsNullOrWhiteSpace($ModelPath) -and (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    $hasLocalModel = $true
} else {
    $ModelPath = $null
}

if ($Port -le 0) {
    $Port = Get-EnvInt -Name 'LOCAL_CODEX_OLLAMA_PORT' -DefaultValue 11434
}
if ($ContextSize -le 0) {
    $ContextSize = Get-EnvInt -Name 'LOCAL_CODEX_OLLAMA_CONTEXT' -DefaultValue 8192
}
if ($StartupTimeoutSec -le 0) {
    $StartupTimeoutSec = Get-EnvInt -Name 'LOCAL_CODEX_OLLAMA_STARTUP_TIMEOUT_SEC' -DefaultValue 300
}

if ([string]::IsNullOrWhiteSpace($ModelAlias) -and $hasLocalModel) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS)) {
        $ModelAlias = $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS
    } else {
        $ModelAlias = [System.IO.Path]::GetFileNameWithoutExtension($ModelPath)
    }
}

$baseUrl = "http://$BindHost`:$Port"
$openAiBaseUrl = "$baseUrl/v1"

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    throw "Ollama was not found in PATH."
}

$logDir = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LOG_DIR)) { '/tmp/local-codex-kit' } else { $env:LOCAL_CODEX_LOG_DIR }
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
        $message = "Embedded Ollama failed to become ready at $baseUrl within $StartupTimeoutSec seconds."
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

if ($hasLocalModel -and -not [string]::IsNullOrWhiteSpace($ModelAlias)) {
    Ensure-OllamaModel -OllamaPath $ollama.Source -BaseUrl $baseUrl -ModelAlias $ModelAlias -ModelPath $ModelPath -ContextSize $ContextSize -LogDir $logDir
}

[pscustomobject]@{
    started = $started
    modelPath = $ModelPath
    modelAlias = $ModelAlias
    baseUrl = $openAiBaseUrl
    ollamaBaseUrl = $baseUrl
    processId = $processId
    outLog = $outLog
    errLog = $errLog
}
