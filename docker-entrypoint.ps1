$ErrorActionPreference = 'Stop'
$Command = @($args)

$toolchainModulePath = if ($env:LOCAL_CODEX_TOOLCHAIN_MODULE_PATH) { $env:LOCAL_CODEX_TOOLCHAIN_MODULE_PATH } else { '/opt/powershell-modules' }

$env:ToolchainPullPolicy = if ($env:ToolchainPullPolicy) { $env:ToolchainPullPolicy } else { 'IfNotPresent' }
$env:ToolchainPath = if ($env:ToolchainPath) { $env:ToolchainPath } else { '/opt/toolchain-cache' }
$env:ToolchainRepo = if ($env:ToolchainRepo) { $env:ToolchainRepo } else { '/opt/toolchain-repo' }
$env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN = if ($env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN) { $env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN } else { '1' }

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
} elseif (Test-Path '/workspace') {
    '/workspace'
} else {
    '/opt/local-codex-kit'
}

if (Test-Path $workspace) {
    Set-Location $workspace
}

Write-Host ''
Write-Host 'Local Codex Kit container'
Write-Host ("- Repo: {0}" -f '/opt/local-codex-kit')
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Codex CLI: {0}" -f ((Get-Command codex).Source))
Write-Host ("- Network mode: {0}" -f 'offline (set by docker compose)')
Write-Host ("- Toolchain module path: {0}" -f $toolchainModulePath)
Write-Host ("- Toolchain cache path: {0}" -f $env:ToolchainPath)
Write-Host ("- Toolchain offline repo: {0}" -f $env:ToolchainRepo)
Write-Host ("- Toolchain pull policy: {0}" -f $env:ToolchainPullPolicy)
Write-Host '- Use this container for the kit scripts and Codex CLI environment.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: `codex` uses LLVM/vLLM preset with Toolchain, `codex-local` uses LM Studio preset.'
pwsh -NoLogo
exit $LASTEXITCODE
