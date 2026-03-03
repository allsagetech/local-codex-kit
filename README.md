# Local Codex Kit

This folder is meant to be handed to someone as a working local Codex launcher.

## Fast handoff

Give them the `local-codex-kit` folder, then have them do these steps in PowerShell:

```powershell
cd D:\local-codex-kit
.\install.ps1
. $PROFILE
```

That installs Toolchain if needed, ensures the Toolchain `codex:latest` package is available, and writes a managed `codex` function into their PowerShell profile that points at this kit. For LM Studio presets it also installs/bootstraps LM Studio and downloads default models.

This kit now prefers an existing Toolchain repo at `C:\Users\sages\Documents\allsagetech\Toolchain` (or `LOCAL_CODEX_TOOLCHAIN_REPO`) before cloning anything.

Install a different default preset if needed:

```powershell
.\install.ps1 -Preset qwen
.\install.ps1 -Preset small
.\install.ps1 -Preset llvm
```

Skip the default model downloads if needed:

```powershell
.\install.ps1 -SkipModelDownload
```

Choose the model setup mode explicitly if needed:

```powershell
.\install.ps1 -ModelSetup default
.\install.ps1 -ModelSetup interactive
.\install.ps1 -ModelSetup skip
```

Preview the install without changing the machine:

```powershell
.\install.ps1 -DryRun
```

Remove the changes later if needed:

```powershell
.\delete.ps1
```

Preview the uninstall without removing anything:

```powershell
.\delete.ps1 -DryRun
```

Build the Docker image if you want a packaged CLI environment:

```powershell
.\seed-toolchain-offline.ps1 -Clean
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

Default Docker package refs used by this flow:

- `codex-linux:latest`
- `git-linux:latest`
- `llvm-linux:latest`

Windows host install (`.\install.ps1`) still uses `codex:latest` / `llvm:latest`.

Inside the container shell:

```powershell
codex
codex-llvm
codex-vllm
codex-local
codex-qwen
codex-small
```

The container profile maps `codex` to LLVM/vLLM mode with Toolchain enabled by default.
`codex-local`, `codex-qwen`, and `codex-small` are also available.
`docker compose` is configured with `network_mode: "none"` so the container has no internet access.
Because networking is disabled, `LOCAL_CODEX_LLVM_BASE_URL` must point to a server running inside the same container namespace (for example `http://127.0.0.1:8000/v1`).
`.\seed-toolchain-offline.ps1` saves Toolchain packages into `.\.toolchain-offline` (gitignored), and Docker copies that folder into `/opt/toolchain-repo` inside the image.
At runtime, Toolchain is configured with `ToolchainRepo=/opt/toolchain-repo` and `ToolchainPullPolicy=IfNotPresent` so package resolution stays local/offline.

Toolchain package build/push workflow should stay in your `C:\Users\sages\Documents\allsagetech\Toolchains` repo; this kit only consumes already-available packages.

For strict offline runs, pin package refs when seeding:

```powershell
.\seed-toolchain-offline.ps1 -Clean -CodexPackage codex-linux:latest -GitPackage git-linux:latest -LlvmPackage llvm-linux:latest
```

Package refs that also control runtime `toolchain exec` in the container:

- `LOCAL_CODEX_TOOLCHAIN_CODEX_PKG`
- `LOCAL_CODEX_TOOLCHAIN_GIT_PKG`
- `LOCAL_CODEX_TOOLCHAIN_LLVM_PKG`

Optionally pin Toolchain source for reproducible builds:

- `LOCAL_CODEX_TOOLCHAIN_REPO_URL`
- `LOCAL_CODEX_TOOLCHAIN_REPO_REF`

If they want to do it manually instead, this is the exact profile snippet:

```powershell
function codex {
    D:\local-codex-kit\codex-here.ps1 -Preset local @args
}
```

Then from any repo:

```powershell
cd D:\some-repo
codex
```

## What they need installed

- Git in PATH
- Toolchain will be installed by `.\install.ps1` if it is missing
- the Toolchain `codex:latest` package will be fetched by `.\install.ps1`
- the Toolchain `llvm:latest` package will be fetched by `.\install.ps1` (disable with `LOCAL_CODEX_USE_LLVM_TOOLCHAIN=0`)
- for `local`, `qwen`, or `small` presets: LM Studio desktop will be installed if missing, `lmstudio:latest` can bootstrap `lms`, and default models are downloaded
- for `llvm`/`vllm` preset: run your local LLVM/vLLM-compatible server separately (default endpoint `http://127.0.0.1:8000/v1`)

## What `codex` does here

The default route is:

- preset: `local`
- mode: `local-balanced`
- Codex model slug: `gpt-oss-20b`
- LM Studio model: `openai/gpt-oss-20b`

Other options:

- `codex -Preset qwen`
- `codex -Preset small`
- `codex -Preset llvm` (alias: `codex -Preset vllm`)

LLVM/vLLM route defaults:

- provider: `llvm`
- base URL env: `LOCAL_CODEX_LLVM_BASE_URL` (default `http://127.0.0.1:8000/v1`)
- model env: `LOCAL_CODEX_LLVM_MODEL` (default `llama3`)
- API key env name: `LOCAL_CODEX_LLVM_API_KEY_ENV` (default `LOCAL_CODEX_LLVM_API_KEY`)
- Toolchain package envs: `LOCAL_CODEX_TOOLCHAIN_CODEX_PKG` / `LOCAL_CODEX_TOOLCHAIN_LLVM_PKG`

## Expected startup output

When it is working, startup should show all of these:

- `Selected model: Local GPT OSS 20B`
- `Codex model slug: gpt-oss-20b`
- `Codex sandbox: workspace-write`
- `LM Studio model: openai/gpt-oss-20b`
- `Toolchain: enabled`

Then the Codex TUI should open with:

- `model: gpt-oss-20b`

For LLVM/vLLM mode, startup should show:

- `Provider: llvm`
- `LLVM endpoint: http://127.0.0.1:8000/v1` (or your override)
- `Codex model slug: <your LLVM model>`

## Best way to share this

The fastest path is:

1. Give them the whole `D:\local-codex-kit` folder.
2. Tell them to run `.\install.ps1`, `.\install.ps1 -Preset qwen`, `.\install.ps1 -Preset small`, or `.\install.ps1 -Preset llvm`.
3. For lower-memory machines, tell them to use `.\install.ps1 -Preset small`.
4. Tell them to run `. $PROFILE`.
5. Tell them to run `codex` inside a Git repo.

That is simpler than asking them to hand-edit their profile.

## Files that matter

- `codex-here.ps1`: entry point with `local`, `qwen`, `small`, and `llvm`/`vllm`
- `install.ps1`: installs Toolchain, ensures `codex:latest` and `llvm:latest` are available, configures either LM Studio presets or LLVM preset, and sets the default preset
- `delete.ps1`: removes the managed profile block and can remove Toolchain, LM Studio, and downloaded models
- `start-codex.ps1`: prints launch info and starts Codex
- `codex-backend.ps1`: model routing, Git checks, LM Studio integration, and LLVM/vLLM custom-provider integration
- `bootstrap-toolchain.ps1`: ensures Toolchain is installed, preferring `C:\Users\sages\Documents\allsagetech\Toolchain` or `LOCAL_CODEX_TOOLCHAIN_REPO`
- `seed-toolchain-offline.ps1`: saves selected Toolchain packages into `.\.toolchain-offline` for Docker offline seeding (defaults: `codex-linux`, `git-linux`, `llvm-linux`)
- `Dockerfile`: builds a PowerShell image with Git/Codex CLI, installs Toolchain in Linux, and copies `.\.toolchain-offline` into `/opt/toolchain-repo`
- `docker-entrypoint.ps1`: starts an interactive container shell, loads Toolchain module, and enforces offline Toolchain pull policy
- `docker-profile.ps1`: maps container commands (`codex`, `codex-llvm`, `codex-vllm`, etc.) to kit presets
- `docker-lmstudio-bridge.js`: optional host LM Studio bridge helper (not used by default in offline container mode)
- `docker-compose.yml`: mounts the kit/workspace, passes Toolchain build args, and disables container network access

## Notes

- run `Remove-Item Function:\codex` if you want the stock Codex CLI in the current shell
- run `. $PROFILE` or open a new PowerShell window after changing your profile
- starting from a Git repo gives better repo-aware behavior
- `Codex sandbox: workspace-write` is the Codex CLI permission sandbox; the Docker image is only a packaging/container layer around the CLI

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
