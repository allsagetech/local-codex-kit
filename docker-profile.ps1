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

Initialize-PSReadLineHistory

function Get-DefaultOllamaModel {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS)) {
        return $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS
    }

    try {
        $lines = @(& ollama list 2>$null)
        foreach ($line in @($lines | Select-Object -Skip 1)) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            return (($trimmed -split '\s+')[0]).Trim()
        }
    } catch {
    }

    return 'gpt-oss:20b'
}

function Convert-ToOllamaCompatibleModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    return $resolvedModel
}

function Convert-ToCodexCompatibleModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss-(.+)$') {
        return "gpt-oss:$($Matches[1])"
    }

    return $resolvedModel
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
                $resolvedArgs += (Convert-ToCodexCompatibleModelName -ModelName ([string]$ArgumentList[$index]))
            }

            continue
        }

        if ($value.StartsWith('--model=')) {
            $resolvedArgs += ('--model=' + (Convert-ToCodexCompatibleModelName -ModelName $value.Substring(8)))
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
                return (Convert-ToCodexCompatibleModelName -ModelName ([string]$ArgumentList[$index + 1]))
            }

            return ''
        }

        if ($value.StartsWith('--model=')) {
            return (Convert-ToCodexCompatibleModelName -ModelName $value.Substring(8))
        }
    }

    return ''
}

function Test-OllamaModelInstalled {
    param(
        [string]$ModelName
    )

    $resolvedOllamaModel = Convert-ToOllamaCompatibleModelName -ModelName $ModelName
    $resolvedCodexModel = Convert-ToCodexCompatibleModelName -ModelName $ModelName
    if (
        [string]::IsNullOrWhiteSpace($resolvedOllamaModel) -and
        [string]::IsNullOrWhiteSpace($resolvedCodexModel)
    ) {
        return $true
    }

    try {
        $lines = @(& ollama list 2>$null)
    } catch {
        return $true
    }

    foreach ($line in @($lines | Select-Object -Skip 1)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $installedModel = (($trimmed -split '\s+')[0]).Trim()
        if (
            (($resolvedOllamaModel) -and ($installedModel -eq $resolvedOllamaModel)) -or
            (($resolvedCodexModel) -and ($installedModel -eq $resolvedCodexModel))
        ) {
            return $true
        }
    }

    return $false
}

function Ensure-OllamaModelInstalled {
    param(
        [string]$ModelName
    )

    $resolvedOllamaModel = Convert-ToOllamaCompatibleModelName -ModelName $ModelName
    $resolvedCodexModel = Convert-ToCodexCompatibleModelName -ModelName $ModelName
    if (
        [string]::IsNullOrWhiteSpace($resolvedOllamaModel) -and
        [string]::IsNullOrWhiteSpace($resolvedCodexModel)
    ) {
        return $true
    }

    try {
        $lines = @(& ollama list 2>$null)
    } catch {
        return $true
    }

    $installedModels = @{}
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $installedModel = (($trimmed -split '\s+')[0]).Trim()
        $installedModels[$installedModel] = $true
    }

    if (
        (($resolvedOllamaModel) -and $installedModels.ContainsKey($resolvedOllamaModel)) -or
        (($resolvedCodexModel) -and $installedModels.ContainsKey($resolvedCodexModel))
    ) {
        return $true
    }

    if (
        ($resolvedOllamaModel) -and
        ($resolvedCodexModel) -and
        ($resolvedOllamaModel -ne $resolvedCodexModel) -and
        $installedModels.ContainsKey($resolvedOllamaModel)
    ) {
        Write-Host ("Creating Ollama alias for Codex metadata: {0} -> {1}" -f $resolvedCodexModel, $resolvedOllamaModel)
        & ollama cp $resolvedOllamaModel $resolvedCodexModel | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    return $false
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

function ollama-local {
    $model = Get-DefaultOllamaModel

    & ollama run $model @args
}

function codex-local {
    $argumentList = Normalize-CodexArgumentList -ArgumentList @($args)
    $defaultModel = if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL)) {
        $env:LOCAL_CODEX_CODEX_MODEL
    } else {
        Get-DefaultOllamaModel
    }
    $defaultModel = Convert-ToCodexCompatibleModelName -ModelName $defaultModel
    $selectedModel = Get-CodexModelArgument -ArgumentList $argumentList
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($selectedModel)) {
        $selectedModel
    } else {
        $defaultModel
    }

    $resolvedArgs = @()

    if (-not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--oss'))) {
        $resolvedArgs += '--oss'
    }
    if (-not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--local-provider'))) {
        $resolvedArgs += @('--local-provider', 'ollama')
    }
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

    if (
        -not [string]::IsNullOrWhiteSpace($effectiveModel) -and
        -not (Ensure-OllamaModelInstalled -ModelName $effectiveModel)
    ) {
        $modelStore = if ($env:LOCAL_CODEX_OLLAMA_MODELS) { $env:LOCAL_CODEX_OLLAMA_MODELS } else { '/opt/local-codex-kit/ollama-models' }
        throw ("Configured Ollama model '{0}' is not installed. Check `ollama list`. This runtime reads models from '{1}', so rebuild the image with LOCAL_CODEX_OLLAMA_PULL_MODELS updated if you need a different baked model set." -f $effectiveModel, $modelStore)
    }

    & codex @resolvedArgs @argumentList
}

Set-Alias -Name codex-ollama -Value codex-local
