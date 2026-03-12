$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Test-RequiredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required path is missing: $Path"
    }
}

function Test-DockerIgnoreEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $dockerIgnorePath = Join-Path $repoRoot '.dockerignore'
    $entries = @(Get-Content -LiteralPath $dockerIgnorePath)
    if ($entries -notcontains $Entry) {
        throw "Expected '$Entry' in .dockerignore."
    }
}

function Assert-PowerShellFilesParse {
    $parseErrors = New-Object System.Collections.Generic.List[string]
    $psFiles = @(Get-ChildItem -Path $repoRoot -Recurse -Filter *.ps1 -File)

    foreach ($file in $psFiles) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

        foreach ($error in @($errors)) {
            $parseErrors.Add(("{0}: {1}" -f $file.FullName, $error.Message))
        }
    }

    if ($parseErrors.Count -gt 0) {
        throw ("PowerShell parse validation failed:`n{0}" -f ($parseErrors -join "`n"))
    }
}

function Assert-DockerComposeConfig {
    param(
        [string[]]$ComposeFiles
    )

    $docker = Get-Command docker -ErrorAction Stop
    $arguments = @('compose')
    foreach ($composeFile in $ComposeFiles) {
        $arguments += @('-f', $composeFile)
    }
    $arguments += 'config'

    & $docker.Source @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("docker compose config failed for: {0}" -f ($ComposeFiles -join ', '))
    }
}

Test-RequiredPath -Path (Join-Path $repoRoot 'host-project')
Test-DockerIgnoreEntry -Entry '.git'
Assert-PowerShellFilesParse
Assert-DockerComposeConfig -ComposeFiles @('docker-compose.yml')

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docker-compose.gpu.yml')) {
    Assert-DockerComposeConfig -ComposeFiles @('docker-compose.yml', 'docker-compose.gpu.yml')
}

Write-Host 'Static validation completed successfully.'
