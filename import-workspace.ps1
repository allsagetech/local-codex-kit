param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$Destination = '/workspace'
)

$ErrorActionPreference = 'Stop'

if (-not $Destination.StartsWith('/workspace')) {
    throw "Destination must stay under /workspace. Received: $Destination"
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
    throw "Source path must be a directory: $SourcePath"
}

$repoRoot = Split-Path -Parent $PSCommandPath
$containerName = 'local-ollama-kit-workspace-import'
$dockerCpSource = Join-Path $resolvedSource '.'
$escapedDestination = $Destination.Replace("'", "''")

& docker rm -f $containerName 2>$null | Out-Null

& docker compose -f (Join-Path $repoRoot 'docker-compose.yml') run -d --name $containerName --no-deps --entrypoint pwsh local-ollama-kit -NoLogo -NoProfile -Command "Start-Sleep -Seconds 600" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to start the temporary import container.'
}

try {
    & docker exec $containerName pwsh -NoLogo -NoProfile -Command "New-Item -ItemType Directory -Path '$escapedDestination' -Force | Out-Null" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create destination directory: $Destination"
    }

    & docker cp $dockerCpSource "${containerName}:${Destination}/"
    if ($LASTEXITCODE -ne 0) {
        throw "docker cp failed while importing '$resolvedSource' to '$Destination'."
    }
} finally {
    & docker rm -f $containerName 2>$null | Out-Null
}

Write-Host ("Imported '{0}' into Docker workspace volume at '{1}'." -f $resolvedSource, $Destination)
