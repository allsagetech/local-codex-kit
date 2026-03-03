param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '.toolchain-offline'),
    [string]$CodexPackage = 'codex-linux:latest',
    [string]$GitPackage = 'git-linux:latest',
    [string]$LlvmPackage = 'llvm-linux:latest',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Toolchain)) {
    throw 'Toolchain module is not installed. Install Toolchain first, then re-run this script.'
}

Import-Module Toolchain -Force

if ($Clean -and (Test-Path $OutputPath)) {
    Remove-Item -Path $OutputPath -Recurse -Force
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$resolvedOutput = (Resolve-Path $OutputPath).Path
$packages = @($CodexPackage, $GitPackage, $LlvmPackage)

foreach ($package in $packages) {
    Write-Host ("Saving Toolchain package {0} -> {1}" -f $package, $resolvedOutput)
    toolchain save -Index $package $resolvedOutput | Out-Host
}

Write-Host ''
Write-Host 'Toolchain offline repo ready for Docker build:'
Write-Host ("- Path: {0}" -f $resolvedOutput)
Write-Host '- Package refs:'
Write-Host ("  - {0}" -f $CodexPackage)
Write-Host ("  - {0}" -f $GitPackage)
Write-Host ("  - {0}" -f $LlvmPackage)
