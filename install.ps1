param(
    [string]$KitPath = $PSScriptRoot,
    [ValidateSet('local', 'qwen', 'small')]
    [string]$Preset = 'local',
    [ValidateSet('prompt', 'default', 'interactive', 'skip')]
    [string]$ModelSetup = 'prompt',
    [switch]$SkipModelDownload,
    [switch]$DryRun,
    [string]$ProfilePath = $PROFILE
)

$ErrorActionPreference = 'Stop'

function Get-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($command.CommandType -in @('Application', 'ExternalScript')) {
            return $command
        }
    }

    return $null
}

function Invoke-DryRunStep {
    param(
        [string]$Message
    )

    Write-Host ("[dry-run] {0}" -f $Message)
}

function Test-LmStudioDesktopInstalled {
    $expectedCli = Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'
    if (Test-Path $expectedCli -PathType Leaf) {
        return $true
    }

    return [bool](Get-Command 'lms' -ErrorAction SilentlyContinue)
}

function Install-LmStudioDesktop {
    if ($DryRun) {
        Invoke-DryRunStep 'Would install LM Studio desktop from the official Windows installer script.'
        return
    }

    Write-Host 'LM Studio desktop missing. Installing from the official Windows installer script...'
    $scriptText = (Invoke-WebRequest -UseBasicParsing 'https://lmstudio.ai/install.ps1').Content
    Invoke-Expression $scriptText
}

function Ensure-LmStudioCli {
    if (Get-Command 'lms' -ErrorAction SilentlyContinue) {
        return
    }

    $bootstrapCli = Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'
    if (Test-Path $bootstrapCli -PathType Leaf) {
        if ($DryRun) {
            Invoke-DryRunStep "Would run '$bootstrapCli bootstrap'."
            return
        }
        cmd /c "$bootstrapCli bootstrap" | Out-Host
    }

    if (-not (Get-Command 'lms' -ErrorAction SilentlyContinue)) {
        if ($DryRun) {
            Invoke-DryRunStep 'Would bootstrap LM Studio CLI through Toolchain lmstudio:latest.'
            return
        }
        Write-Host 'LM Studio CLI missing from PATH. Bootstrapping it through Toolchain lmstudio:latest...'
        toolchain exec lmstudio:latest {
            lmstudio install-cli | Out-Host
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'Toolchain failed to bootstrap LM Studio CLI. Install LM Studio, run it once, then re-run .\install.ps1.'
        }
    }
}

function Ensure-LmStudioModels {
    param(
        [string[]]$Models
    )

    $lsOutput = (& lms ls --json 2>$null | Out-String).Trim()
    $installedModels = @()
    if ($lsOutput) {
        try {
            $parsed = $lsOutput | ConvertFrom-Json
            if ($parsed -is [System.Collections.IEnumerable]) {
                foreach ($item in $parsed) {
                    if ($item.PSObject.Properties['path']) { $installedModels += [string]$item.path }
                    if ($item.PSObject.Properties['id']) { $installedModels += [string]$item.id }
                    if ($item.PSObject.Properties['identifier']) { $installedModels += [string]$item.identifier }
                }
            }
        } catch {
        }
    }

    foreach ($model in $Models) {
        $alreadyInstalled = $false
        foreach ($candidate in $installedModels) {
            if ($candidate -like "*$model*") {
                $alreadyInstalled = $true
                break
            }
        }

        if ($alreadyInstalled) {
            Write-Host ("LM Studio model already present: {0}" -f $model)
            continue
        }

        if ($DryRun) {
            Invoke-DryRunStep "Would download LM Studio model: $model"
            continue
        }

        Write-Host ("Downloading LM Studio model: {0}" -f $model)
        & lms get $model | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "LM Studio failed to download model: $model"
        }
    }
}

function Invoke-LmStudioModelSetup {
    param(
        [ValidateSet('prompt', 'default', 'interactive', 'skip')]
        [string]$Mode
    )

    if ($SkipModelDownload -or $Mode -eq 'skip') {
        return 'skipped'
    }

    if ($Mode -eq 'prompt') {
        Write-Host ''
        Write-Host 'LM Studio model setup:'
        Write-Host '1. Download the recommended default models'
        Write-Host '2. Choose models interactively with LM Studio'
        Write-Host '3. Skip model downloads for now'
        $selection = Read-Host 'Select 1, 2, or 3'
        switch ($selection) {
            '1' { $Mode = 'default' }
            '2' { $Mode = 'interactive' }
            '3' { $Mode = 'skip' }
            default { $Mode = 'default' }
        }
    }

    switch ($Mode) {
        'default' {
            $models = @('openai/gpt-oss-20b')
            switch ($Preset) {
                'qwen' { $models += 'qwen2.5-coder-32b-instruct' }
                'small' { $models += 'qwen2.5-coder-7b-instruct' }
                default {
                    $models += @(
                        'qwen2.5-coder-32b-instruct',
                        'qwen2.5-coder-7b-instruct'
                    )
                }
            }
            Ensure-LmStudioModels -Models $models
            return 'default'
        }
        'interactive' {
            Write-Host 'Launching interactive LM Studio model selection...'
            & lms get | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw 'LM Studio interactive model selection failed.'
            }
            return 'interactive'
        }
        default {
            return 'skipped'
        }
    }
}

$resolvedKitPath = (Resolve-Path $KitPath).Path
$codexHerePath = Join-Path $resolvedKitPath 'codex-here.ps1'
if (-not (Test-Path $codexHerePath -PathType Leaf)) {
    throw "Could not find codex-here.ps1 at $codexHerePath"
}

if ($DryRun) {
    Invoke-DryRunStep 'Would install Toolchain if missing.'
} else {
    & (Join-Path $resolvedKitPath 'bootstrap-toolchain.ps1') -InstallIfMissing
}

if ($DryRun) {
    Invoke-DryRunStep 'Would ensure Codex CLI is available through Toolchain codex:latest.'
} else {
    Write-Host 'Ensuring Codex CLI is available through Toolchain...'
    toolchain exec codex:latest {
        codex --version | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Toolchain failed to provision codex:latest.'
    }
}

if (-not (Test-LmStudioDesktopInstalled)) {
    Install-LmStudioDesktop
}

Ensure-LmStudioCli

$modelSetupResult = Invoke-LmStudioModelSetup -Mode $ModelSetup

$profileDir = Split-Path -Parent $ProfilePath
if ($profileDir -and -not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

if ((-not (Test-Path $ProfilePath)) -and (-not $DryRun)) {
    Set-Content -Path $ProfilePath -Value '' -Encoding ascii
}

$startMarker = '# local-codex-kit:start'
$endMarker = '# local-codex-kit:end'
$managedBlock = @"
$startMarker
function codex {
    & '$codexHerePath' -Preset $Preset @args
}
$endMarker
"@

$existingProfile = Get-Content $ProfilePath -Raw
$escapedStart = [regex]::Escape($startMarker)
$escapedEnd = [regex]::Escape($endMarker)
$managedPattern = "(?s)$escapedStart.*?$escapedEnd"

if ($existingProfile -match $managedPattern) {
    $updatedProfile = [regex]::Replace($existingProfile, $managedPattern, $managedBlock)
} else {
    $trimmedProfile = $existingProfile.TrimEnd()
    if ($trimmedProfile) {
        $updatedProfile = $trimmedProfile + "`r`n`r`n" + $managedBlock + "`r`n"
    } else {
        $updatedProfile = $managedBlock + "`r`n"
    }
}

if ($DryRun) {
    Invoke-DryRunStep "Would update PowerShell profile at $ProfilePath."
} else {
    Set-Content -Path $ProfilePath -Value $updatedProfile -Encoding ascii
}

Write-Host ''
Write-Host 'local-codex-kit installed into PowerShell profile:'
Write-Host ("- Kit path: {0}" -f $resolvedKitPath)
Write-Host ("- Default preset: {0}" -f $Preset)
Write-Host ("- Profile: {0}" -f $ProfilePath)
Write-Host '- Codex CLI: available through Toolchain codex:latest'
Write-Host '- Toolchain: installed or already present'
Write-Host '- LM Studio desktop: installed or already present'
Write-Host '- LM Studio CLI: available or bootstrapped'
Write-Host ("- LM Studio models: {0}" -f $modelSetupResult)
Write-Host ("- Dry run: {0}" -f $(if ($DryRun) { 'yes' } else { 'no' }))
Write-Host ''
Write-Host 'Next steps:'
Write-Host '- Run `. $PROFILE` in this shell, or open a new PowerShell window'
Write-Host '- Start Codex inside a Git repo with `codex`'
