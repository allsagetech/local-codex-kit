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

function Convert-ToCodexModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return 'gpt-oss-20b'
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss:(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    return $resolvedModel
}

function Get-DefaultCodexModel {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_MODEL_ALIAS)) {
        return $env:LOCAL_CODEX_CODEX_MODEL_ALIAS
    }

    return Convert-ToCodexModelName -ModelName (Get-DefaultOllamaModel)
}

function ollama-local {
    $model = Get-DefaultOllamaModel

    & ollama run $model @args
}

function codex-local {
    $model = Get-DefaultCodexModel

    & codex --profile oss --model $model --dangerously-bypass-approvals-and-sandbox @args
}
