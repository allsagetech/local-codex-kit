# Local Codex Kit (Codex + Ollama)

This repo provides a container-only local Codex workflow backed by an embedded Ollama server. The default image pre-pulls:

- `gpt-oss:20b`

The image installs both `ollama` and `codex`. At runtime the container stays offline with `network_mode: "none"`, and `codex` is preconfigured to talk only to the embedded Ollama endpoint at `http://127.0.0.1:11434/v1`.

Command blocks below are labeled either as host-side PowerShell or as commands to run inside the container.

## What "offline" means here

After the image has been built and the model has been pulled, runtime is local-only:

- Docker disables container networking with `network_mode: "none"`
- Codex talks to `http://127.0.0.1:11434/v1` inside the same container
- Ollama model state stays in `/root/.ollama`

The first build is not network-free. The Dockerfile downloads Ubuntu packages, PowerShell, Ollama, the Codex CLI binary, and any Ollama models you request. If you need a truly air-gapped first build, you need to pre-stage those artifacts in your own mirror or modify the image build to consume local files only.

## Recommended path

If your goal is "use `gpt-oss` with Codex and keep runtime 100% offline", this is the shortest path.

From a host PowerShell:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

Inside the container:

```powershell
codex-local
```

`codex-local` is the safest default inside this Docker setup because it bypasses Codex's own inner sandbox and approval flow while Docker is already acting as the outer isolation boundary.

## Quick start

From a host PowerShell:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

Inside the container, create a workspace directory and start Codex:

```powershell
New-Item -ItemType Directory -Force /workspace/scratch | Out-Null
Set-Location /workspace/scratch
ollama list
codex-local
```

`ollama serve` starts automatically when the container boots. Startup also writes `/root/.codex/config.toml` so plain `codex` uses the local `oss` provider by default. `codex-local` is a convenience wrapper for `codex --profile oss --model <current-model> --dangerously-bypass-approvals-and-sandbox`, which is often the easiest mode when Docker is already the outer sandbox. `ollama-local` runs `LOCAL_CODEX_OLLAMA_MODEL_ALIAS` if you set it; otherwise it uses the first configured model. Runtime networking stays disabled because `docker compose` runs with `network_mode: "none"`.

If you want to verify what is available first:

```powershell
ollama list
```

If you want to use the 120B model on the next container run, set this in the host shell before starting the container:

```powershell
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS='gpt-oss:120b'
docker compose run --rm local-codex-kit
```

The `gpt-oss:120b` Ollama tag is about 65 GB. The default `gpt-oss:20b` tag is about 14 GB.

## Which command to use

- `codex`: uses the generated `/root/.codex/config.toml` and should already target local Ollama
- `codex-local`: same local model target, but also disables Codex's inner sandbox and approvals
- `ollama-local`: runs the default Ollama model directly without the Codex agent
- `ollama run gpt-oss:20b`: explicit direct Ollama invocation

## Workspace flow

From a host PowerShell, start a named session:

```powershell
docker compose run --name local-codex-kit-session local-codex-kit
```

From another host PowerShell, copy your repo into the workspace:

```powershell
docker cp C:\path\to\repo\. local-codex-kit-session:/workspace/my-repo
```

Inside the container:

```powershell
Set-Location /workspace/my-repo
codex-local
```

The workspace persists across container runs because it lives in a named Docker volume.

## Model changes

If a model was not pulled during build and networking is disabled, Codex cannot fetch it later. Set `LOCAL_CODEX_OLLAMA_PULL_MODELS` before rebuilding the image on the host.

Common examples:

```powershell
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS='gpt-oss:20b'
docker compose build local-codex-kit
```

```powershell
$env:LOCAL_CODEX_OLLAMA_PULL_MODELS='gpt-oss:20b,gpt-oss:120b'
docker compose build local-codex-kit
```

Set `LOCAL_CODEX_OLLAMA_PULL_MODELS=none` to skip build-time pulls entirely.

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

That clears both the workspace and Ollama state.

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
