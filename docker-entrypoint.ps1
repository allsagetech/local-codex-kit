$ErrorActionPreference = 'Stop'
$Command = @($args)

function Get-FirstEmbeddedModelPath {
    $modelRoot = '/opt/models'
    if (-not (Test-Path -LiteralPath $modelRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $modelRoot -Filter '*.gguf' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    return $null
}

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

$env:LOCAL_CODEX_KIT_ROOT = if ($env:LOCAL_CODEX_KIT_ROOT) { $env:LOCAL_CODEX_KIT_ROOT } else { '/opt/local-codex-kit' }
$env:LOCAL_CODEX_WORKSPACE = if ($env:LOCAL_CODEX_WORKSPACE) { $env:LOCAL_CODEX_WORKSPACE } else { '/workspace' }
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS = if ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS) { $env:LOCAL_CODEX_OLLAMA_PULL_MODELS } else { '' }
$env:LOCAL_CODEX_OLLAMA_PORT = if ($env:LOCAL_CODEX_OLLAMA_PORT) { $env:LOCAL_CODEX_OLLAMA_PORT } else { '11434' }
$env:LOCAL_CODEX_OLLAMA_REQUIRE_READY = if ($env:LOCAL_CODEX_OLLAMA_REQUIRE_READY) { $env:LOCAL_CODEX_OLLAMA_REQUIRE_READY } else { '0' }

if (-not $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH) {
    $detectedModel = Get-FirstEmbeddedModelPath
    if ($detectedModel) {
        $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH = $detectedModel
    }
}

$defaultEmbeddedMode = '0'
if ($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH -and (Test-Path -LiteralPath $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH -PathType Leaf)) {
    $defaultEmbeddedMode = '1'
}
$defaultOllamaModel = Get-FirstConfiguredOllamaModel -RawModels $env:LOCAL_CODEX_OLLAMA_PULL_MODELS

$env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE = if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE) { $env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE } else { $defaultEmbeddedMode }
$env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS = if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS) {
    $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS
} elseif ($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH) {
    [System.IO.Path]::GetFileNameWithoutExtension($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH)
} else {
    'qwen2.5-coder-7b-instruct'
}
$env:LOCAL_CODEX_OLLAMA_ENABLE = if ($env:LOCAL_CODEX_OLLAMA_ENABLE) { $env:LOCAL_CODEX_OLLAMA_ENABLE } else { '1' }
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS = if ($env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS) {
    $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS
} elseif ($defaultOllamaModel) {
    $defaultOllamaModel
} else {
    $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS
}
$env:LOCAL_CODEX_OLLAMA_CONTEXT = if ($env:LOCAL_CODEX_OLLAMA_CONTEXT) {
    $env:LOCAL_CODEX_OLLAMA_CONTEXT
} elseif ($env:LOCAL_CODEX_EMBEDDED_CONTEXT) {
    $env:LOCAL_CODEX_EMBEDDED_CONTEXT
} else {
    '8192'
}

$workspace = $env:LOCAL_CODEX_WORKSPACE
if (-not (Test-Path -LiteralPath $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

Set-Location $workspace

$ollamaInfo = $null
$ollamaStartupError = $null
if ($env:LOCAL_CODEX_OLLAMA_ENABLE -ne '0') {
    $ollamaStarterScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'start-embedded-ollama.ps1'
    if (-not (Test-Path -LiteralPath $ollamaStarterScript)) {
        throw "Embedded Ollama starter script not found: $ollamaStarterScript"
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

Write-Host ''
Write-Host 'Local Ollama container'
Write-Host ("- Repo: {0}" -f $env:LOCAL_CODEX_KIT_ROOT)
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
Write-Host ("- Embedded model mode: {0}" -f $(if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH) {
    Write-Host ("- Embedded model path: {0}" -f $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH)
}
Write-Host ("- Embedded model alias: {0}" -f $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS)
if ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS -and ($env:LOCAL_CODEX_OLLAMA_PULL_MODELS -ne 'none')) {
    Write-Host ("- Build-pulled Ollama models: {0}" -f $env:LOCAL_CODEX_OLLAMA_PULL_MODELS)
}
Write-Host ("- Ollama mode: {0}" -f $(if ($env:LOCAL_CODEX_OLLAMA_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($ollamaInfo) {
    Write-Host ("- Ollama endpoint: {0}" -f $ollamaInfo.ollamaBaseUrl)
    Write-Host ("- Ollama model alias: {0}" -f $ollamaInfo.modelAlias)
    if ($ollamaInfo.started -and $ollamaInfo.processId) {
        Write-Host ("- Ollama PID: {0}" -f $ollamaInfo.processId)
    }
} elseif ($ollamaStartupError) {
    Write-Host '- Ollama startup: failed; shell fallback enabled'
}
Write-Host '- Runtime state stays in Docker-managed volumes for the workspace, models, and Ollama state.'
Write-Host '- Put your project under /workspace before running ollama-local.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: use `ollama-local` or `ollama run <model>`.'
pwsh -NoLogo
exit $LASTEXITCODE
