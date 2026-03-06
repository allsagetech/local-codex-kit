# Local Codex Kit (Ollama-only)

This repo provides a container-only local Ollama workflow. The current default image pre-pulls two coding models through Ollama:

- `qwen3-coder`
- `qwen2.5-coder:32b`

## Quick start

1. Build the image:

```powershell
docker compose build local-codex-kit
```

To override the default model list before building:

```powershell
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS='qwen3-coder,qwen2.5-coder:32b'
docker compose build local-codex-kit
```

Set `LOCAL_CODEX_OLLAMA_PULL_MODELS=none` to skip build-time pulls entirely.

2. Start a shell inside the container:

```powershell
docker compose run --rm local-codex-kit
```

3. Inside the container, work from `/workspace`:

```powershell
New-Item -ItemType Directory -Force /workspace/scratch | Out-Null
Set-Location /workspace/scratch
ollama list
ollama-local
ollama run qwen2.5-coder:32b
```

`ollama serve` starts automatically when the container boots. `ollama-local` runs `LOCAL_CODEX_OLLAMA_MODEL_ALIAS` if you set it; otherwise it uses the first configured model. Runtime networking stays disabled because `docker compose` runs with `network_mode: "none"`.

If you want `ollama-local` to use the 32B model by default:

```powershell
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS='qwen2.5-coder:32b'
docker compose run --rm local-codex-kit
```

If you prefer importing a local GGUF instead of pulling from Ollama, the image still supports `LOCAL_CODEX_EMBEDDED_MODEL_URL`, `LOCAL_CODEX_EMBEDDED_MODEL_FILE`, and `LOCAL_CODEX_EMBEDDED_MODEL_SHA256`.

## Workspace flow

Use the Docker-managed `/workspace` volume for the code you want to work on. One straightforward host-to-container import flow is:

1. Start a named session:

```powershell
docker compose run --name local-codex-kit-session local-codex-kit
```

2. From another host shell, copy a repo into the workspace:

```powershell
docker cp C:\path\to\repo\. local-codex-kit-session:/workspace/my-repo
```

3. Back in the container:

```powershell
Set-Location /workspace/my-repo
ollama-local
```

The workspace persists across container runs because it lives in a named Docker volume.

## State and rebuilds

The default Compose service keeps runtime state in Docker volumes:

- `/workspace`
- `/opt/models`
- `/root/.ollama`

Rebuilding the image updates the launcher code at `/opt/local-codex-kit` without clearing those volumes:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

For a full reset:

```powershell
docker compose down -v
```

That removes the workspace, model cache, and Ollama state.

## Files that matter

- `Dockerfile`: builds the image, installs PowerShell and Ollama, and pre-pulls configured models
- `docker-compose.yml`: defines the offline container runtime and Docker-managed volumes
- `docker-entrypoint.ps1`: starts Ollama and opens the container shell
- `docker-profile.ps1`: adds the `ollama-local` convenience command
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-embedded-ollama.ps1`: launches `ollama serve`, optionally imports a local GGUF, and waits for readiness

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
