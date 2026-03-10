param(
    [string]$Models
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'official-models.ps1')

$env:LOCAL_CODEX_TOOLCHAIN_PATH = if ($env:LOCAL_CODEX_TOOLCHAIN_PATH) { $env:LOCAL_CODEX_TOOLCHAIN_PATH } else { '/opt/local-codex-kit/toolchain-store' }
$env:LOCAL_CODEX_MODEL_MANIFEST = if ($env:LOCAL_CODEX_MODEL_MANIFEST) { $env:LOCAL_CODEX_MODEL_MANIFEST } else { '/opt/local-codex-kit/official-models.manifest.json' }

if (-not (Test-Path -LiteralPath $env:LOCAL_CODEX_TOOLCHAIN_PATH)) {
    New-Item -ItemType Directory -Path $env:LOCAL_CODEX_TOOLCHAIN_PATH -Force | Out-Null
}

$toolchainModuleInfo = Get-Module -ListAvailable -Name Toolchain | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $toolchainModuleInfo) {
    throw 'The `Toolchain` PowerShell module is not installed in this image.'
}

$toolchainModule = Import-Module $toolchainModuleInfo.Path -Force -PassThru
if ($null -eq $toolchainModule) {
    throw "Unable to import Toolchain module from '$($toolchainModuleInfo.Path)'."
}

function Invoke-ToolchainModule {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    return & $toolchainModule $ScriptBlock @ArgumentList
}

$env:ToolchainPath = $env:LOCAL_CODEX_TOOLCHAIN_PATH

$requestedModels = @(Get-ModelList -RawModels $Models)
if ($requestedModels.Count -eq 0) {
    Write-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST -Entries @()
    Write-Host 'Skipping official model pull because no build-time models were requested.'
    exit 0
}

$manifestEntries = @()
$seenRepos = @{}

foreach ($requestedModel in $requestedModels) {
    $repoId = Convert-ToCanonicalModelName -ModelName $requestedModel
    $alias = Convert-ToModelAlias -ModelName $requestedModel
    $packageRef = Resolve-OfficialModelPackageRef -ModelName $requestedModel

    if ([string]::IsNullOrWhiteSpace($repoId) -or [string]::IsNullOrWhiteSpace($alias)) {
        throw "Unable to resolve official model metadata for '$requestedModel'."
    }

    if ($seenRepos.ContainsKey($repoId)) {
        continue
    }

    Write-Host ("Pulling official Toolchain package '{0}' for model '{1}'..." -f $packageRef, $repoId)

    Invoke-ToolchainModule -ScriptBlock {
        param($PackageRef)
        Invoke-PullPackageWithRetry -PackageRef $PackageRef | Out-Null
    } -ArgumentList @($packageRef)

    $digest = Invoke-ToolchainModule -ScriptBlock {
        param($PackageRef)
        $resolvedPackage = $PackageRef | AsPackage
        return ($resolvedPackage | ResolvePackageDigest)
    } -ArgumentList @($packageRef)
    if ([string]::IsNullOrWhiteSpace($digest)) {
        throw ("Unable to resolve Toolchain digest for package '{0}'." -f $packageRef)
    }

    $packageRoot = Resolve-ToolchainContentPath -ToolchainPath $env:LOCAL_CODEX_TOOLCHAIN_PATH -Digest $digest
    if (-not (Test-Path -LiteralPath $packageRoot)) {
        throw ("Pulled Toolchain package content not found at '{0}'." -f $packageRoot)
    }

    $modelPath = Resolve-ToolchainModelPath -PackageRoot $packageRoot -ModelName $repoId
    if (-not (Test-Path -LiteralPath $modelPath)) {
        throw ("Resolved local model path not found at '{0}'." -f $modelPath)
    }

    $manifestEntries += [pscustomobject]@{
        alias        = $alias
        repo         = $repoId
        source_model = $requestedModel
        package_ref  = $packageRef
        digest       = $digest
        package_root = $packageRoot
        model_path   = $modelPath
    }
    $seenRepos[$repoId] = $true
}

Write-ModelManifest -ManifestPath $env:LOCAL_CODEX_MODEL_MANIFEST -Entries $manifestEntries
Write-Host ("Prepared {0} official model(s) from Toolchain store '{1}'." -f $manifestEntries.Count, $env:LOCAL_CODEX_TOOLCHAIN_PATH)
