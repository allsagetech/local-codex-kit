# Local Codex Kit (Ollama-only)

This repo now uses embedded `ollama` directly instead of the Codex CLI. The default image pre-pulls:

- `gpt-oss:20b`

At runtime the container stays offline with `network_mode: "none"`, and `ollama serve` runs inside the same container.

Command blocks below are labeled either as host-side PowerShell or as commands to run inside the container.

## What "offline" means here

After the image has been built and the model has been pulled, runtime is local-only:

- Docker disables container networking with `network_mode: "none"`
- Ollama serves locally on `http://127.0.0.1:11434`
- Ollama model state stays in `/root/.ollama`

The first build is not network-free. The Dockerfile still downloads Ubuntu packages, PowerShell, Ollama, and any Ollama models you request. If you need a truly air-gapped first build, you need to pre-stage those artifacts in your own mirror or modify the image build to consume local files only.

## Quick start

From a host PowerShell:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

Inside the container:

```powershell
New-Item -ItemType Directory -Force /workspace/scratch | Out-Null
Set-Location /workspace/scratch
ollama list
ollama-local
```

`ollama serve` starts automatically when the container boots. `ollama-local` uses `LOCAL_CODEX_OLLAMA_MODEL_ALIAS` if you set it; otherwise it uses the first configured pulled model.

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

- `ollama-local`: runs the default configured Ollama model directly
- `ollama run gpt-oss:20b`: explicit direct Ollama invocation
- `ollama list`: shows installed models

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
ollama-local
```

The workspace persists across container runs because it lives in a named Docker volume.

## Model changes

If a model was not pulled during build and networking is disabled, Ollama cannot fetch it later. Set `LOCAL_CODEX_OLLAMA_PULL_MODELS` before rebuilding the image on the host.

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

## Troubleshooting

If Ollama startup fails, the entrypoint prints the log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
ollama list
Get-ChildItem /tmp/local-codex-kit
Get-Content /tmp/local-codex-kit/ollama.err.log -Tail 100
Get-Content /tmp/local-codex-kit/ollama.out.log -Tail 100
```

If a model was not pulled during build, runtime networking is disabled, and the model is missing from `/root/.ollama`, direct `ollama run` commands will fail until you rebuild with that model included.

## Compatibility note

The repo name, Compose service name, and environment variables still use the `local-codex-kit` and `LOCAL_CODEX_*` names for backward compatibility. The runtime path is now Ollama-only.

## Files

- `Dockerfile`: builds the image, installs PowerShell and Ollama, and pre-pulls configured models
- `docker-compose.yml`: defines the offline container runtime and Docker-managed volumes
- `docker-entrypoint.ps1`: starts Ollama, loads the shell helpers, and opens the container shell
- `docker-profile.ps1`: adds the `ollama-local` convenience command
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-ollama.ps1`: launches `ollama serve` and waits for readiness
