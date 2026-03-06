param(
    [string]$Models = $env:LOCAL_CODEX_OLLAMA_PULL_MODELS,
    [int]$Port = 11434,
    [int]$StartupTimeoutSec = 180
)

$ErrorActionPreference = 'Stop'

function Get-ModelList {
    param(
        [string]$RawModels
    )

    if ([string]::IsNullOrWhiteSpace($RawModels)) {
        return @()
    }

    return @(
        $RawModels.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { (-not [string]::IsNullOrWhiteSpace($_)) -and ($_ -ne 'none') }
    )
}

function Wait-ForOllama {
    param(
        [string]$BaseUrl,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -Method Get -Uri ($BaseUrl.TrimEnd('/') + '/api/tags') -TimeoutSec 2
            return
        } catch {
            if ($_.Exception.Response -ne $null) {
                return
            }
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Ollama did not become ready at $BaseUrl within $TimeoutSec seconds."
}

$resolvedModels = Get-ModelList -RawModels $Models
if ($resolvedModels.Count -eq 0) {
    Write-Host 'No Ollama models requested for build-time pull.'
    exit 0
}

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    throw 'Ollama was not found in PATH.'
}

$hostAddress = "127.0.0.1:$Port"
$baseUrl = "http://$hostAddress"
$env:OLLAMA_HOST = $hostAddress

$logDir = '/tmp/local-codex-kit-build'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$outLog = Join-Path $logDir 'ollama-build.out.log'
$errLog = Join-Path $logDir 'ollama-build.err.log'
$proc = Start-Process -FilePath $ollama.Source -ArgumentList @('serve') -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog

try {
    Wait-ForOllama -BaseUrl $baseUrl -TimeoutSec $StartupTimeoutSec

    foreach ($model in $resolvedModels) {
        Write-Host ("Pulling Ollama model: {0}" -f $model)
        & $ollama.Source pull $model
        if ($LASTEXITCODE -ne 0) {
            throw ("ollama pull failed for model '{0}' with exit code {1}." -f $model, $LASTEXITCODE)
        }
    }
} finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}
