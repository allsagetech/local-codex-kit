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

function Get-FirstConfiguredLlamaModel {
    param(
        [string]$RawModels
    )

    foreach ($entry in @(Get-ModelList -RawModels $RawModels)) {
        return $entry
    }

    return $null
}

function Convert-ToCodexModelName {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    if ($resolvedModel -match '^gpt-oss:(.+)$') {
        return "gpt-oss-$($Matches[1])"
    }

    if ($resolvedModel -match '^ggml-org/(.+)-GGUF$') {
        return $Matches[1]
    }

    return $resolvedModel.Replace(':', '-')
}

function Convert-ToLlamaRepoId {
    param(
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return ''
    }

    $resolvedModel = $ModelName.Trim()
    if ($resolvedModel -match '^[^/]+/.+-GGUF$') {
        return $resolvedModel
    }

    if ($resolvedModel -match '^openai/gpt-oss-(.+)$') {
        return "unsloth/gpt-oss-$($Matches[1])-GGUF"
    }

    if ($resolvedModel -match '^gpt-oss:(.+)$') {
        return "unsloth/gpt-oss-$($Matches[1])-GGUF"
    }

    if ($resolvedModel -match '^gpt-oss-(.+)$') {
        return "unsloth/gpt-oss-$($Matches[1])-GGUF"
    }

    return $resolvedModel
}

function Get-LlamaDownloadIncludePatterns {
    param(
        [string]$ModelName
    )

    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLAMACPP_GGUF_INCLUDE)) {
        return @(
            $env:LOCAL_CODEX_LLAMACPP_GGUF_INCLUDE.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return @('*.gguf')
    }

    $resolvedModel = $ModelName.Trim()
    if (
        ($resolvedModel -match '(^|/)gpt-oss-20b($|[-:])') -or
        ($resolvedModel -eq 'gpt-oss:20b')
    ) {
        return @('gpt-oss-20b-Q4_K_M.gguf')
    }

    if (
        ($resolvedModel -match '(^|/)gpt-oss-120b($|[-:])') -or
        ($resolvedModel -eq 'gpt-oss:120b')
    ) {
        return @('Q4_K_M/*.gguf', 'gpt-oss-120b-Q4_K_M*.gguf')
    }

    return @('*.gguf')
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

function Get-LlamaManifestPath {
    param(
        [string]$ModelRoot
    )

    return (Join-Path $ModelRoot 'manifest.json')
}

function Read-LlamaManifest {
    param(
        [string]$ModelRoot
    )

    $manifestPath = Get-LlamaManifestPath -ModelRoot $ModelRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return @()
    }

    $rawManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($null -eq $rawManifest) {
        return @()
    }

    if ($rawManifest -is [System.Collections.IEnumerable] -and -not ($rawManifest -is [string])) {
        return @($rawManifest)
    }

    if ($rawManifest.PSObject.Properties.Name -contains 'models') {
        return @($rawManifest.models)
    }

    return @($rawManifest)
}

function Write-LlamaManifest {
    param(
        [string]$ModelRoot,
        [object[]]$Entries
    )

    if (-not (Test-Path -LiteralPath $ModelRoot)) {
        New-Item -ItemType Directory -Path $ModelRoot -Force | Out-Null
    }

    $manifestPath = Get-LlamaManifestPath -ModelRoot $ModelRoot
    $payload = [pscustomobject]@{
        models = @($Entries)
    }

    Set-Content -LiteralPath $manifestPath -Value ($payload | ConvertTo-Json -Depth 8)
}

function Select-PrimaryGgufFile {
    param(
        [string]$ModelDirectory
    )

    $ggufFiles = @(
        Get-ChildItem -LiteralPath $ModelDirectory -Recurse -File -Filter '*.gguf' |
        Sort-Object -Property FullName
    )

    if ($ggufFiles.Count -eq 0) {
        return $null
    }

    foreach ($file in $ggufFiles) {
        if ($file.Name -match '-00001-of-\d+\.gguf$') {
            return $file.FullName
        }
    }

    return $ggufFiles[0].FullName
}

function Resolve-LlamaModelEntry {
    param(
        [object[]]$Manifest,
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $null
    }

    $desiredAlias = Convert-ToCodexModelName -ModelName $ModelName
    $desiredRepo = Convert-ToLlamaRepoId -ModelName $ModelName

    foreach ($entry in @($Manifest)) {
        if (
            (($entry.alias) -and ($entry.alias -eq $desiredAlias)) -or
            (($entry.repo) -and ($entry.repo -eq $desiredRepo)) -or
            (($entry.source_model) -and ($entry.source_model -eq $ModelName))
        ) {
            return $entry
        }
    }

    return $null
}
