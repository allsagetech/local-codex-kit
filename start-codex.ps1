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

$spec = Get-CodexLaunchSpec -ScriptRoot $PSScriptRoot -Mode $Mode -ExtraPrompt $ExtraPrompt -NoPreamble:$NoPreamble -WorkingDirectory $WorkingDirectory -UseToolchain:$UseToolchain -SkipRepoCheck:$SkipRepoCheck

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
    $useLlvmToolchain = $env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN -ne '0'
    if ($useLlvmToolchain) {
        $llvmPackage = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_LLVM_PKG)) { 'llvm:latest' } else { $env:LOCAL_CODEX_TOOLCHAIN_LLVM_PKG }
        Write-Host ("- Toolchain LLVM package: {0}" -f $llvmPackage)
    }
}
Write-Host ''

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
            $scriptText = "`$codexArgs = @($argLiteral)`ncodex @codexArgs"
        }
        $scriptBlock = [scriptblock]::Create($scriptText)

        $codexPackage = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_CODEX_PKG)) { 'codex:latest' } else { $env:LOCAL_CODEX_TOOLCHAIN_CODEX_PKG }
        $gitPackage = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_GIT_PKG)) { 'git:latest' } else { $env:LOCAL_CODEX_TOOLCHAIN_GIT_PKG }
        $useLlvmToolchain = $env:LOCAL_CODEX_USE_LLVM_TOOLCHAIN -ne '0'
        $llvmPackage = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_LLVM_PKG)) { 'llvm:latest' } else { $env:LOCAL_CODEX_TOOLCHAIN_LLVM_PKG }
        $toolchainPackages = @($codexPackage, $gitPackage)
        if ($useLlvmToolchain) {
            $toolchainPackages += $llvmPackage
        }

        toolchain exec @toolchainPackages $scriptBlock
    } finally {
        Pop-Location
    }
} else {
    & $spec.codexPath @($spec.args)
}
