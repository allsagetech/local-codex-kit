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

    return 'qwen2.5-coder:7b'
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
                $resolvedArgs += (Convert-ToOllamaCompatibleModelName -ModelName ([string]$ArgumentList[$index]))
            }

            continue
        }

        if ($value.StartsWith('--model=')) {
            $resolvedArgs += ('--model=' + (Convert-ToOllamaCompatibleModelName -ModelName $value.Substring(8)))
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
                return (Convert-ToOllamaCompatibleModelName -ModelName ([string]$ArgumentList[$index + 1]))
            }

            return ''
        }

        if ($value.StartsWith('--model=')) {
            return (Convert-ToOllamaCompatibleModelName -ModelName $value.Substring(8))
        }
    }

    return ''
}

function Test-OllamaModelInstalled {
    param(
        [string]$ModelName
    )

    $resolvedModel = Convert-ToOllamaCompatibleModelName -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($resolvedModel)) {
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
        if ($installedModel -eq $resolvedModel) {
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
    $defaultModel = Convert-ToOllamaCompatibleModelName -ModelName $defaultModel
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
        -not (Test-OllamaModelInstalled -ModelName $effectiveModel)
    ) {
        throw ("Configured Ollama model '{0}' is not installed. Check `ollama list`. If this container is reusing an older `/root/.ollama` volume, remove the Docker volume that backs `/root/.ollama` (typically `local-codex-kit_local-codex-kit-ollama`) and start the container again." -f $effectiveModel)
    }

    & codex @resolvedArgs @argumentList
}

Set-Alias -Name codex-ollama -Value codex-local
