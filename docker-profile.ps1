function Initialize-PSReadLineHistory {
    if (-not (Get-Module -ListAvailable -Name PSReadLine)) {
        return
    }

    $historyRoot = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        Join-Path $env:HOME '.local/share/powershell/PSReadLine'
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
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_OLLAMA_MODEL_ALIAS)) {
        return $env:LOCAL_OLLAMA_MODEL_ALIAS
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

    return 'qwen2.5-coder:14b'
}

function Resolve-OllamaModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    return $ModelName.Trim()
}

function Ensure-OllamaModelInstalled {
    param(
        [string]$ModelName
    )

    $resolvedOllamaModel = Resolve-OllamaModelName -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($resolvedOllamaModel)) {
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

    return $installedModels.ContainsKey($resolvedOllamaModel)
}

function ollama-local {
    $model = Get-DefaultOllamaModel | Resolve-OllamaModelName

    if (
        -not [string]::IsNullOrWhiteSpace($model) -and
        -not (Ensure-OllamaModelInstalled -ModelName $model)
    ) {
        $modelStore = if ($env:LOCAL_OLLAMA_MODELS) { $env:LOCAL_OLLAMA_MODELS } else { '/opt/local-ollama-kit/ollama-models' }
        throw ("Configured Ollama model '{0}' is not installed. Check `ollama list`. This runtime reads models from '{1}', so rebuild the image with LOCAL_OLLAMA_PULL_MODELS updated if you need a different baked model set." -f $model, $modelStore)
    }

    & ollama run $model @args
}
