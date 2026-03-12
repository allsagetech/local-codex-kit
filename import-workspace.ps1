param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$Destination = '/workspace'
)

$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Destination must not be empty.'
    }

    if (-not $Path.StartsWith('/')) {
        throw "Destination must be an absolute Linux path. Received: $Path"
    }

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $Path.Split('/')) {
        if (($segment -eq '') -or ($segment -eq '.')) {
            continue
        }

        if ($segment -eq '..') {
            if ($segments.Count -eq 0) {
                throw "Destination escapes the filesystem root: $Path"
            }

            $segments.RemoveAt($segments.Count - 1)
            continue
        }

        $segments.Add($segment)
    }

    $normalizedPath = if ($segments.Count -eq 0) {
        '/'
    } else {
        '/' + ($segments -join '/')
    }

    if (($normalizedPath -ne '/workspace') -and (-not $normalizedPath.StartsWith('/workspace/'))) {
        throw "Destination must stay under /workspace. Received: $Path"
    }

    return $normalizedPath
}

$resolvedDestination = Resolve-WorkspaceDestination -Path $Destination
$resolvedSource = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
    throw "Source path must be a directory: $SourcePath"
}

$repoRoot = Split-Path -Parent $PSCommandPath
$containerName = 'local-codex-kit-workspace-import-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
$dockerCpSource = Join-Path $resolvedSource '.'
$escapedDestination = $resolvedDestination.Replace("'", "''")

& docker rm -f $containerName 2>$null | Out-Null

& docker compose -f (Join-Path $repoRoot 'docker-compose.yml') run -d --name $containerName --no-deps --entrypoint pwsh local-codex-kit-workspace-import -NoLogo -NoProfile -Command "Start-Sleep -Seconds 600" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to start the temporary import container.'
}

try {
    & docker exec $containerName pwsh -NoLogo -NoProfile -Command "New-Item -ItemType Directory -Path '$escapedDestination' -Force | Out-Null" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create destination directory: $resolvedDestination"
    }

    & docker cp $dockerCpSource "${containerName}:${resolvedDestination}/"
    if ($LASTEXITCODE -ne 0) {
        throw "docker cp failed while importing '$resolvedSource' to '$resolvedDestination'."
    }
} finally {
    & docker rm -f $containerName 2>$null | Out-Null
}

Write-Host ("Imported '{0}' into Docker workspace volume at '{1}'." -f $resolvedSource, $resolvedDestination)
