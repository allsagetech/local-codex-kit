$ErrorActionPreference = 'Stop'
$Command = @($args)

$toolchainRepo = if ($env:LOCAL_CODEX_TOOLCHAIN_REPO) {
    $env:LOCAL_CODEX_TOOLCHAIN_REPO
} else {
    '/opt/toolchain'
}

$env:ToolchainPullPolicy = if ($env:ToolchainPullPolicy) { $env:ToolchainPullPolicy } else { 'Never' }
$env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN = if ($env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN) { $env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN } else { '1' }

if (-not (Get-Module -ListAvailable Toolchain)) {
    $toolchainInstaller = Join-Path $toolchainRepo 'install.ps1'
    if (Test-Path $toolchainInstaller) {
        Write-Host ("Installing Toolchain module from {0}..." -f $toolchainRepo)
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $toolchainInstaller
    }
}

if (Get-Module -ListAvailable Toolchain) {
    Import-Module Toolchain -Force
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
Write-Host ("- Toolchain repo: {0}" -f $toolchainRepo)
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
