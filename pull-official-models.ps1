param(
    [string]$Models
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

$env:LOCAL_CODEX_HF_CACHE_SEED = if ($env:LOCAL_CODEX_HF_CACHE_SEED) { $env:LOCAL_CODEX_HF_CACHE_SEED } else { '/opt/local-codex-kit/hf-cache-seed' }
$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:HF_HUB_DOWNLOAD_TIMEOUT = if ($env:HF_HUB_DOWNLOAD_TIMEOUT) { $env:HF_HUB_DOWNLOAD_TIMEOUT } else { '120' }

if (-not (Test-Path -LiteralPath $env:LOCAL_CODEX_HF_CACHE_SEED)) {
    New-Item -ItemType Directory -Path $env:LOCAL_CODEX_HF_CACHE_SEED -Force | Out-Null
}

$hfCli = Get-Command huggingface-cli -ErrorAction SilentlyContinue
if (-not $hfCli) {
    $hfCli = Get-Command hf -ErrorAction SilentlyContinue
}
if (-not $hfCli) {
    throw 'Neither `huggingface-cli` nor `hf` is installed in this image.'
}

$requestedModels = @(Get-ModelList -RawModels $Models)
if ($requestedModels.Count -eq 0) {
    Write-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST -Entries @()
    Write-Host 'Skipping official model download because no build-time models were requested.'
    exit 0
}

$manifestEntries = @()
$seenRepos = @{}

foreach ($requestedModel in $requestedModels) {
    $repoId = Convert-ToCanonicalModelName -ModelName $requestedModel
    $alias = Convert-ToModelAlias -ModelName $requestedModel
    $cacheSlug = Convert-ToHfCacheSlug -ModelName $requestedModel

    if ([string]::IsNullOrWhiteSpace($repoId) -or [string]::IsNullOrWhiteSpace($alias)) {
        throw "Unable to resolve official model metadata for '$requestedModel'."
    }

    if ($seenRepos.ContainsKey($repoId)) {
        continue
    }

    Write-Host ("Downloading official Hugging Face model '{0}'..." -f $repoId)

    $downloadArgs = @('download', $repoId, '--cache-dir', $env:LOCAL_CODEX_HF_CACHE_SEED)
    if ($env:HF_TOKEN) {
        $downloadArgs += @('--token', $env:HF_TOKEN)
    }

    & $hfCli.Source @downloadArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("Official model download failed for '{0}'." -f $repoId)
    }

    $manifestEntries += [pscustomobject]@{
        alias        = $alias
        repo         = $repoId
        source_model = $requestedModel
        cache_slug   = $cacheSlug
    }
    $seenRepos[$repoId] = $true
}

Write-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST -Entries $manifestEntries
Write-Host ("Prepared {0} official model(s) in Hugging Face cache seed '{1}'." -f $manifestEntries.Count, $env:LOCAL_CODEX_HF_CACHE_SEED)
