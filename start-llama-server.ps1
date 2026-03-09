$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'llama-models.ps1')

$env:LOCAL_CODEX_LLAMACPP_MODELS = if ($env:LOCAL_CODEX_LLAMACPP_MODELS) { $env:LOCAL_CODEX_LLAMACPP_MODELS } else { '/opt/local-codex-kit/llama-models' }
$env:LOCAL_CODEX_LLAMACPP_PORT = if ($env:LOCAL_CODEX_LLAMACPP_PORT) { $env:LOCAL_CODEX_LLAMACPP_PORT } else { '8080' }
$env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH = if ($env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH) { $env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH } else { '65536' }
$env:LOCAL_CODEX_LLAMACPP_BATCH_SIZE = if ($env:LOCAL_CODEX_LLAMACPP_BATCH_SIZE) { $env:LOCAL_CODEX_LLAMACPP_BATCH_SIZE } else { '512' }
$env:LOCAL_CODEX_LLAMACPP_UBATCH_SIZE = if ($env:LOCAL_CODEX_LLAMACPP_UBATCH_SIZE) { $env:LOCAL_CODEX_LLAMACPP_UBATCH_SIZE } else { '512' }
$env:LOCAL_CODEX_LLAMACPP_STARTUP_TIMEOUT_SEC = if ($env:LOCAL_CODEX_LLAMACPP_STARTUP_TIMEOUT_SEC) { $env:LOCAL_CODEX_LLAMACPP_STARTUP_TIMEOUT_SEC } else { '300' }

$llamaServer = Get-Command llama-server -ErrorAction SilentlyContinue
if (-not $llamaServer) {
    throw 'llama-server is not installed in this image.'
}

$manifest = @(Read-LlamaManifest -ModelRoot $env:LOCAL_CODEX_LLAMACPP_MODELS)
if ($manifest.Count -eq 0) {
    throw ("No llama.cpp models are available in '{0}'. Rebuild the image with LOCAL_CODEX_LLAMACPP_PULL_MODELS set." -f $env:LOCAL_CODEX_LLAMACPP_MODELS)
}

$selectedModel = if ($env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS) {
    $env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS
} elseif ($env:LOCAL_CODEX_CODEX_MODEL) {
    $env:LOCAL_CODEX_CODEX_MODEL
} else {
    $manifest[0].alias
}

$modelEntry = Resolve-LlamaModelEntry -Manifest $manifest -ModelName $selectedModel
if ($null -eq $modelEntry) {
    $availableModels = ($manifest | ForEach-Object { $_.alias }) -join ', '
    throw ("Configured llama.cpp model '{0}' is not available. Installed models: {1}" -f $selectedModel, $availableModels)
}

$modelFile = $modelEntry.model_file
if (-not (Test-Path -LiteralPath $modelFile)) {
    throw ("Configured model file not found: {0}" -f $modelFile)
}

$logDir = '/tmp/local-codex-kit'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$outLog = Join-Path $logDir 'llama.out.log'
$errLog = Join-Path $logDir 'llama.err.log'

$argumentList = @(
    '--host', '127.0.0.1',
    '--port', $env:LOCAL_CODEX_LLAMACPP_PORT,
    '-m', $modelFile,
    '--alias', $modelEntry.alias,
    '-c', $env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH,
    '-b', $env:LOCAL_CODEX_LLAMACPP_BATCH_SIZE,
    '-ub', $env:LOCAL_CODEX_LLAMACPP_UBATCH_SIZE,
    '--jinja'
)

if ($env:LOCAL_CODEX_LLAMACPP_THREADS) {
    $argumentList += @('-t', $env:LOCAL_CODEX_LLAMACPP_THREADS)
}

if ($env:LOCAL_CODEX_LLAMACPP_GPU_LAYERS) {
    $argumentList += @('-ngl', $env:LOCAL_CODEX_LLAMACPP_GPU_LAYERS)
}

$proc = Start-Process -FilePath $llamaServer.Source -ArgumentList $argumentList -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$baseUrl = "http://127.0.0.1:$($env:LOCAL_CODEX_LLAMACPP_PORT)"
$deadline = (Get-Date).AddSeconds([int]$env:LOCAL_CODEX_LLAMACPP_STARTUP_TIMEOUT_SEC)

while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        $message = "llama-server exited before becoming ready.`n`nstdout: $outLog`nstderr: $errLog"
        throw $message
    }

    try {
        $health = Invoke-RestMethod -Uri ($baseUrl + '/health') -TimeoutSec 5
        $models = Invoke-RestMethod -Uri ($baseUrl + '/v1/models') -TimeoutSec 5
        if ($health -and $models) {
            return [pscustomobject]@{
                started        = $true
                processId      = $proc.Id
                llamaBaseUrl   = $baseUrl
                modelAlias     = $modelEntry.alias
                modelFile      = $modelFile
                stdoutLogPath  = $outLog
                stderrLogPath  = $errLog
            }
        }
    } catch {
    }

    Start-Sleep -Seconds 1
}

try {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
} catch {
}

throw ("Timed out waiting for llama-server to become ready. stdout: {0} stderr: {1}" -f $outLog, $errLog)
