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

$toolchainModulePath = if ($env:LOCAL_CODEX_TOOLCHAIN_MODULE_PATH) { $env:LOCAL_CODEX_TOOLCHAIN_MODULE_PATH } else { '/opt/powershell-modules' }

$env:LOCAL_CODEX_KIT_ROOT = if ($env:LOCAL_CODEX_KIT_ROOT) { $env:LOCAL_CODEX_KIT_ROOT } else { '/opt/local-codex-kit' }
$env:ToolchainPullPolicy = if ($env:ToolchainPullPolicy) { $env:ToolchainPullPolicy } else { 'IfNotPresent' }
$env:ToolchainPath = if ($env:ToolchainPath) { $env:ToolchainPath } else { '/opt/toolchain-cache' }
$env:ToolchainRepo = if ($env:ToolchainRepo) { $env:ToolchainRepo } else { '/opt/toolchain-repo' }
$env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN = if ($env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN) { $env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN } else { '1' }
$env:LOCAL_CODEX_LLVM_BASE_URL = if ($env:LOCAL_CODEX_LLVM_BASE_URL) { $env:LOCAL_CODEX_LLVM_BASE_URL } else { 'http://127.0.0.1:8000/v1' }
$env:LOCAL_CODEX_LLVM_WIRE_API = if ($env:LOCAL_CODEX_LLVM_WIRE_API) { $env:LOCAL_CODEX_LLVM_WIRE_API } else { 'chat' }
$env:LOCAL_CODEX_EMBEDDED_PORT = if ($env:LOCAL_CODEX_EMBEDDED_PORT) { $env:LOCAL_CODEX_EMBEDDED_PORT } else { '8000' }
$env:LOCAL_CODEX_EMBEDDED_REQUIRE_READY = if ($env:LOCAL_CODEX_EMBEDDED_REQUIRE_READY) { $env:LOCAL_CODEX_EMBEDDED_REQUIRE_READY } else { '0' }

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

$env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE = if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE) { $env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE } else { $defaultEmbeddedMode }
$env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS = if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS) {
    $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS
} elseif ($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH) {
    [System.IO.Path]::GetFileNameWithoutExtension($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH)
} else {
    'qwen2.5-coder-7b-instruct'
}
$env:LOCAL_CODEX_LLVM_MODEL = if ($env:LOCAL_CODEX_LLVM_MODEL) { $env:LOCAL_CODEX_LLVM_MODEL } else { $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS }
$env:LOCAL_CODEX_LLVM_API_KEY = if ($env:LOCAL_CODEX_LLVM_API_KEY) { $env:LOCAL_CODEX_LLVM_API_KEY } else { 'local' }

foreach ($candidate in @($toolchainModulePath, '/root/Documents/PowerShell/Modules', '/root/Documents/WindowsPowerShell/Modules')) {
    if (-not $candidate -or -not (Test-Path $candidate)) {
        continue
    }

    if ($env:PSModulePath) {
        if (-not ($env:PSModulePath.Split(':') -contains $candidate)) {
            $env:PSModulePath = "${candidate}:$env:PSModulePath"
        }
    } else {
        $env:PSModulePath = $candidate
    }
}

if (Get-Module -ListAvailable Toolchain) {
    Import-Module Toolchain -Force
} else {
    Write-Warning ("Toolchain module not found. Mount it at {0} or set LOCAL_CODEX_TOOLCHAIN_MODULE_PATH." -f $toolchainModulePath)
}

$workspace = if ($env:LOCAL_CODEX_WORKSPACE) {
    $env:LOCAL_CODEX_WORKSPACE
} elseif (Test-Path $env:LOCAL_CODEX_KIT_ROOT) {
    $env:LOCAL_CODEX_KIT_ROOT
} elseif (Test-Path '/workspace') {
    '/workspace'
} else {
    $env:LOCAL_CODEX_KIT_ROOT
}

if (-not (Test-Path $workspace)) {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
}

Set-Location $workspace

$embeddedServerInfo = $null
$embeddedStartupError = $null
if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE -ne '0') {
    $starterScript = Join-Path $env:LOCAL_CODEX_KIT_ROOT 'start-embedded-llm.ps1'
    if (-not (Test-Path -LiteralPath $starterScript)) {
        throw "Embedded model starter script not found: $starterScript"
    }

    try {
        $embeddedServerInfo = & $starterScript
        if ($embeddedServerInfo.baseUrl) {
            $env:LOCAL_CODEX_LLVM_BASE_URL = [string]$embeddedServerInfo.baseUrl
        }
        if ($embeddedServerInfo.modelAlias) {
            $env:LOCAL_CODEX_LLVM_MODEL = [string]$embeddedServerInfo.modelAlias
        }
    } catch {
        $embeddedStartupError = $_.Exception.Message
        $env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE = '0'

        if ($env:LOCAL_CODEX_EMBEDDED_REQUIRE_READY -eq '1') {
            throw
        }

        Write-Warning 'Embedded llama-server failed to start. Continuing without the embedded endpoint.'
        Write-Warning $embeddedStartupError
    }
}

Write-Host ''
Write-Host 'Local Codex Kit container'
Write-Host ("- Repo: {0}" -f $env:LOCAL_CODEX_KIT_ROOT)
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Codex CLI: {0}" -f ((Get-Command codex).Source))
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
Write-Host ("- Toolchain module path: {0}" -f $toolchainModulePath)
Write-Host ("- Toolchain cache path: {0}" -f $env:ToolchainPath)
Write-Host ("- Toolchain offline repo: {0}" -f $env:ToolchainRepo)
Write-Host ("- Toolchain pull policy: {0}" -f $env:ToolchainPullPolicy)
Write-Host ("- Embedded model mode: {0}" -f $(if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE -ne '0') { 'enabled' } else { 'disabled' }))
if ($env:LOCAL_CODEX_EMBEDDED_MODEL_PATH) {
    Write-Host ("- Embedded model path: {0}" -f $env:LOCAL_CODEX_EMBEDDED_MODEL_PATH)
}
if ($env:LOCAL_CODEX_EMBEDDED_MODEL_ENABLE -ne '0') {
    Write-Host ("- Embedded model alias: {0}" -f $env:LOCAL_CODEX_LLVM_MODEL)
    Write-Host ("- Embedded model endpoint: {0}" -f $env:LOCAL_CODEX_LLVM_BASE_URL)
    if ($embeddedServerInfo -and $embeddedServerInfo.started -and $embeddedServerInfo.processId) {
        Write-Host ("- Embedded model server PID: {0}" -f $embeddedServerInfo.processId)
    }
} elseif ($embeddedStartupError) {
    Write-Host '- Embedded model startup: failed; shell fallback enabled'
}
Write-Host '- Runtime state stays in Docker-managed volumes for the workspace, models, Toolchain cache, and Codex config.'
Write-Host '- Put your project under /workspace before running codex for repo-aware behavior.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: `codex`, `codex-llvm`, and `codex-vllm` use the embedded/OpenAI-compatible endpoint.'
pwsh -NoLogo
exit $LASTEXITCODE
