param(
    [string]$KitPath = $PSScriptRoot,
    [string]$ProfilePath = $PROFILE,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Confirm-DeleteStep {
    param(
        [string]$Prompt
    )

    if ($Force) {
        return $true
    }

    $reply = Read-Host "$Prompt [Y/n]"
    return ($reply -eq '') -or ($reply -match '^(y|yes)$')
}

function Invoke-DryRunStep {
    param(
        [string]$Message
    )

    Write-Host ("[dry-run] {0}" -f $Message)
}

function Remove-ManagedProfileBlock {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $startMarker = '# local-codex-kit:start'
    $endMarker = '# local-codex-kit:end'
    $content = Get-Content $Path -Raw
    $pattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)

    if ($content -notmatch $pattern) {
        return $false
    }

    $updated = [regex]::Replace($content, $pattern, '').Trim()
    if ($updated) {
        if ($DryRun) {
            Invoke-DryRunStep "Would update PowerShell profile at $Path."
        } else {
            Set-Content -Path $Path -Value ($updated + "`r`n") -Encoding ascii
        }
    } else {
        if ($DryRun) {
            Invoke-DryRunStep "Would clear PowerShell profile at $Path."
        } else {
            Set-Content -Path $Path -Value '' -Encoding ascii
        }
    }
    return $true
}

function Remove-UserPathEntry {
    param(
        [string]$Entry
    )

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) {
        return $false
    }

    $parts = @($current -split ';' | Where-Object { $_ -and $_ -ne $Entry })
    $updated = ($parts -join ';')
    if ($updated -ne $current) {
        if ($DryRun) {
            Invoke-DryRunStep "Would remove user PATH entry $Entry."
            return $true
        }
        try {
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
            return $true
        } catch {
            Write-Warning $_.Exception.Message
            return $false
        }
    }

    return $false
}

function Remove-ToolchainPackages {
    if (-not (Get-Module -ListAvailable Toolchain)) {
        return $false
    }

    Import-Module Toolchain -Force
    try {
        if ($DryRun) {
            Invoke-DryRunStep 'Would remove Toolchain packages codex:latest, lmstudio:latest, and git:latest.'
            return $true
        }
        toolchain remove codex:latest lmstudio:latest git:latest | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        Write-Warning $_.Exception.Message
        return $false
    }
}

function Remove-ToolchainModule {
    $module = Get-Module -ListAvailable Toolchain | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        return $false
    }

    if (Test-Path $module.ModuleBase) {
        if ($DryRun) {
            Invoke-DryRunStep "Would remove Toolchain module at $($module.ModuleBase)."
            return $true
        }
        try {
            Remove-Item -Path $module.ModuleBase -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Warning $_.Exception.Message
            return $false
        }
    }

    return $false
}

function Remove-LmStudioModels {
    $lmStudioRoot = Join-Path $env:USERPROFILE '.lmstudio'
    $targets = @(
        (Join-Path $lmStudioRoot 'models\lmstudio-community\gpt-oss-20b-GGUF'),
        (Join-Path $lmStudioRoot 'models\lmstudio-community\Qwen2.5-Coder-32B-Instruct-GGUF'),
        (Join-Path $lmStudioRoot 'hub\models\openai\gpt-oss-20b'),
        (Join-Path $lmStudioRoot 'hub\models\qwen\qwen2.5-coder-32b')
    )

    $removedAny = $false
    foreach ($target in $targets) {
        if (Test-Path $target) {
            if ($DryRun) {
                Invoke-DryRunStep "Would remove LM Studio target $target."
            } else {
                Remove-Item -Path $target -Recurse -Force
            }
            $removedAny = $true
        }
    }
    return $removedAny
}

function Remove-LmStudioData {
    $lmStudioRoot = Join-Path $env:USERPROFILE '.lmstudio'
    if (Test-Path $lmStudioRoot) {
        if ($DryRun) {
            Invoke-DryRunStep "Would remove LM Studio data directory $lmStudioRoot."
        } else {
            Remove-Item -Path $lmStudioRoot -Recurse -Force
        }
        return $true
    }
    return $false
}

$resolvedKitPath = (Resolve-Path $KitPath).Path
$toolchainCheckout = Join-Path $resolvedKitPath 'Toolchain'
$lmStudioBin = Join-Path $env:USERPROFILE '.lmstudio\bin'

$results = @()

$profileRemoved = Remove-ManagedProfileBlock -Path $ProfilePath
$results += [pscustomobject]@{ Step = 'Profile block'; Removed = $profileRemoved }

if (Test-Path $toolchainCheckout) {
    if (Confirm-DeleteStep -Prompt "Remove local Toolchain checkout at $toolchainCheckout?") {
        if ($DryRun) {
            Invoke-DryRunStep "Would remove local Toolchain checkout at $toolchainCheckout."
        } else {
            Remove-Item -Path $toolchainCheckout -Recurse -Force
        }
        $results += [pscustomobject]@{ Step = 'Local Toolchain checkout'; Removed = $true }
    }
}

if (Confirm-DeleteStep -Prompt 'Remove Toolchain packages (codex, lmstudio, git) from Toolchain storage?') {
    $removed = Remove-ToolchainPackages
    $results += [pscustomobject]@{ Step = 'Toolchain packages'; Removed = $removed }
}

if (Confirm-DeleteStep -Prompt 'Remove the installed Toolchain PowerShell module?') {
    $removed = Remove-ToolchainModule
    $results += [pscustomobject]@{ Step = 'Toolchain module'; Removed = $removed }
}

$pathRemoved = Remove-UserPathEntry -Entry $lmStudioBin
$results += [pscustomobject]@{ Step = 'LM Studio PATH entry'; Removed = $pathRemoved }

if (Confirm-DeleteStep -Prompt 'Remove the default LM Studio models downloaded by local-codex-kit?') {
    $removed = Remove-LmStudioModels
    $results += [pscustomobject]@{ Step = 'LM Studio models'; Removed = $removed }
}

if (Confirm-DeleteStep -Prompt 'Remove the LM Studio user data directory (~/.lmstudio)?') {
    $removed = Remove-LmStudioData
    $results += [pscustomobject]@{ Step = 'LM Studio data'; Removed = $removed }
}

Write-Host ''
Write-Host 'local-codex-kit delete summary:'
foreach ($result in $results) {
    Write-Host ("- {0}: {1}" -f $result.Step, $(if ($result.Removed) { 'removed' } else { 'not changed' }))
}
Write-Host ("- Dry run: {0}" -f $(if ($DryRun) { 'yes' } else { 'no' }))
Write-Host ''
Write-Host 'Next steps:'
Write-Host '- Run `. $PROFILE` in this shell, or open a new PowerShell window'
