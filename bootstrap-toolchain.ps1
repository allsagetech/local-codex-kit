param(
    [switch]$InstallIfMissing
)

$ErrorActionPreference = 'Stop'

$toolchainRoot = Join-Path $PSScriptRoot 'Toolchain'
$installer = Join-Path $toolchainRoot 'install.ps1'
$module = Get-Module -ListAvailable Toolchain | Sort-Object Version -Descending | Select-Object -First 1

if ((-not $module) -and (-not (Test-Path $installer))) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Toolchain checkout is missing at $toolchainRoot and Git is not available to clone it."
    }

    Write-Host 'Toolchain checkout missing. Cloning https://github.com/allsagetech/Toolchain.git ...'
    & $git.Source clone https://github.com/allsagetech/Toolchain.git $toolchainRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $installer)) {
        throw "Toolchain clone failed. Expected installer at $installer"
    }
}

if (-not $module) {
    if (-not $InstallIfMissing) {
        throw "Toolchain is not installed. Re-run with -InstallIfMissing or run .\Toolchain\install.ps1 first."
    }

    Write-Host 'Installing Toolchain from local repo...'
    & powershell -ExecutionPolicy Bypass -File $installer
    if ($LASTEXITCODE -ne 0) {
        throw "Toolchain installation failed with exit code $LASTEXITCODE"
    }
}

Import-Module Toolchain -Force
Get-Command toolchain -ErrorAction Stop | Out-Null

$installed = Get-Module -ListAvailable Toolchain | Sort-Object Version -Descending | Select-Object -First 1
Write-Host ("Toolchain ready: " + $installed.Version)
