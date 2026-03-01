$ErrorActionPreference = 'Stop'
$Command = @($args)

$workspace = if ($env:LOCAL_CODEX_WORKSPACE) {
    $env:LOCAL_CODEX_WORKSPACE
} elseif (Test-Path '/workspace') {
    '/workspace'
} else {
    '/opt/local-codex-kit'
}

if (Test-Path $workspace) {
    Set-Location $workspace
}

Write-Host ''
Write-Host 'Local Codex Kit container'
Write-Host ("- Repo: {0}" -f '/opt/local-codex-kit')
Write-Host ("- Working directory: {0}" -f (Get-Location).Path)
Write-Host ("- Codex CLI: {0}" -f ((Get-Command codex).Source))
Write-Host '- Use this container for the kit scripts and Codex CLI environment.'
Write-Host ''

if ($Command -and $Command.Count -gt 0) {
    $commandName = $Command[0]
    $commandArgs = @($Command | Select-Object -Skip 1)
    & $commandName @commandArgs
    exit $LASTEXITCODE
}

Write-Host 'Starting interactive PowerShell session...'
Write-Host '- Container defaults: `codex` uses local GPT OSS, `codex-qwen` uses Qwen 32B, `codex-small` uses Qwen 7B.'
pwsh -NoLogo
exit $LASTEXITCODE
