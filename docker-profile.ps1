function Get-LocalCodexKitRoot {
    if ($env:LOCAL_CODEX_KIT_ROOT) {
        return $env:LOCAL_CODEX_KIT_ROOT
    }

    return '/opt/local-codex-kit'
}

function Show-UnsupportedContainerPreset {
    param(
        [string]$Name
    )

    throw ("{0} requires LM Studio, which is intentionally not installed in the container image. Use codex, codex-llvm, or codex-vllm." -f $Name)
}

function codex {
    # Default container route is LLVM/vLLM with Toolchain enabled.
    & (Join-Path (Get-LocalCodexKitRoot) 'codex-here.ps1') -Preset llvm @args
}

function codex-llvm {
    & (Join-Path (Get-LocalCodexKitRoot) 'codex-here.ps1') -Preset llvm @args
}

function codex-vllm {
    & (Join-Path (Get-LocalCodexKitRoot) 'codex-here.ps1') -Preset vllm @args
}

function codex-local {
    Show-UnsupportedContainerPreset -Name 'codex-local'
}

function codex-qwen {
    Show-UnsupportedContainerPreset -Name 'codex-qwen'
}

function codex-small {
    Show-UnsupportedContainerPreset -Name 'codex-small'
}
