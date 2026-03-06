# Local Codex Kit (Codex + Ollama in Docker)

This repo now follows the Ollama Codex integration inside the container instead of on the host:

- installs the OpenAI `codex` CLI in the image
- runs `ollama serve` inside the same container
- defaults to `gpt-oss:20b`
- keeps runtime networking disabled with `network_mode: "none"`
- includes VS Code, Chromium-compatible browser tooling, Git, Go, Python, Helm, Zarf, Node 22, and Linux build tools

The primary workflow is `codex --oss` inside Docker. A convenience wrapper, `codex-local`, is also available and expands to the container-safe defaults for this repo.

Command blocks below are labeled either as host-side PowerShell or as commands to run inside the container.

## What this matches

This repo implements the Ollama manual setup for Codex:

- install `@openai/codex`
- run `codex --oss`
- use a model with a context window of at least 64k tokens

Because Codex's Linux sandbox can be unreliable inside Docker, this image configures Codex to use `sandbox_mode = "danger-full-access"` with `approval_policy = "on-request"` and relies on Docker isolation instead. Runtime networking still stays disabled at the container level.

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
codex-local
```

Equivalent manual command inside the container:

```powershell
codex --oss -m openai/gpt-oss-20b
```

`ollama serve` starts automatically when the container boots. `gpt-oss:20b` is the default pulled Ollama tag, and `openai/gpt-oss-20b` is the default Codex model name. That follows the Ollama Codex docs and avoids Codex's fallback metadata warning for `gpt-oss:20b`.

## Default behavior

- `codex-local`: runs `codex --oss` with Docker-safe defaults and `openai/gpt-oss-20b`
- `codex --oss`: the upstream Ollama manual flow; the container seeds the OSS base URL and Codex config for you
- `ollama-local`: runs the default Ollama model directly
- `ollama list`: shows installed models

## Tooling

Installed in the image:

- `code`
- `chromium`
- `git`
- `go`
- `python`, `pip`, `venv`
- `helm`
- `zarf`
- `node`, `npm`, `npx`
- `gcc`, `clang`

Linux-specific note:

- `Notepad++` and `VS Build Tools` are Windows-only and are not added to this Ubuntu container.
- The image installs Linux-native equivalents instead: VS Code, terminal editors, and GNU/Clang build tooling.

## Context length

Ollama recommends at least 64k tokens for coding tools like Codex. This repo sets:

- `LOCAL_CODEX_OLLAMA_CONTEXT_LENGTH=65536`

That value is passed to `ollama serve` as `OLLAMA_CONTEXT_LENGTH`.

To change it for the next run:

```powershell
$env:LOCAL_CODEX_OLLAMA_CONTEXT_LENGTH='131072'
docker compose run --rm local-codex-kit
```

Make sure your hardware can support the larger context window.

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

If you want Codex to target a different pre-pulled model on the next container run:

```powershell
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS='gpt-oss:120b'
docker compose run --rm local-codex-kit
```

If you ever need to force a Codex model name manually, set `LOCAL_CODEX_CODEX_MODEL` explicitly.

The `gpt-oss:120b` Ollama tag is about 65 GB. The default `gpt-oss:20b` tag is about 14 GB.

## State and rebuilds

The default Compose service keeps runtime state in Docker volumes:

- `/workspace`
- `/root/.ollama`
- `/root/.codex`

Rebuilding the image updates the launcher code at `/opt/local-codex-kit` without clearing those volumes:

```powershell
docker compose build local-codex-kit
docker compose run --rm local-codex-kit
```

## Troubleshooting

If Ollama startup fails, the entrypoint prints the log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
codex --version
dpkg-query -W -f='${binary:Package} ${Version}\n' code
chromium --version
go version
python --version
helm version --short
zarf version
ollama list
Get-ChildItem /tmp/local-codex-kit
Get-Content /tmp/local-codex-kit/ollama.err.log -Tail 100
Get-Content /tmp/local-codex-kit/ollama.out.log -Tail 100
```

If a model was not pulled during build, runtime networking is disabled, and the model is missing from `/root/.ollama`, `codex --oss` and `ollama run` will fail until you rebuild with that model included.

## Compatibility note

The repo name, Compose service name, and environment variables still use the `local-codex-kit` and `LOCAL_CODEX_*` names for backward compatibility.

## Files

- `Dockerfile`: builds the image, installs PowerShell, Node 22, Codex CLI, Ollama, and the extra Linux-native dev tooling, then pre-pulls configured models
- `docker-compose.yml`: defines the offline container runtime and Docker-managed volumes
- `docker-entrypoint.ps1`: starts Ollama, seeds the Codex OSS config with the Ollama-compatible model name, loads the shell helpers, and opens the container shell
- `docker-profile.ps1`: adds the `codex-local`, `codex-ollama`, and `ollama-local` convenience commands
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-ollama.ps1`: launches `ollama serve` with the configured context length and waits for readiness
