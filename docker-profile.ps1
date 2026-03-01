function Start-LocalCodexLmStudioBridge {
    $bridgeUrl = 'http://127.0.0.1:1234/v1/models'
    try {
        Invoke-WebRequest -UseBasicParsing $bridgeUrl -TimeoutSec 1 | Out-Null
        return
    } catch {
    }

    $bridgeScript = '/opt/local-codex-kit/docker-lmstudio-bridge.js'
    $bridgeOut = '/tmp/local-codex-lmstudio-bridge.out.log'
    $bridgeErr = '/tmp/local-codex-lmstudio-bridge.err.log'
    Start-Process node -ArgumentList $bridgeScript -RedirectStandardOutput $bridgeOut -RedirectStandardError $bridgeErr | Out-Null
    Start-Sleep -Seconds 1
}

function codex {
    Start-LocalCodexLmStudioBridge
    $env:LOCAL_CODEX_USE_HOST_LMSTUDIO = '1'
    & '/opt/local-codex-kit/codex-here.ps1' -Preset local -NoToolchain @args
}

function codex-qwen {
    Start-LocalCodexLmStudioBridge
    $env:LOCAL_CODEX_USE_HOST_LMSTUDIO = '1'
    & '/opt/local-codex-kit/codex-here.ps1' -Preset qwen -NoToolchain @args
}

function codex-small {
    Start-LocalCodexLmStudioBridge
    $env:LOCAL_CODEX_USE_HOST_LMSTUDIO = '1'
    & '/opt/local-codex-kit/codex-here.ps1' -Preset small -NoToolchain @args
}
