param(
    [string]$Models
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'llama-models.ps1')

$env:LOCAL_CODEX_LLAMACPP_MODELS = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }

if (-not (Test-Path -LiteralPath $env:LOCAL_CODEX_LLAMACPP_MODELS)) {
    New-Item -ItemType Directory -Path $env:LOCAL_CODEX_LLAMACPP_MODELS -Force | Out-Null
}

$requestedModels = @(Get-ModelList -RawModels $Models)
if ($requestedModels.Count -eq 0) {
    Write-LlamaManifest -ModelRoot $env:LOCAL_CODEX_LLAMACPP_MODELS -Entries @()
    Write-Host 'Skipping llama.cpp model download because no build-time models were requested.'
    exit 0
}

$manifestEntries = @()
$seenAliases = @{}

foreach ($requestedModel in $requestedModels) {
    $alias = Convert-ToCodexModelName -ModelName $requestedModel
    $repoId = Convert-ToLlamaRepoId -ModelName $requestedModel

    if ([string]::IsNullOrWhiteSpace($alias) -or [string]::IsNullOrWhiteSpace($repoId)) {
        throw "Unable to resolve llama.cpp model metadata for '$requestedModel'."
    }

    if ($seenAliases.ContainsKey($alias)) {
        continue
    }

    $targetDirectory = Join-Path $env:LOCAL_CODEX_LLAMACPP_MODELS $alias
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

    Write-Host ("Downloading llama.cpp model '{0}' from Hugging Face repo '{1}'..." -f $alias, $repoId)
    & python -m huggingface_hub download $repoId --local-dir $targetDirectory --include '*.gguf'
    if ($LASTEXITCODE -ne 0) {
        throw ("huggingface_hub download failed for repo '{0}'." -f $repoId)
    }

    $modelFile = Select-PrimaryGgufFile -ModelDirectory $targetDirectory
    if ([string]::IsNullOrWhiteSpace($modelFile)) {
        throw ("No .gguf model file was downloaded for repo '{0}'." -f $repoId)
    }

    $manifestEntries += [pscustomobject]@{
        alias        = $alias
        repo         = $repoId
        source_model = $requestedModel
        directory    = $targetDirectory
        model_file   = $modelFile
    }
    $seenAliases[$alias] = $true
}

Write-LlamaManifest -ModelRoot $env:LOCAL_CODEX_LLAMACPP_MODELS -Entries $manifestEntries
Write-Host ("Prepared {0} llama.cpp model(s) under '{1}'." -f $manifestEntries.Count, $env:LOCAL_CODEX_LLAMACPP_MODELS)
