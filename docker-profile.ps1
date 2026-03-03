function codex {
    # Default container route is LLVM/vLLM with Toolchain enabled.
    & '/opt/local-codex-kit/codex-here.ps1' -Preset llvm @args
}

function codex-llvm {
    & '/opt/local-codex-kit/codex-here.ps1' -Preset llvm @args
}

function codex-vllm {
    & '/opt/local-codex-kit/codex-here.ps1' -Preset vllm @args
}

function codex-local {
    & '/opt/local-codex-kit/codex-here.ps1' -Preset local @args
}

function codex-qwen {
    & '/opt/local-codex-kit/codex-here.ps1' -Preset qwen @args
}

function codex-small {
    & '/opt/local-codex-kit/codex-here.ps1' -Preset small @args
}
