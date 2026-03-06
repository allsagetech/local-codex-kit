# Local Codex Kit (Codex + Ollama)

This repo provides a container-only offline runtime for Codex CLI backed by a local Ollama server. The default image pre-pulls:

- `gpt-oss:20b`

The image installs both `ollama` and `codex`. At runtime the container stays offline with `network_mode: "none"`, and `codex` is preconfigured to talk only to the embedded Ollama endpoint at `http://127.0.0.1:11434/v1`.

## Quick start

1. Build the image:

```powershell
docker compose build local-codex-kit
```

To override the default model list before building:

```powershell
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS='gpt-oss:20b,gpt-oss:120b'
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
codex
codex-local
ollama-local
ollama run gpt-oss:20b
```

`ollama serve` starts automatically when the container boots. Startup also writes `/root/.codex/config.toml` so plain `codex` uses the local `oss` provider by default. `codex-local` is a convenience wrapper for `codex --profile oss --dangerously-bypass-approvals-and-sandbox`, which is often the easiest mode when Docker is already the outer sandbox. `ollama-local` runs `LOCAL_CODEX_OLLAMA_MODEL_ALIAS` if you set it; otherwise it uses the first configured model. Runtime networking stays disabled because `docker compose` runs with `network_mode: "none"`.

If you want both `codex` and `ollama-local` to use the 120B model by default:

```powershell
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS='gpt-oss:120b'
docker compose run --rm local-codex-kit
```

The `gpt-oss:120b` Ollama tag is about 65 GB. The default `gpt-oss:20b` tag is about 14 GB.

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
codex
```

The workspace persists across container runs because it lives in a named Docker volume.

## Offline behavior

After the image is built and your Ollama model is present, runtime is local-only:

- Docker disables container networking with `network_mode: "none"`
- Codex talks to `http://127.0.0.1:11434/v1` inside the same container
- Ollama model state stays in `/root/.ollama`

If a model was not pulled during build and networking is disabled, Codex cannot fetch it later. Rebuild with the model listed in `LOCAL_CODEX_OLLAMA_PULL_MODELS`, or start a networked build step separately before using the offline runtime.

## State and rebuilds

The default Compose service keeps runtime state in Docker volumes:

- `/workspace`
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

That removes the workspace and Ollama state.

## Files that matter

- `Dockerfile`: builds the image, installs PowerShell, Codex CLI, Ollama, and pre-pulls configured models
- `configure-codex.ps1`: writes the local Codex config that points to the embedded Ollama server
- `docker-compose.yml`: defines the offline container runtime and Docker-managed volumes
- `docker-entrypoint.ps1`: starts Ollama, writes Codex config, and opens the container shell
- `docker-profile.ps1`: adds the `codex-local` and `ollama-local` convenience commands
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-ollama.ps1`: launches `ollama serve` and waits for readiness

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
