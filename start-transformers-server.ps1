$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

function Sync-SeededHfCache {
    param(
        [string]$SeedRoot,
        [string]$TargetRoot,
        [string]$RequiredCacheSlug
    )

    if (-not (Test-Path -LiteralPath $SeedRoot)) {
        throw ("Hugging Face cache seed not found: {0}" -f $SeedRoot)
    }

    if (-not (Test-Path -LiteralPath $TargetRoot)) {
        New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    }

    $requiredSourcePath = Join-Path (Join-Path $SeedRoot 'hub') $RequiredCacheSlug
    if (-not (Test-Path -LiteralPath $requiredSourcePath)) {
        throw ("Seeded model cache entry not found: {0}" -f $requiredSourcePath)
    }

    $requiredTargetPath = Join-Path (Join-Path $TargetRoot 'hub') $RequiredCacheSlug
    if (Test-Path -LiteralPath $requiredTargetPath) {
        return
    }

    $seedItems = Get-ChildItem -LiteralPath $SeedRoot -Force
    foreach ($item in $seedItems) {
        Copy-Item -LiteralPath $item.FullName -Destination $TargetRoot -Recurse -Force
    }
}

$env:LOCAL_CODEX_HF_CACHE_SEED = if ($env:LOCAL_CODEX_HF_CACHE_SEED) { $env:LOCAL_CODEX_HF_CACHE_SEED } else { '/opt/local-codex-kit/hf-cache-seed' }
$env:LOCAL_CODEX_HF_HOME = if ($env:LOCAL_CODEX_HF_HOME) { $env:LOCAL_CODEX_HF_HOME } else { '/home/codex/.cache/huggingface' }
$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:LOCAL_CODEX_TRANSFORMERS_PORT = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }
$env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC = if ($env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC) { $env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC } else { '300' }
$env:LOCAL_CODEX_TRANSFORMERS_DTYPE = if ($env:LOCAL_CODEX_TRANSFORMERS_DTYPE) { $env:LOCAL_CODEX_TRANSFORMERS_DTYPE } else { 'auto' }
$env:TRANSFORMERS_OFFLINE = if ($env:TRANSFORMERS_OFFLINE) { $env:TRANSFORMERS_OFFLINE } else { '1' }
$env:HF_HUB_OFFLINE = if ($env:HF_HUB_OFFLINE) { $env:HF_HUB_OFFLINE } else { '1' }
$env:HF_HOME = $env:LOCAL_CODEX_HF_HOME

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

Sync-SeededHfCache `
    -SeedRoot $env:LOCAL_CODEX_HF_CACHE_SEED `
    -TargetRoot $env:LOCAL_CODEX_HF_HOME `
    -RequiredCacheSlug $modelEntry.cache_slug

$logDir = '/tmp/local-codex-kit'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$outLog = Join-Path $logDir 'transformers.out.log'
$errLog = Join-Path $logDir 'transformers.err.log'

$argumentList = @(
    'serve',
    '--host', '127.0.0.1',
    '--port', $env:LOCAL_CODEX_TRANSFORMERS_PORT,
    '--force-model', $modelEntry.repo
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
                cacheSlug     = $modelEntry.cache_slug
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
