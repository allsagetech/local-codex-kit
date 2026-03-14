$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }
$env:LOCAL_CODEX_TRANSFORMERS_PORT = if ($env:LOCAL_CODEX_TRANSFORMERS_PORT) { $env:LOCAL_CODEX_TRANSFORMERS_PORT } else { '8000' }
$env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC = if ($env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC) { $env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC } else { '300' }
$env:LOCAL_CODEX_TRANSFORMERS_DTYPE = if ($env:LOCAL_CODEX_TRANSFORMERS_DTYPE) { $env:LOCAL_CODEX_TRANSFORMERS_DTYPE } else { 'auto' }
$env:LOCAL_CODEX_TRANSFORMERS_DEVICE = if ($env:LOCAL_CODEX_TRANSFORMERS_DEVICE) { $env:LOCAL_CODEX_TRANSFORMERS_DEVICE } else { 'auto' }
$env:LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK = if ($env:LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK) { $env:LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK } else { '0' }
$env:LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS = if ($env:LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS) { $env:LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS } else { '1024' }
$env:LOCAL_CODEX_TRANSFORMERS_OFFLOAD_DIR = if ($env:LOCAL_CODEX_TRANSFORMERS_OFFLOAD_DIR) { $env:LOCAL_CODEX_TRANSFORMERS_OFFLOAD_DIR } else { '/tmp/local-codex-kit/transformers-offload' }
$env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_ENABLE = if ($env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_ENABLE) { $env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_ENABLE } else { '1' }
$env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_TIMEOUT_SEC = if ($env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_TIMEOUT_SEC) { $env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_TIMEOUT_SEC } else { '45' }
$env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_MAX_OUTPUT_TOKENS = if ($env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_MAX_OUTPUT_TOKENS) { $env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_MAX_OUTPUT_TOKENS } else { '16' }
$env:PYTHONPATH = if ($env:PYTHONPATH) { '/opt/local-codex-kit/python-patches:' + $env:PYTHONPATH } else { '/opt/local-codex-kit/python-patches' }

$transformers = Get-Command transformers -ErrorAction SilentlyContinue
if (-not $transformers) {
    throw '`transformers` CLI is not installed in this image.'
}

function Get-TransformersRuntimeInfo {
    $runtimeJson = & python -c @'
import json

try:
    import torch
except Exception as exc:
    print(json.dumps({"torch_import_error": str(exc)}))
    raise SystemExit(0)

cuda_available = bool(getattr(torch.cuda, "is_available", lambda: False)())
cuda_device_count = int(getattr(torch.cuda, "device_count", lambda: 0)()) if cuda_available else 0
cuda_capability = None
if cuda_available and cuda_device_count > 0:
    try:
        major, minor = torch.cuda.get_device_capability(0)
        cuda_capability = f"{major}.{minor}"
    except Exception:
        cuda_capability = None

xpu_module = getattr(torch, "xpu", None)
xpu_available = False
if xpu_module is not None:
    try:
        xpu_available = bool(xpu_module.is_available())
    except Exception:
        xpu_available = False

print(json.dumps({
    "cuda_available": cuda_available,
    "cuda_device_count": cuda_device_count,
    "cuda_capability": cuda_capability,
    "xpu_available": xpu_available,
}))
'@

    if ([string]::IsNullOrWhiteSpace($runtimeJson)) {
        return [pscustomobject]@{
            cuda_available   = $false
            cuda_device_count = 0
            cuda_capability  = $null
            xpu_available    = $false
            torch_import_error = 'python runtime probe returned no output'
        }
    }

    return ($runtimeJson | ConvertFrom-Json)
}

function Assert-TransformersRuntimeSupported {
    param(
        [string]$ModelName
    )

    if ($env:LOCAL_CODEX_TRANSFORMERS_DEVICE -ne 'auto') {
        return
    }

    $runtimeInfo = Get-TransformersRuntimeInfo
    if ($runtimeInfo.torch_import_error) {
        throw ("Unable to inspect Torch runtime support: {0}" -f $runtimeInfo.torch_import_error)
    }

    if ($runtimeInfo.cuda_available -or $runtimeInfo.xpu_available) {
        return
    }

    if ($env:LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK -eq '1') {
        return
    }

    $message = (
        "No supported accelerator was detected for '{0}'. This image defaults to the official MXFP4 weights, and on CPU-only hosts `transformers serve` currently fails during auto offload. " +
        "Set LOCAL_CODEX_TRANSFORMERS_DEVICE=cpu and LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK=1 only if you intentionally want to try a large RAM-heavy CPU run."
    ) -f $ModelName
    throw $message
}

function Get-TransformersFailureHint {
    param(
        [string]$ErrLogPath,
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ErrLogPath) -or -not (Test-Path -LiteralPath $ErrLogPath)) {
        return ''
    }

    $recentLog = Get-Content -LiteralPath $ErrLogPath -Tail 120 -ErrorAction SilentlyContinue
    if ($recentLog -match 'CUDA out of memory|torch\.OutOfMemoryError') {
        return (
            "The first generation attempt for '{0}' hit a CUDA out-of-memory error. " +
            "This official transformers runtime currently does not fit on the available accelerator. " +
            "Use a larger GPU, switch to a smaller model, or opt into CPU fallback only if you accept much slower responses."
        ) -f $ModelName
    }

    return ''
}

function Invoke-TransformersSmokeTest {
    param(
        [string]$BaseUrl,
        [string]$ModelName,
        [int]$TimeoutSec,
        [int]$MaxOutputTokens
    )

    $payload = @{
        model             = $ModelName
        input             = 'Reply with exactly hello.'
        max_output_tokens = $MaxOutputTokens
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod `
            -Uri ($BaseUrl + '/v1/responses') `
            -Method Post `
            -ContentType 'application/json' `
            -Body $payload `
            -TimeoutSec $TimeoutSec
    } catch {
        $details = if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $_.ErrorDetails.Message
        } else {
            $_.Exception.Message
        }

        throw ("Transformers smoke test failed for '{0}': {1}" -f $ModelName, $details)
    }

    if ($null -eq $response) {
        throw ("Transformers smoke test returned no payload for '{0}'." -f $ModelName)
    }
}

$manifest = @(Read-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST)
if ($manifest.Count -eq 0) {
    throw ("No official models are available in manifest '{0}'. Rebuild the image with LOCAL_CODEX_OFFICIAL_PULL_MODELS set." -f $env:LOCAL_CODEX_MODEL_MANIFEST)
}

$selectedModel = if ($env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS) {
    $env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS
} elseif ($env:LOCAL_CODEX_CODEX_MODEL) {
    $env:LOCAL_CODEX_CODEX_MODEL
} else {
    $manifest[0].repo
}

$modelEntry = Resolve-InstalledModelEntry -Manifest $manifest -ModelName $selectedModel
if ($null -eq $modelEntry) {
    $availableModels = ($manifest | ForEach-Object { $_.repo }) -join ', '
    throw ("Configured official model '{0}' is not available. Installed models: {1}" -f $selectedModel, $availableModels)
}

Assert-TransformersRuntimeSupported -ModelName $modelEntry.repo

$resolvedModelPath = if (-not [string]::IsNullOrWhiteSpace($modelEntry.package_root)) {
    Resolve-ToolchainModelPath -PackageRoot $modelEntry.package_root -ModelName $modelEntry.repo
} else {
    Resolve-ToolchainModelPath -PackageRoot $modelEntry.model_path -ModelName $modelEntry.repo
}
if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
    $resolvedModelPath = $modelEntry.model_path
}

if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
    throw ("Installed model '{0}' does not define a local model path in manifest '{1}'." -f $modelEntry.repo, $env:LOCAL_CODEX_MODEL_MANIFEST)
}

if (-not (Test-Path -LiteralPath $resolvedModelPath)) {
    throw ("Installed model path does not exist: {0}" -f $resolvedModelPath)
}

$logDir = '/tmp/local-codex-kit'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$null = New-Item -ItemType Directory -Path $env:LOCAL_CODEX_TRANSFORMERS_OFFLOAD_DIR -Force
$outLog = Join-Path $logDir 'transformers.out.log'
$errLog = Join-Path $logDir 'transformers.err.log'

$argumentList = @(
    'serve',
    '--host', '127.0.0.1',
    '--port', $env:LOCAL_CODEX_TRANSFORMERS_PORT,
    '--device', $env:LOCAL_CODEX_TRANSFORMERS_DEVICE,
    '--force-model', $resolvedModelPath
)

if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TRANSFORMERS_DTYPE) -and ($env:LOCAL_CODEX_TRANSFORMERS_DTYPE -ne 'auto')) {
    $argumentList += @('--dtype', $env:LOCAL_CODEX_TRANSFORMERS_DTYPE)
}
if ($env:LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING -eq '1') {
    $argumentList += '--continuous-batching'
}
if ($env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION) {
    $argumentList += @('--attn-implementation', $env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION)
}

$proc = Start-Process -FilePath $transformers.Source -ArgumentList $argumentList -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$baseUrl = "http://127.0.0.1:$($env:LOCAL_CODEX_TRANSFORMERS_PORT)"
$deadline = (Get-Date).AddSeconds([int]$env:LOCAL_CODEX_TRANSFORMERS_STARTUP_TIMEOUT_SEC)

while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        $message = "transformers serve exited before becoming ready.`n`nstdout: $outLog`nstderr: $errLog"
        throw $message
    }

    try {
        $models = Invoke-RestMethod -Uri ($baseUrl + '/v1/models') -TimeoutSec 5
        if ($models) {
            if ($env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_ENABLE -ne '0') {
                try {
                    Invoke-TransformersSmokeTest `
                        -BaseUrl $baseUrl `
                        -ModelName $modelEntry.repo `
                        -TimeoutSec ([int]$env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_TIMEOUT_SEC) `
                        -MaxOutputTokens ([int]$env:LOCAL_CODEX_TRANSFORMERS_SMOKE_TEST_MAX_OUTPUT_TOKENS)
                } catch {
                    $hint = Get-TransformersFailureHint -ErrLogPath $errLog -ModelName $modelEntry.repo
                    $message = $_.Exception.Message
                    if (-not [string]::IsNullOrWhiteSpace($hint)) {
                        $message = $message + "`n`n" + $hint
                    }

                    throw $message
                }
            }

            return [pscustomobject]@{
                started       = $true
                processId     = $proc.Id
                baseUrl       = $baseUrl
                modelRepo     = $modelEntry.repo
                modelPath     = $resolvedModelPath
                stdoutLogPath = $outLog
                stderrLogPath = $errLog
            }
        }
    } catch {
        if ($_.Exception.Message -like 'Transformers smoke test*') {
            throw
        }

        if ($proc.HasExited) {
            throw
        }
    }

    Start-Sleep -Seconds 1
}

try {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
} catch {
}

throw ("Timed out waiting for transformers serve to become ready. stdout: {0} stderr: {1}" -f $outLog, $errLog)
