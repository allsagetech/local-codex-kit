param(
    [string]$ConfigPath = $(if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_CODEX_CONFIG_PATH)) { '/root/.codex/config.toml' } else { $env:LOCAL_CODEX_CODEX_CONFIG_PATH }),
    [string]$BaseUrl = $(if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OLLAMA_BASE_URL)) {
        $port = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_OLLAMA_PORT)) { '11434' } else { $env:LOCAL_CODEX_OLLAMA_PORT }
        "http://127.0.0.1:$port/v1"
    } else {
        $env:LOCAL_CODEX_OLLAMA_BASE_URL
    }),
    [string]$Model = $env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS
)

$ErrorActionPreference = 'Stop'

function Format-TomlString {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = 'gpt-oss:20b'
}

$configDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$content = @(
    'disable_response_storage = true'
    'show_reasoning_content = true'
    ''
    ('model = {0}' -f (Format-TomlString -Value $Model))
    'model_provider = "oss"'
    ''
    '[model_providers.oss]'
    'name = "Open Source"'
    ('base_url = {0}' -f (Format-TomlString -Value $BaseUrl))
    ''
    '[profiles.oss]'
    ('model = {0}' -f (Format-TomlString -Value $Model))
    'model_provider = "oss"'
) -join "`n"

Set-Content -LiteralPath $ConfigPath -Value $content -Encoding utf8NoBOM
$ConfigPath
