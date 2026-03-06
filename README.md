# Local Codex Kit (Ollama-only)

This repo now provides a container-only local Ollama workflow. Codex, LLVM, `llama-server`, and Toolchain are no longer part of the runtime path.

## Quick start

1. Build the image. By default the build pre-pulls `qwen3-coder` through Ollama. To choose different models, set `LOCAL_CODEX_OLLAMA_PULL_MODELS` first:

```powershell
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS='qwen3-coder'
docker compose build local-codex-kit
```

You can pre-pull multiple Ollama models with a comma-separated list such as `qwen3-coder,deepseek-r1:8b`.
Set `LOCAL_CODEX_OLLAMA_PULL_MODELS=none` if you want the image build to skip model downloads entirely.

2. Start a shell inside the container:

```powershell
docker compose run --rm local-codex-kit
```

3. Inside the container, move into a project under `/workspace` and use Ollama directly:

```powershell
New-Item -ItemType Directory -Force /workspace/scratch | Out-Null
Set-Location /workspace/scratch
ollama list
ollama-local
# or:
ollama run qwen3-coder
```

The container starts `ollama serve` automatically.
During image build, it pre-pulls the models listed in `LOCAL_CODEX_OLLAMA_PULL_MODELS`.
`ollama-local` is a convenience wrapper for the default model selected by `LOCAL_CODEX_OLLAMA_MODEL_ALIAS`, or the first pulled model if that variable is unset.
`docker compose` runs with `network_mode: "none"`, so the container has no external network access after startup.
If you build without pre-pulling a model, the shell still starts, but `ollama-local` will not work until you pull or create a model yourself.
If embedded Ollama startup fails, the container drops you into the shell with the recent server logs instead of exiting immediately. Increase `LOCAL_CODEX_OLLAMA_STARTUP_TIMEOUT_SEC` if startup is slow, or set `LOCAL_CODEX_OLLAMA_REQUIRE_READY=1` to keep fail-fast behavior.
If you prefer a local GGUF import instead of `ollama pull`, the old baked-model env vars still work: `LOCAL_CODEX_EMBEDDED_MODEL_URL`, `LOCAL_CODEX_EMBEDDED_MODEL_FILE`, and `LOCAL_CODEX_EMBEDDED_MODEL_SHA256`.

## Importing code into the workspace

Use the Docker-managed workspace volume at `/workspace` for the code you want to work on.

One concrete flow from the host without bind mounts is:

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
ollama-local
```

When that session exits, the project remains in the Docker-managed `workspace` volume for the next container run.

## What persists

The default Compose service stores mutable runtime state in named Docker volumes:

- workspace contents at `/workspace`
- model files at `/opt/models`
- Ollama state at `/root/.ollama`

The launcher code stays in the image at `/opt/local-codex-kit`, so rebuilding the image updates the kit without requiring a volume reset.

## Updating the image

To pick up new kit code or a new image build, rebuild and start the container again:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

This keeps the Docker-managed workspace, models, and Ollama state intact.

## Resetting state

If you want a completely fresh container state, remove the service volumes:

```powershell
docker compose down -v
```

That wipes the workspace, model volume, and Ollama state.

## Container commands

Inside the container shell:

```powershell
ollama-local
ollama list
ollama run qwen3-coder
```

## Files that matter

- `Dockerfile`: builds the container image and installs PowerShell plus Ollama
- `docker-compose.yml`: runs the container without external network access and keeps mutable state in Docker volumes
- `docker-entrypoint.ps1`: starts Ollama when available and opens the container shell
- `docker-profile.ps1`: adds the `ollama-local` convenience command
- `pull-ollama-models.ps1`: starts a temporary Ollama server during image build and runs `ollama pull` for configured models
- `start-embedded-ollama.ps1`: launches `ollama serve`, optionally imports a local GGUF as an Ollama model, and waits for readiness

## Notes

- build-time model pulls are controlled by `LOCAL_CODEX_OLLAMA_PULL_MODELS`
- set `LOCAL_CODEX_OLLAMA_PULL_MODELS=none` to skip build-time pulls
- if you pull multiple models, set `LOCAL_CODEX_OLLAMA_MODEL_ALIAS` to choose which one `ollama-local` should run by default
- you can still bake a local GGUF into the image with `LOCAL_CODEX_EMBEDDED_MODEL_URL` if you want an imported local model instead of a registry pull
- Ollama is enabled by default in Docker; set `LOCAL_CODEX_OLLAMA_ENABLE=0` if you want to start the shell without a local runtime
- if you rebuild the image with different pulled models and want a completely fresh Ollama state, reset the volumes with `docker compose down -v`

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
