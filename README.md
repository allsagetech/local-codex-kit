# Local Codex Kit

This repo now defaults to a container-only workflow. Runtime state stays inside Docker-managed volumes instead of writing to your host profile, host Toolchain install, host LM Studio install, or host bind-mounted workspace.

## Quick start

1. Build the image. If you want an embedded model baked into the image, set a model URL first:

```powershell
$env:LOCAL_CODEX_EMBEDDED_MODEL_URL='https://.../qwen2.5-coder-7b-instruct-q4_k_m.gguf'
$env:LOCAL_CODEX_EMBEDDED_MODEL_SHA256='<sha256>'
docker compose build local-codex-kit
```

2. Start a shell inside the container:

```powershell
docker compose run --rm local-codex-kit
```

3. Inside the container:

```powershell
codex
codex-llvm
codex-vllm
```

`codex` defaults to the embedded LLVM/vLLM-compatible endpoint at `http://127.0.0.1:8000/v1`.
`docker compose` is configured with `network_mode: "none"` at runtime, so the container has no external network access after startup.
If you build without a model, the shell still starts, but `codex` will not work until `/opt/models` contains a GGUF model or `LOCAL_CODEX_LLVM_BASE_URL` points at another in-container endpoint.

## What persists

The default Compose service stores all mutable runtime state in named Docker volumes:

- repo contents at `/opt/local-codex-kit`
- model files at `/opt/models`
- Toolchain cache at `/opt/toolchain-cache`
- PowerShell and app config at `/root/.config`
- Codex auth/config at `/root/.codex`

That means the container can be removed and recreated without writing launcher state onto the host filesystem outside Docker's own managed storage.

## Updating and resetting

The repo volume is seeded from the image the first time it is created. If you rebuild the image and want a fresh copy of the repo inside Docker, remove the named volumes and start again:

```powershell
docker compose down -v
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

## Toolchain packages

The image build now pre-seeds the Toolchain package repo inside the image. The default package refs are:

- `codex-linux:latest`
- `git-linux:latest`
- `llvm-linux:latest`

You can override them at build and runtime with:

- `LOCAL_CODEX_TOOLCHAIN_CODEX_PKG`
- `LOCAL_CODEX_TOOLCHAIN_GIT_PKG`
- `LOCAL_CODEX_TOOLCHAIN_LLVM_PKG`

If you change those refs, rebuild the image so the container's offline Toolchain repo matches the runtime package settings.

## Container commands

Inside the container shell:

```powershell
codex
codex-llvm
codex-vllm
```

`codex-local`, `codex-qwen`, and `codex-small` are intentionally disabled in the container image because they depend on LM Studio, which is not installed in this Docker-first flow.

## Legacy host scripts

`install.ps1`, `delete.ps1`, and `seed-toolchain-offline.ps1` are still in the repo for older host-based workflows, but they are no longer the default or recommended path.

## Files that matter

- `Dockerfile`: builds the container image, installs PowerShell/Codex, builds Toolchain, and seeds the offline Toolchain repo during image build
- `docker-compose.yml`: runs the container without external network access and keeps mutable state in Docker volumes
- `docker-entrypoint.ps1`: starts the embedded model server when available and opens the container shell
- `docker-profile.ps1`: maps supported container commands to the LLVM/vLLM preset
- `start-embedded-llm.ps1`: launches `llama-server` inside the container and waits for readiness
- `start-codex.ps1`: launches Codex and blocks LM Studio-only presets when running in container mode

## Notes

- model weights are not included by default; provide them with `LOCAL_CODEX_EMBEDDED_MODEL_URL` during build or intentionally bake a local file into the image
- `Codex sandbox: workspace-write` is the Codex CLI sandbox mode inside the container
- if you want repo-aware behavior inside the container, keep `.git` in the image context when building

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
