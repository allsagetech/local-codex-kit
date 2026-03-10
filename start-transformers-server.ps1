$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:LOCAL_CODEX_TRANSFORMERS_PORT = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }
$env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC = if ($env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC) { $env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC } else { '300' }
$env:LOCAL_CODEX_TRANSFORMERS_DTYPE = if ($env:LOCAL_CODEX_TRANSFORMERS_DTYPE) { $env:LOCAL_CODEX_TRANSFORMERS_DTYPE } else { 'auto' }

$transformers = Get-Command transformers -ErrorAction SilentlyContinue
if (-not $transformers) {
    throw '`transformers` CLI is not installed in this image.'
}

$manifest = @(Read-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST)
if ($manifest.Count -eq 0) {
    throw ("No official models are available in manifest '{0}'. Rebuild the image with LOCAL_CODEX_OFFICIAL_PULL_MODELS set." -f $env:LOCAL_CODEX_MODEL_MANIFEST)
}

$selectedModel = if ($env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS) {
    $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS
} elseif ($env:LOCAL_CODEX_CODEX_MODEL) {
    $env:LOCAL_CODEX_CODEX_MODEL
} else {
    $manifest[0].repo
}

$modelEntry = Resolve-InstalledModelEntry -Manifest $manifest -ModelName $selectedModel
if ($null -eq $modelEntry) {
    $availableModels = ($manifest | ForEach-Object { $_.repo }) -join ', '
    throw ("Configured official model '{0}' is not available. Installed models: {1}" -f $selectedModel, $availableModels)
}

$resolvedModelPath = if (-not [string]::IsNullOrWhiteSpace($modelEntry.package_root)) {
    Resolve-ToolchainModelPath -PackageRoot $modelEntry.package_root -ModelName $modelEntry.repo
} else {
    Resolve-ToolchainModelPath -PackageRoot $modelEntry.model_path -ModelName $modelEntry.repo
}
if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
    $resolvedModelPath = $modelEntry.model_path
}

if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
    throw ("Installed model '{0}' does not define a local model path in manifest '{1}'." -f $modelEntry.repo, $env:LOCAL_CODEX_MODEL_MANIFEST)
}

if (-not (Test-Path -LiteralPath $resolvedModelPath)) {
    throw ("Installed model path does not exist: {0}" -f $resolvedModelPath)
}

$logDir = '/tmp/local-codex-kit'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$outLog = Join-Path $logDir 'transformers.out.log'
$errLog = Join-Path $logDir 'transformers.err.log'

$argumentList = @(
    'serve',
    '--host', '127.0.0.1',
    '--port', $env:LOCAL_CODEX_TRANSFORMERS_PORT,
    '--force-model', $resolvedModelPath
)

if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TRANSFORMERS_DTYPE) -and ($env:LOCAL_CODEX_TRANSFORMERS_DTYPE -ne 'auto')) {
    $argumentList += @('--dtype', $env:LOCAL_CODEX_TRANSFORMERS_DTYPE)
}
if ($env:LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING -eq '1') {
    $argumentList += '--continuous-batching'
}
if ($env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION) {
    $argumentList += @('--attn_implementation', $env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION)
}

$proc = Start-Process -FilePath $transformers.Source -ArgumentList $argumentList -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$baseUrl = "http://127.0.0.1:$($env:LOCAL_CODEX_TRANSFORMERS_PORT)"
$deadline = (Get-Date).AddSeconds([int]$env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC)

while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        $message = "transformers serve exited before becoming ready.`n`nstdout: $outLog`nstderr: $errLog"
        throw $message
    }

    try {
        $models = Invoke-RestMethod -Uri ($baseUrl + '/v1/models') -TimeoutSec 5
        if ($models) {
            return [pscustomobject]@{
                started       = $true
                processId     = $proc.Id
                baseUrl       = $baseUrl
                modelRepo     = $modelEntry.repo
                modelPath     = $resolvedModelPath
                stdoutLogPath = $outLog
                stderrLogPath = $errLog
            }
        }
    } catch {
    }

    Start-Sleep -Seconds 1
}

try {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
} catch {
}

throw ("Timed out waiting for transformers serve to become ready. stdout: {0} stderr: {1}" -f $outLog, $errLog)
