. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

function Initialize-PSReadLineHistory {
    if (-not (Get-Module -ListAvailable -Name PSReadLine)) {
        return
    }

    $historyRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $env:CODEX_HOME '.local/share/powershell/PSReadLine'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        Join-Path $env:HOME '.codex/.local/share/powershell/PSReadLine'
    } else {
        $null
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($historyRoot)) {
            New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
            Set-PSReadLineOption -HistorySavePath (Join-Path $historyRoot 'ConsoleHost_history.txt')
            return
        }
    } catch {
    }

    try {
        Set-PSReadLineOption -HistorySaveStyle SaveNothing
    } catch {
    }
}

function Get-InstalledModelEntries {
    $manifestPath = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
    return @(Read-ModelManifest -ManifestPath $manifestPath)
}

function Get-DefaultModelRepo {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS)) {
        return (Convert-ToCanonicalModelName -ModelName $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS)
    }

    $manifest = @(Get-InstalledModelEntries)
    if ($manifest.Count -gt 0) {
        return $manifest[0].repo
    }

    return 'openai/gpt-oss-20b'
}

function Get-DefaultModelEntry {
    $manifest = @(Get-InstalledModelEntries)
    if ($manifest.Count -eq 0) {
        return $null
    }

    $desiredModel = if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS)) {
        $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL)) {
        $env:LOCAL_CODEX_CODEX_MODEL
    } else {
        $manifest[0].repo
    }

    $entry = Resolve-InstalledModelEntry -Manifest $manifest -ModelName $desiredModel
    if ($entry) {
        return $entry
    }

    return $manifest[0]
}

function Normalize-CodexArgumentList {
    param(
        [object[]]$ArgumentList
    )

    $resolvedArgs = @()

    for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
        $argument = $ArgumentList[$index]
        $value = if ($null -eq $argument) { '' } else { [string]$argument }

        if (($value -eq '--model') -or ($value -eq '-m')) {
            $resolvedArgs += $value
            if (($index + 1) -lt $ArgumentList.Count) {
                $index += 1
                $resolvedArgs += (Convert-ToCanonicalModelName -ModelName ([string]$ArgumentList[$index]))
            }

            continue
        }

        if ($value.StartsWith('--model=')) {
            $resolvedArgs += ('--model=' + (Convert-ToCanonicalModelName -ModelName $value.Substring(8)))
            continue
        }

        $resolvedArgs += $argument
    }

    return @($resolvedArgs)
}

function Get-CodexModelArgument {
    param(
        [object[]]$ArgumentList
    )

    for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
        $argument = $ArgumentList[$index]
        $value = if ($null -eq $argument) { '' } else { [string]$argument }

        if (($value -eq '--model') -or ($value -eq '-m')) {
            if (($index + 1) -lt $ArgumentList.Count) {
                return (Convert-ToCanonicalModelName -ModelName ([string]$ArgumentList[$index + 1]))
            }

            return ''
        }

        if ($value.StartsWith('--model=')) {
            return (Convert-ToCanonicalModelName -ModelName $value.Substring(8))
        }
    }

    return ''
}

function Test-HasCodexOption {
    param(
        [object[]]$ArgumentList,
        [string[]]$Names
    )

    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument) {
            continue
        }

        $value = [string]$argument
        foreach ($name in $Names) {
            if (($value -eq $name) -or $value.StartsWith("$name=")) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-ModelInstalled {
    param(
        [string]$ModelName
    )

    return ($null -ne (Resolve-InstalledModelEntry -Manifest @(Get-InstalledModelEntries) -ModelName $ModelName))
}

function transformers-local {
    $modelEntry = Get-DefaultModelEntry
    if ($null -eq $modelEntry) {
        throw 'No installed Toolchain-backed model path is available in the manifest.'
    }

    $modelPath = if (-not [string]::IsNullOrWhiteSpace($modelEntry.package_root)) {
        Resolve-ToolchainModelPath -PackageRoot $modelEntry.package_root -ModelName $modelEntry.repo
    } else {
        Resolve-ToolchainModelPath -PackageRoot $modelEntry.model_path -ModelName $modelEntry.repo
    }
    if ([string]::IsNullOrWhiteSpace($modelPath)) {
        $modelPath = $modelEntry.model_path
    }
    if ([string]::IsNullOrWhiteSpace($modelPath)) {
        throw 'No installed Toolchain-backed model path is available in the manifest.'
    }

    $port = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }

    & transformers chat ("localhost:$port") --model-name-or-path $modelPath @args
}

function codex-local {
    $argumentList = Normalize-CodexArgumentList -ArgumentList @($args)
    $defaultModel = if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL)) {
        Convert-ToCanonicalModelName -ModelName $env:LOCAL_CODEX_CODEX_MODEL
    } else {
        Get-DefaultModelRepo
    }
    $selectedModel = Get-CodexModelArgument -ArgumentList $argumentList
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($selectedModel)) {
        $selectedModel
    } else {
        $defaultModel
    }

    if (
        -not [string]::IsNullOrWhiteSpace($effectiveModel) -and
        -not (Ensure-ModelInstalled -ModelName $effectiveModel)
    ) {
        $manifestPath = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
        throw ("Configured official model '{0}' is not installed. Check '{1}' or rebuild the image with LOCAL_CODEX_OFFICIAL_PULL_MODELS updated." -f $effectiveModel, $manifestPath)
    }

    $resolvedArgs = @(
        '-c', 'model_provider="oss"',
        '-c', ('model_providers.oss.base_url=' + (Convert-ToTomlString -Value $env:CODEX_OSS_BASE_URL)),
        '-c', 'model_providers.oss.name="Official gpt-oss (Transformers)"'
    )

    if (-not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--sandbox'))) {
        $resolvedArgs += @('--sandbox', $env:LOCAL_CODEX_CODEX_SANDBOX_MODE)
    }
    if (-not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--ask-for-approval', '-a'))) {
        $resolvedArgs += @('--ask-for-approval', $env:LOCAL_CODEX_CODEX_APPROVAL_POLICY)
    }
    if (
        -not [string]::IsNullOrWhiteSpace($defaultModel) -and
        -not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--model', '-m'))
    ) {
        $resolvedArgs += @('--model', $defaultModel)
    }

    & codex @resolvedArgs @argumentList
}

Initialize-PSReadLineHistory
Set-Alias -Name codex-official -Value codex-local
