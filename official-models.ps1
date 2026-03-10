$ErrorActionPreference = 'Stop'

function Get-ModelList {
    param(
        [string]$RawModels
    )

    if ([string]::IsNullOrWhiteSpace($RawModels)) {
        return @()
    }

    return @(
        $RawModels.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { (-not [string]::IsNullOrWhiteSpace($_)) -and ($_ -ne 'none') }
    )
}

function Get-FirstConfiguredModel {
    param(
        [string]$RawModels
    )

    foreach ($entry in @(Get-ModelList -RawModels $RawModels)) {
        return $entry
    }

    return $null
}

function Convert-ToCanonicalModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return $resolvedModel
    }

    if ($resolvedModel -match '^gpt-oss:(.+)$') {
        return "openai/gpt-oss-$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss-(.+)$') {
        return "openai/gpt-oss-$($Matches[1])"
    }

    return $resolvedModel
}

function Convert-ToModelAlias {
    param(
        [string]$ModelName
    )

    $canonicalModel = Convert-ToCanonicalModelName -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($canonicalModel)) {
        return ''
    }

    if ($canonicalModel.Contains('/')) {
        return ($canonicalModel.Split('/')[-1]).Trim()
    }

    return $canonicalModel.Replace(':', '-')
}

function Resolve-OfficialModelPackageRef {
    param(
        [string]$ModelName
    )

    $canonicalModel = Convert-ToCanonicalModelName -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($canonicalModel)) {
        return ''
    }

    switch ($canonicalModel) {
        'openai/gpt-oss-20b' {
            if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B)) {
                return $env:LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B
            }

            return 'openai-gpt-oss-20b:1.0.0'
        }

        'openai/gpt-oss-120b' {
            if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B)) {
                return $env:LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B
            }

            throw "No Toolchain package is configured for '$canonicalModel'. Set LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_120B."
        }

        default {
            throw "No Toolchain package mapping is configured for '$canonicalModel'."
        }
    }
}

function Convert-ToHfCacheSlug {
    param(
        [string]$ModelName
    )

    $canonicalModel = Convert-ToCanonicalModelName -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($canonicalModel)) {
        return ''
    }

    return 'models--' + $canonicalModel.Replace('/', '--')
}

function Resolve-ToolchainContentPath {
    param(
        [string]$ToolchainPath,
        [string]$Digest
    )

    if ([string]::IsNullOrWhiteSpace($ToolchainPath) -or [string]::IsNullOrWhiteSpace($Digest)) {
        return ''
    }

    if (-not $Digest.StartsWith('sha256:')) {
        throw "Unsupported Toolchain digest '$Digest'."
    }

    $shortDigest = $Digest.Substring('sha256:'.Length)
    if ($shortDigest.Length -lt 12) {
        throw "Toolchain digest '$Digest' is shorter than expected."
    }

    return (Join-Path (Join-Path $ToolchainPath 'content') $shortDigest.Substring(0, 12))
}

function Resolve-ToolchainModelPath {
    param(
        [string]$PackageRoot,
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($PackageRoot) -or [string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $hfCacheRoot = Join-Path $PackageRoot 'cache/hf-cache'
    $cacheSlug = Convert-ToHfCacheSlug -ModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($cacheSlug)) {
        return $PackageRoot
    }

    $repoCacheRoot = Join-Path $hfCacheRoot $cacheSlug
    if (-not (Test-Path -LiteralPath $repoCacheRoot)) {
        return $PackageRoot
    }

    $refsMainPath = Join-Path (Join-Path $repoCacheRoot 'refs') 'main'
    if (Test-Path -LiteralPath $refsMainPath) {
        $snapshotId = (Get-Content -LiteralPath $refsMainPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($snapshotId)) {
            $snapshotPath = Join-Path (Join-Path $repoCacheRoot 'snapshots') $snapshotId
            if (Test-Path -LiteralPath $snapshotPath) {
                return $snapshotPath
            }
        }
    }

    $snapshotsRoot = Join-Path $repoCacheRoot 'snapshots'
    if (-not (Test-Path -LiteralPath $snapshotsRoot)) {
        return $PackageRoot
    }

    $snapshotDirectory = Get-ChildItem -LiteralPath $snapshotsRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($snapshotDirectory) {
        return $snapshotDirectory.FullName
    }

    return $PackageRoot
}

function Convert-ToTomlString {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-ModelManifestPath {
    param(
        [string]$ManifestPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        return $ManifestPath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_MODEL_MANIFEST)) {
        return $env:LOCAL_CODEX_MODEL_MANIFEST
    }

    return '/opt/local-codex-kit/official-models.manifest.json'
}

function Read-ModelManifest {
    param(
        [string]$ManifestPath
    )

    $resolvedManifestPath = Get-ModelManifestPath -ManifestPath $ManifestPath
    if (-not (Test-Path -LiteralPath $resolvedManifestPath)) {
        return @()
    }

    $rawManifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json
    if ($null -eq $rawManifest) {
        return @()
    }

    if ($rawManifest.PSObject.Properties.Name -contains 'models') {
        return @($rawManifest.models)
    }

    return @($rawManifest)
}

function Write-ModelManifest {
    param(
        [string]$ManifestPath,
        [object[]]$Entries
    )

    $resolvedManifestPath = Get-ModelManifestPath -ManifestPath $ManifestPath
    $manifestDirectory = Split-Path -Parent $resolvedManifestPath
    if (-not [string]::IsNullOrWhiteSpace($manifestDirectory) -and -not (Test-Path -LiteralPath $manifestDirectory)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }

    $payload = [pscustomobject]@{
        models = @($Entries)
    }

    Set-Content -LiteralPath $resolvedManifestPath -Value ($payload | ConvertTo-Json -Depth 8)
}

function Resolve-InstalledModelEntry {
    param(
        [object[]]$Manifest,
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $null
    }

    $desiredRepo = Convert-ToCanonicalModelName -ModelName $ModelName
    $desiredAlias = Convert-ToModelAlias -ModelName $ModelName

    foreach ($entry in @($Manifest)) {
        if (
            (($entry.repo) -and ($entry.repo -eq $desiredRepo)) -or
            (($entry.alias) -and ($entry.alias -eq $desiredAlias)) -or
            (($entry.source_model) -and ($entry.source_model -eq $ModelName))
        ) {
            return $entry
        }
    }

    return $null
}
