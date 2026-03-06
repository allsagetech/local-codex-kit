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
    $argumentList = @($args)
    $model = if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL)) {
        $env:LOCAL_CODEX_CODEX_MODEL
    } else {
        Get-DefaultOllamaModel
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
        -not [string]::IsNullOrWhiteSpace($model) -and
        -not (Test-HasCodexOption -ArgumentList $argumentList -Names @('--model', '-m'))
    ) {
        $resolvedArgs += @('--model', $model)
    }

    & codex @resolvedArgs @argumentList
}

Set-Alias -Name codex-ollama -Value codex-local
