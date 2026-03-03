param(
    [ValidateSet('auto', 'local', 'qwen', 'small', 'llvm', 'vllm')]
    [string]$Preset = 'auto',
    [Alias('Prompt')]
    [string]$Task = '',
    [switch]$NoToolchain,
    [switch]$NoPreamble
)

$mode = switch ($Preset) {
    'auto' { 'auto' }
    'local' { 'local-balanced' }
    'qwen' { 'local-coder' }
    'small' { 'local-small' }
    'llvm' { 'local-llvm' }
    'vllm' { 'local-llvm' }
}

& (Join-Path $PSScriptRoot 'start-codex.ps1') -Mode $mode -ExtraPrompt $Task -NoPreamble:$NoPreamble -WorkingDirectory (Get-Location).Path -UseToolchain:(-not $NoToolchain)
