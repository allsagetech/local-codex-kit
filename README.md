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

3. Inside the container, move into a project under `/workspace` and then run Codex:

```powershell
New-Item -ItemType Directory -Force /workspace/scratch | Out-Null
Set-Location /workspace/scratch
codex
codex-llvm
codex-vllm
```

`codex` defaults to the embedded LLVM/vLLM-compatible endpoint at `http://127.0.0.1:8000/v1`.
`docker compose` is configured with `network_mode: "none"` at runtime, so the container has no external network access after startup.
If you build without a model, the shell still starts, but `codex` will not work until `/opt/models` contains a GGUF model or `LOCAL_CODEX_LLVM_BASE_URL` points at another in-container endpoint.
If embedded `llama-server` startup fails, the container now drops you into the shell with the recent server logs instead of exiting immediately. Increase `LOCAL_CODEX_EMBEDDED_STARTUP_TIMEOUT_SEC` if your model is slow to load on CPU, or set `LOCAL_CODEX_EMBEDDED_REQUIRE_READY=1` to keep fail-fast behavior.
For repo-aware sessions, put a Git repo or project directory under `/workspace` before launching `codex`.

## Importing code into the workspace

Use the Docker-managed workspace volume at `/workspace` for the code you want Codex to edit.

One concrete import flow from the host without bind mounts is:

1. Start a named session:

```powershell
docker compose run --name local-codex-kit-session local-codex-kit
```

2. From a second host shell, copy a project into the container workspace:

```powershell
docker cp C:\path\to\repo\. local-codex-kit-session:/workspace/my-repo
```

3. Back in the container shell:

```powershell
Set-Location /workspace/my-repo
codex
```

When that session exits, the project remains in the Docker-managed `workspace` volume for the next container run.

## What persists

The default Compose service stores all mutable runtime state in named Docker volumes:

- workspace contents at `/workspace`
- model files at `/opt/models`
- Toolchain cache at `/opt/toolchain-cache`
- Codex auth/config at `/root/.codex`

The launcher code itself stays in the image at `/opt/local-codex-kit`, so rebuilding the image updates the kit without requiring a volume reset.

## Updating the image

To pick up new kit code or a new image build, rebuild and start the container again:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

This keeps the Docker-managed workspace, models, Toolchain cache, and Codex auth state intact.

## Resetting state

If you want a completely fresh container state, remove the service volumes:

```powershell
docker compose down -v
```

That wipes the workspace, model volume, Toolchain cache, and Codex auth/config.

## Toolchain packages

The image build now pre-seeds the Toolchain package repo inside the image with:

- `codex:codex-0.106.0-linux`

The Codex Linux image is currently published on Docker Hub as the legacy tag `codex-0.106.0-linux`, so the Toolchain package ref must use the raw-tag form `codex:codex-0.106.0-linux`.

`git` and `clang` are installed directly from Ubuntu packages in the container because the current `allsagetech/toolchains` registry no longer publishes Linux `git` or `llvm` package names. `LOCAL_CODEX_TOOLCHAIN_GIT_PKG` and `LOCAL_CODEX_TOOLCHAIN_LLVM_PKG` therefore default to empty in Docker unless you override them with valid package refs.

You can override them at build and runtime with:

- `LOCAL_CODEX_TOOLCHAIN_CODEX_PKG`
- `LOCAL_CODEX_TOOLCHAIN_GIT_PKG`
- `LOCAL_CODEX_TOOLCHAIN_LLVM_PKG`

If you change those refs, rebuild the image so the container's offline Toolchain repo matches the runtime package settings. The default runtime pull policy refreshes packages from the embedded offline repo on each launch.

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
- if you rebuild the image with a different baked model and want it to replace the existing `/opt/models` volume contents, reset the model volume with `docker compose down -v` or remove that volume explicitly
- if you want repo-aware behavior for the launcher repo itself, keep `.git` in the image context when building

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
