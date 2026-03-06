$ErrorActionPreference = 'Stop'
$Command = @($args)

function Get-FirstConfiguredOllamaModel {
    param(
        [string]$RawModels
    )

    if ([string]::IsNullOrWhiteSpace($RawModels)) {
        return $null
    }

    foreach ($entry in $RawModels.Split(',')) {
        $model = $entry.Trim()
        if ((-not [string]::IsNullOrWhiteSpace($model)) -and ($model -ne 'none')) {
            return $model
        }
    }

    return $null
}

function Convert-ToOllamaModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    return $resolvedModel
}

function Convert-ToCodexModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss:(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    return $resolvedModel
}

function Get-InstalledOllamaModels {
    try {
        $lines = @(& ollama list 2>$null)
    } catch {
        return @()
    }

    return @(
        $lines |
        Select-Object -Skip 1 |
        ForEach-Object {
            $trimmed = $_.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                (($trimmed -split '\s+')[0]).Trim()
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
}

function Ensure-OllamaModelAlias {
    param(
        [string]$SourceModel,
        [string]$AliasModel
    )

    if ([string]::IsNullOrWhiteSpace($SourceModel) -or [string]::IsNullOrWhiteSpace($AliasModel)) {
        return $SourceModel
    }

    if ($SourceModel -eq $AliasModel) {
        return $AliasModel
    }

    $installedModels = @(Get-InstalledOllamaModels)
    if ($installedModels -notcontains $SourceModel) {
        Write-Warning ("Requested Ollama model '{0}' is not installed; Codex will keep using that model name directly." -f $SourceModel)
        return $SourceModel
    }

    if ($installedModels -contains $AliasModel) {
        return $AliasModel
    }

    try {
        & ollama cp $SourceModel $AliasModel | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $AliasModel
        }
    } catch {
        Write-Warning ("Failed to create Ollama alias '{0}' -> '{1}'. Codex will keep using '{1}' directly." -f $AliasModel, $SourceModel)
        return $SourceModel
    }

    Write-Warning ("Ollama alias creation returned a non-zero exit code for '{0}' -> '{1}'. Codex will keep using '{1}' directly." -f $AliasModel, $SourceModel)
    return $SourceModel
}

$env:LOCAL_CODEX_KIT_ROOT = if ($env:LOCAL_CODEX_KIT_ROOT) { $env:LOCAL_CODEX_KIT_ROOT } else { '/opt/local-codex-kit' }
$env:LOCAL_CODEX_WORKSPACE = if ($env:LOCAL_CODEX_WORKSPACE) { $env:LOCAL_CODEX_WORKSPACE } else { '/workspace' }
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS = if ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS) { $env:LOCAL_CODEX_OLLAMA_PULL_MODELS } else { '' }
$env:LOCAL_CODEX_OLLAMA_PORT = if ($env:LOCAL_CODEX_OLLAMA_PORT) { $env:LOCAL_CODEX_OLLAMA_PORT } else { '11434' }
$env:LOCAL_CODEX_OLLAMA_REQUIRE_READY = if ($env:LOCAL_CODEX_OLLAMA_REQUIRE_READY) { $env:LOCAL_CODEX_OLLAMA_REQUIRE_READY } else { '0' }

$defaultOllamaModel = Get-FirstConfiguredOllamaModel -RawModels $env:LOCAL_CODEX_OLLAMA_PULL_MODELS
$requestedModel = if ($env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS) {
    $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS
} elseif ($defaultOllamaModel) {
    $defaultOllamaModel
} else {
    ''
}
$preferredCodexModel = Convert-ToCodexModelName -ModelName $requestedModel

$env:LOCAL_CODEX_OLLAMA_ENABLE = if ($env:LOCAL_CODEX_OLLAMA_ENABLE) { $env:LOCAL_CODEX_OLLAMA_ENABLE } else { '1' }
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS = if ($requestedModel) {
    Convert-ToOllamaModelName -ModelName $requestedModel
} else {
    ''
}
$env:LOCAL_CODEX_CODEX_MODEL_ALIAS = $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS

$workspace = $env:LOCAL_CODEX_WORKSPACE
if (-not (Test-Path -LiteralPath $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

Set-Location $workspace

$ollamaInfo = $null
$ollamaStartupError = $null
if ($env:LOCAL_CODEX_OLLAMA_ENABLE -ne '0') {
    $ollamaStarterScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'start-ollama.ps1'
    if (-not (Test-Path -LiteralPath $ollamaStarterScript)) {
        throw "Ollama starter script not found: $ollamaStarterScript"
    }

    try {
        $ollamaInfo = & $ollamaStarterScript
    } catch {
        $ollamaStartupError = $_.Exception.Message
        $env:LOCAL_CODEX_OLLAMA_ENABLE = '0'

        if ($env:LOCAL_CODEX_OLLAMA_REQUIRE_READY -eq '1') {
            throw
        }

        Write-Warning 'Embedded Ollama failed to start. Continuing without a local model runtime.'
        Write-Warning $ollamaStartupError
    }
}

$ollamaHost = if ($env:LOCAL_CODEX_OLLAMA_HOST) { $env:LOCAL_CODEX_OLLAMA_HOST } else { '127.0.0.1' }
$env:LOCAL_CODEX_OLLAMA_BASE_URL = if ($ollamaInfo) {
    '{0}/v1' -f $ollamaInfo.ollamaBaseUrl.TrimEnd('/')
} else {
    "http://$ollamaHost`:$($env:LOCAL_CODEX_OLLAMA_PORT)/v1"
}

if ($ollamaInfo -and $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS) {
    $env:LOCAL_CODEX_CODEX_MODEL_ALIAS = Ensure-OllamaModelAlias -SourceModel $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS -AliasModel $preferredCodexModel
}

$codexConfigPath = $null
$codexConfigError = $null
$codexModel = if ($env:LOCAL_CODEX_CODEX_MODEL_ALIAS) {
    $env:LOCAL_CODEX_CODEX_MODEL_ALIAS
} else {
    $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS
}
$codexConfiguratorScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'configure-codex.ps1'
if (Test-Path -LiteralPath $codexConfiguratorScript) {
    try {
        $codexConfigPath = & $codexConfiguratorScript -BaseUrl $env:LOCAL_CODEX_OLLAMA_BASE_URL -Model $codexModel
    } catch {
        $codexConfigError = $_.Exception.Message
        Write-Warning 'Codex config generation failed. Continuing with manual Codex setup.'
        Write-Warning $codexConfigError
    }
}

Write-Host ''
Write-Host 'Local Ollama container'
Write-Host ("- Repo: {0}" -f $env:LOCAL_CODEX_KIT_ROOT)
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
if ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS -and ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS -ne 'none')) {
    Write-Host ("- Build-pulled Ollama models: {0}" -f $env:LOCAL_CODEX_OLLAMA_PULL_MODELS)
}
Write-Host ("- Ollama mode: {0}" -f $(if ($env:LOCAL_CODEX_OLLAMA_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($ollamaInfo) {
    Write-Host ("- Ollama endpoint: {0}" -f $ollamaInfo.ollamaBaseUrl)
    Write-Host ("- Ollama model alias: {0}" -f $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS)
    if ($env:LOCAL_CODEX_CODEX_MODEL_ALIAS -and ($env:LOCAL_CODEX_CODEX_MODEL_ALIAS -ne $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS)) {
        Write-Host ("- Codex model alias: {0}" -f $env:LOCAL_CODEX_CODEX_MODEL_ALIAS)
    }
    if ($ollamaInfo.started -and $ollamaInfo.processId) {
        Write-Host ("- Ollama PID: {0}" -f $ollamaInfo.processId)
    }
} elseif ($ollamaStartupError) {
    Write-Host '- Ollama startup: failed; shell fallback enabled'
}
if ($codexConfigPath) {
    Write-Host ("- Codex config: {0}" -f $codexConfigPath)
    Write-Host ("- Codex default profile: {0}" -f 'oss')
} elseif ($codexConfigError) {
    Write-Host '- Codex config: failed; manual setup required'
}
Write-Host '- Runtime state stays in Docker-managed volumes for the workspace and Ollama state.'
Write-Host '- Put your project under /workspace before running codex or ollama-local.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: use `codex`, `codex-local`, `ollama-local`, or `ollama run <model>`.'
pwsh -NoLogo
exit $LASTEXITCODE
