param(
    [ValidateSet("local-balanced", "local-coder", "local-small", "local-llvm", "auto")]
    [string]$Mode = "local-balanced",
    [string]$ExtraPrompt = "",
    [switch]$NoPreamble,
    [switch]$SkipRepoCheck,
    [string]$WorkingDirectory = (Get-Location).Path,
    [switch]$UseToolchain
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex-backend.ps1')

function Repair-ToolchainLinuxExecutableBits {
    if (-not $IsLinux) {
        return
    }

    $toolchainPath = if ([string]::IsNullOrWhiteSpace($env:ToolchainPath)) {
        '/opt/toolchain-cache'
    } else {
        $env:ToolchainPath
    }

    $contentRoot = Join-Path $toolchainPath 'content'
    if (-not (Test-Path -LiteralPath $contentRoot)) {
        return
    }

    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        return
    }

    # Toolchain extraction currently drops executable bits for Linux package files.
    # Restore executable mode for common tool entrypoints before invoking toolchain exec.
    $escapedContentRoot = $contentRoot.Replace("'", "'\''")
    $chmodScript = "set -e; root='$escapedContentRoot'; if [ -d `"${root}`" ]; then find `"${root}`" -type f \( -path '*/bin/*' -o -path '*/vendor/*/codex/codex' \) -exec chmod a+rx {} +; fi"
    & $bash.Source -lc $chmodScript
}

function Resolve-OptionalToolchainPackage {
    param(
        [string]$EnvVarName,
        [string]$DefaultPackage
    )

    $raw = [System.Environment]::GetEnvironmentVariable($EnvVarName, 'Process')
    if ($null -ne $raw) {
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'none') {
            return $null
        }

        return $raw
    }

    if ([string]::IsNullOrWhiteSpace($DefaultPackage)) {
        return $null
    }

    return $DefaultPackage
}

function Test-OptionalToolchainToggle {
    param(
        [string]$EnvVarName,
        [bool]$DefaultEnabled
    )

    $raw = [System.Environment]::GetEnvironmentVariable($EnvVarName, 'Process')
    if ($null -eq $raw) {
        return $DefaultEnabled
    }

    return $raw -ne '0'
}

function Test-OpenAiEndpointReachable {
    param(
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return $false
    }

    $modelsUrl = $BaseUrl.TrimEnd('/') + '/models'
    try {
        $null = Invoke-RestMethod -Method Get -Uri $modelsUrl -TimeoutSec 2
        return $true
    } catch {
        # A non-success status still confirms the endpoint is reachable.
        if ($_.Exception.Response -ne $null) {
            return $true
        }
        return $false
    }
}

$spec = Get-CodexLaunchSpec -ScriptRoot $PSScriptRoot -Mode $Mode -ExtraPrompt $ExtraPrompt -NoPreamble:$NoPreamble -WorkingDirectory $WorkingDirectory -UseToolchain:$UseToolchain -SkipRepoCheck:$SkipRepoCheck

if (($env:LOCAL_CODEX_CONTAINER_MODE -eq '1') -and ($spec.resolvedMode -in @('local-balanced', 'local-coder', 'local-small'))) {
    throw 'LM Studio presets are not included in the Docker image. Use codex, codex-llvm, or codex-vllm.'
}

Write-Host ''
Write-Host 'Codex launcher:'
Write-Host ("- Mode: {0}" -f $spec.resolvedMode)
Write-Host ("- Provider: {0}" -f $spec.provider)
Write-Host ("- Selected model: {0}" -f $spec.displayModel)
Write-Host ("- Codex model slug: {0}" -f $spec.model)
Write-Host '- Codex sandbox: workspace-write'
if ($spec.localModelKey) {
    Write-Host ("- LM Studio model: {0}" -f $spec.localModelKey)
    Write-Host ("- LM Studio identifier: {0}" -f $spec.localIdentifier)
}
if ($spec.provider -eq 'llvm') {
    Write-Host ("- LLVM endpoint: {0}" -f $spec.localBaseUrl)
    Write-Host ("- LLVM API key env: {0}" -f $spec.localApiKeyEnv)
    Write-Host ("- LLVM wire API: {0}" -f $spec.localWireApi)
}
if ($spec.metadataNote) {
    Write-Host ("- Codex CLI metadata: {0}" -f $spec.metadataNote)
}
Write-Host ("- Working directory: {0}" -f $spec.workingDirectory)
Write-Host ("- Toolchain: {0}" -f $(if ($UseToolchain) { 'enabled' } else { 'disabled' }))
if ($UseToolchain) {
    $useLlvmToolchain = Test-OptionalToolchainToggle -EnvVarName 'LOCAL_CODEX_USE_LLVM_TOOLCHAIN' -DefaultEnabled:(-not $IsLinux)
    if ($useLlvmToolchain) {
        $defaultLlvmPkgForHost = if ($IsLinux) { $null } else { 'llvm:latest' }
        $llvmPackage = Resolve-OptionalToolchainPackage -EnvVarName 'LOCAL_CODEX_TOOLCHAIN_LLVM_PKG' -DefaultPackage $defaultLlvmPkgForHost
        if ($llvmPackage) {
            Write-Host ("- Toolchain LLVM package: {0}" -f $llvmPackage)
        } elseif ($IsLinux) {
            Write-Host '- Toolchain LLVM package: disabled (using system clang)'
        }
    }
}
Write-Host ''

if ($spec.provider -eq 'llvm' -and -not (Test-OpenAiEndpointReachable -BaseUrl $spec.localBaseUrl)) {
    if ($env:LOCAL_CODEX_CONTAINER_MODE -eq '1') {
        throw ("LLVM endpoint is not reachable at {0}. Build the image with a GGUF model, place one under /opt/models inside Docker, or point LOCAL_CODEX_LLVM_BASE_URL at another in-container OpenAI-compatible endpoint." -f $spec.localBaseUrl)
    }

    throw ("LLVM endpoint is not reachable at {0}. Start your local LLVM/vLLM-compatible server, set LOCAL_CODEX_LLVM_BASE_URL, or run codex with -Preset local." -f $spec.localBaseUrl)
}

if (($spec.resolvedMode -in @('local-balanced', 'local-coder', 'local-small')) -and ($env:LOCAL_CODEX_USE_HOST_LMSTUDIO -ne '1')) {
    Ensure-LocalModel -ModelKey $spec.localModelKey -Identifier $spec.localIdentifier -ContextLength $spec.contextLength
}

if ($SkipRepoCheck -and -not $spec.isGitRepo) {
    Write-Warning 'Interactive codex does not support --skip-git-repo-check. Start it from a repo directory for full repo-aware behavior.'
}

if ($UseToolchain) {
    & (Join-Path $PSScriptRoot 'bootstrap-toolchain.ps1') -InstallIfMissing
    Push-Location $PSScriptRoot
    try {
        $argLiteral = (($spec.args | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ')
        if ($spec.codexPath) {
            $codexPath = $spec.codexPath.Replace("'", "''")
            $scriptText = "`$codexArgs = @($argLiteral)`n& '$codexPath' @codexArgs"
        } else {
            $scriptText = "`$codexArgs = @($argLiteral)`n`$codexCmd = Get-Command 'codex.cmd' -ErrorAction SilentlyContinue`nif (`$codexCmd -and `$codexCmd.Source) { & `$codexCmd.Source @codexArgs } else { codex @codexArgs }"
        }
        $scriptBlock = [scriptblock]::Create($scriptText)

        $defaultCodexPkg = if ($IsLinux) { 'codex:codex-0.106.0-linux' } else { 'codex:latest' }
        $defaultGitPkg = if ($IsLinux) { $null } else { 'git:latest' }
        $defaultLlvmPkg = if ($IsLinux) { $null } else { 'llvm:latest' }

        $codexPackage = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_CODEX_PKG)) { $defaultCodexPkg } else { $env:LOCAL_CODEX_TOOLCHAIN_CODEX_PKG }
        $gitPackage = Resolve-OptionalToolchainPackage -EnvVarName 'LOCAL_CODEX_TOOLCHAIN_GIT_PKG' -DefaultPackage $defaultGitPkg
        $useLlvmToolchain = Test-OptionalToolchainToggle -EnvVarName 'LOCAL_CODEX_USE_LLVM_TOOLCHAIN' -DefaultEnabled:(-not $IsLinux)
        $llvmPackage = Resolve-OptionalToolchainPackage -EnvVarName 'LOCAL_CODEX_TOOLCHAIN_LLVM_PKG' -DefaultPackage $defaultLlvmPkg
        $toolchainPackages = @($codexPackage)
        if ($gitPackage) {
            $toolchainPackages += $gitPackage
        }
        if ($useLlvmToolchain -and $llvmPackage) {
            $toolchainPackages += $llvmPackage
        }

        $pullPolicy = if ([string]::IsNullOrWhiteSpace($env:ToolchainPullPolicy)) { 'IfNotPresent' } else { $env:ToolchainPullPolicy }
        if ($pullPolicy -eq 'Always') {
            toolchain pull @toolchainPackages | Out-Host
        }
        Repair-ToolchainLinuxExecutableBits
        toolchain exec @toolchainPackages $scriptBlock
    } finally {
        Pop-Location
    }
} else {
    & $spec.codexPath @($spec.args)
}
