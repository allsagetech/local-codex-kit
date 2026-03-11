function Get-OfficialModelHelpersPath {
    $candidatePaths = @()

    if ($PSCommandPath) {
        $candidatePaths += (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_KIT_ROOT)) {
        $candidatePaths += (Join-Path $env:LOCAL_CODEX_KIT_ROOT 'official-models.ps1')
    }
    $candidatePaths += '/opt/local-codex-kit/official-models.ps1'

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
            return $candidatePath
        }
    }

    throw ("Unable to locate official-models.ps1. Checked: {0}" -f ($candidatePaths -join ', '))
}

. (Get-OfficialModelHelpersPath)

$env:LOCAL_CODEX_CODEX_PROVIDER = if ($env:LOCAL_CODEX_CODEX_PROVIDER) { $env:LOCAL_CODEX_CODEX_PROVIDER } else { 'transformers' }
$env:LOCAL_CODEX_TRANSFORMERS_API_KEY = if ($env:LOCAL_CODEX_TRANSFORMERS_API_KEY) { $env:LOCAL_CODEX_TRANSFORMERS_API_KEY } else { 'local-codex' }

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

function Test-LocalCodexRuntimeReady {
    if ([string]::IsNullOrWhiteSpace($env:CODEX_OSS_BASE_URL)) {
        return $false
    }

    try {
        $null = Invoke-RestMethod -Uri ($env:CODEX_OSS_BASE_URL.TrimEnd('/') + '/models') -TimeoutSec 3
        return $true
    } catch {
        return $false
    }
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
    if ($env:LOCAL_CODEX_TRANSFORMERS_ENABLE -eq '0') {
        throw 'Embedded Transformers runtime is unavailable in this container. Review the startup warning above before running codex-local.'
    }

    if (-not (Test-LocalCodexRuntimeReady)) {
        throw ("Embedded Transformers runtime is not responding at '{0}'. Start or fix the local runtime before running codex-local." -f $env:CODEX_OSS_BASE_URL)
    }

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
        '-c', ('model_provider=' + (Convert-ToTomlString -Value $env:LOCAL_CODEX_CODEX_PROVIDER)),
        '-c', ('model_providers.' + $env:LOCAL_CODEX_CODEX_PROVIDER + '.base_url=' + (Convert-ToTomlString -Value $env:CODEX_OSS_BASE_URL)),
        '-c', ('model_providers.' + $env:LOCAL_CODEX_CODEX_PROVIDER + '.name=' + (Convert-ToTomlString -Value 'Official gpt-oss (Transformers)')),
        '-c', ('model_providers.' + $env:LOCAL_CODEX_CODEX_PROVIDER + '.wire_api=' + (Convert-ToTomlString -Value 'responses')),
        '-c', ('model_providers.' + $env:LOCAL_CODEX_CODEX_PROVIDER + '.env_key=' + (Convert-ToTomlString -Value 'LOCAL_CODEX_TRANSFORMERS_API_KEY'))
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
