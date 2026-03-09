. (Join-Path (Split-Path -Parent $PSCommandPath) 'llama-models.ps1')

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

function Get-LlamaManifestEntries {
    $modelRoot = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }
    return @(Read-LlamaManifest -ModelRoot $modelRoot)
}

function Get-DefaultLlamaModelAlias {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS)) {
        return (Convert-ToCodexModelName -ModelName $env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS)
    }

    $manifest = @(Get-LlamaManifestEntries)
    if ($manifest.Count -gt 0) {
        return $manifest[0].alias
    }

    return 'gpt-oss-20b'
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
                $resolvedArgs += (Convert-ToCodexModelName -ModelName ([string]$ArgumentList[$index]))
            }

            continue
        }

        if ($value.StartsWith('--model=')) {
            $resolvedArgs += ('--model=' + (Convert-ToCodexModelName -ModelName $value.Substring(8)))
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
                return (Convert-ToCodexModelName -ModelName ([string]$ArgumentList[$index + 1]))
            }

            return ''
        }

        if ($value.StartsWith('--model=')) {
            return (Convert-ToCodexModelName -ModelName $value.Substring(8))
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

function Get-LlamaModelEntryOrNull {
    param(
        [string]$ModelName
    )

    return (Resolve-LlamaModelEntry -Manifest @(Get-LlamaManifestEntries) -ModelName $ModelName)
}

function Ensure-LlamaModelInstalled {
    param(
        [string]$ModelName
    )

    return ($null -ne (Get-LlamaModelEntryOrNull -ModelName $ModelName))
}

function llama-local {
    $modelAlias = Get-DefaultLlamaModelAlias
    $modelEntry = Get-LlamaModelEntryOrNull -ModelName $modelAlias

    if ($null -eq $modelEntry) {
        $modelStore = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }
        throw ("Configured llama.cpp model '{0}' is not installed. Check '{1}/manifest.json' or rebuild the image with LOCAL_CODEX_LLAMACPP_PULL_MODELS updated." -f $modelAlias, $modelStore)
    }

    & llama-cli -m $modelEntry.model_file --jinja @args
}

function codex-local {
    $argumentList = Normalize-CodexArgumentList -ArgumentList @($args)
    $defaultModel = if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL)) {
        Convert-ToCodexModelName -ModelName $env:LOCAL_CODEX_CODEX_MODEL
    } else {
        Get-DefaultLlamaModelAlias
    }
    $selectedModel = Get-CodexModelArgument -ArgumentList $argumentList
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($selectedModel)) {
        $selectedModel
    } else {
        $defaultModel
    }

    if (
        -not [string]::IsNullOrWhiteSpace($effectiveModel) -and
        -not (Ensure-LlamaModelInstalled -ModelName $effectiveModel)
    ) {
        $modelStore = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }
        throw ("Configured llama.cpp model '{0}' is not installed. Check '{1}/manifest.json' or rebuild the image with LOCAL_CODEX_LLAMACPP_PULL_MODELS updated." -f $effectiveModel, $modelStore)
    }

    $resolvedArgs = @(
        '-c', 'model_provider="oss"',
        '-c', ('model_providers.oss.base_url=' + (Convert-ToTomlString -Value $env:CODEX_OSS_BASE_URL)),
        '-c', 'model_providers.oss.name="Local llama.cpp"'
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
Set-Alias -Name codex-llama -Value codex-local
