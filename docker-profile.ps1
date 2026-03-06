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

    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS)) {
        return $env:LOCAL_CODEX_EMBEDDED_MODEL_ALIAS
    }

    return 'qwen3-coder'
}

function ollama-local {
    $model = Get-DefaultOllamaModel

    & ollama run $model @args
}
