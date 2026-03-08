# Local Codex Kit (Container-Only Codex + Ollama)

This repo packages Codex and Ollama into a single Docker runtime with the security boundary at the container:

- no host bind mount onto `/workspace` itself
- runtime networking disabled with `network_mode: "none"`
- non-root runtime user
- read-only root filesystem
- tmpfs-backed `/tmp`
- `no-new-privileges`
- all Linux capabilities dropped

The intended workflow is:

1. build the image with the models you want baked in
2. import code into the Docker-managed workspace volume
3. run Codex inside the container against `/workspace`

## What this repo does

- installs the OpenAI `codex` CLI in the image
- runs `ollama serve` inside the same container
- defaults to Ollama tag `gpt-oss:20b`
- stores the workspace and runtime state in Docker-managed volumes
- stores the Ollama model payload inside the image at `/opt/local-codex-kit/ollama-models`
- keeps runtime network access disabled

`codex-local` is the convenience entrypoint inside the container. It expands to `codex --oss` with the local Ollama endpoint and the container-safe defaults for this repo.

## Quick start

Build the image on the host:

```powershell
docker compose build local-codex-kit
```

If Docker Hub is flaky in your environment, you can override the base image without editing the repo:

```powershell
$env:LOCAL_CODEX_BASE_IMAGE='your-mirror-or-local-tag:22.04'
docker compose build local-codex-kit
```

Import a host project into the Docker workspace volume:

```powershell
.\import-workspace.ps1 -SourcePath C:\path\to\project -Destination /workspace/project
```

Start the container:

```powershell
docker compose run --rm local-codex-kit
```

Inside the container:

```powershell
Set-Location /workspace/project
ollama list
codex-local
```

Equivalent manual Codex command inside the container:

```powershell
codex --oss -m gpt-oss:20b
```

If Codex prints `Model metadata for "gpt-oss:20b" not found`, treat that as a warning from the CLI metadata table rather than an Ollama runtime failure.

## Security model

This setup assumes the container is the trust boundary.

- project files live in a Docker volume mounted at `/workspace`
- Codex state lives in a Docker volume mounted at `/home/codex/.codex`
- Ollama runtime state lives in a Docker volume mounted at `/home/codex/.ollama`
- Ollama model blobs are baked into the image at `/opt/local-codex-kit/ollama-models`

Because Codex's Linux sandbox can be unreliable inside Docker, the container still defaults Codex to `sandbox_mode = "danger-full-access"` with `approval_policy = "on-request"`. The containment is enforced by Docker and the hardened runtime settings, not by a nested sandbox.

## Workspace handling

The Compose service includes a live host project bind mount at `/workspace/project`.

By default, it binds `./host-project` from this repo. You can instead point it at any host project path by setting `LOCAL_CODEX_HOST_PROJECT_PATH` before starting the container:

```powershell
$env:LOCAL_CODEX_HOST_PROJECT_PATH='C:\path\to\your\project'
docker compose run --rm local-codex-kit
```

Inside the container, work in:

```powershell
/workspace/project
```

Any file changes you make there are immediately visible on the host, because `/workspace/project` is a bind mount to the host path.

The rest of `/workspace` remains in the Docker-managed volume, so you still keep the container-local workspace layout for anything outside the bound project folder.

To copy a host folder into the Docker-managed workspace volume:

```powershell
.\import-workspace.ps1 -SourcePath C:\path\to\project -Destination /workspace/project
```

To inspect the workspace from inside the container:

```powershell
Get-ChildItem /workspace
```

If you need to copy files out later, use `docker cp` from a running container or a temporary helper container. The default workflow keeps the active workspace inside Docker.

## Model handling

Models are selected at image-build time through `LOCAL_CODEX_OLLAMA_PULL_MODELS`.

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

At runtime, Ollama reads models from the image-baked model store at `/opt/local-codex-kit/ollama-models`. To change the available model set, rebuild the image.

To select a different baked model at runtime:

```powershell
$env:LOCAL_CODEX_OLLAMA_MODEL_ALIAS='gpt-oss:120b'
docker compose run --rm local-codex-kit
```

If you need to override the Codex model name explicitly, set `LOCAL_CODEX_CODEX_MODEL` to the Ollama model name, for example `gpt-oss:20b`.

## Default behavior

- `codex-local`: runs `codex --oss` with the local Ollama endpoint and repo defaults
- `codex --oss`: the upstream Ollama manual flow; this container seeds the config for you
- `ollama-local`: runs the default Ollama model directly
- `ollama list`: shows the baked model set visible to the runtime

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

`code .` inside this headless container does not open your Windows desktop VS Code.

## Context length

The default context length is:

- `LOCAL_CODEX_OLLAMA_CONTEXT_LENGTH=65536`

To change it for the next container run:

```powershell
$env:LOCAL_CODEX_OLLAMA_CONTEXT_LENGTH='131072'
docker compose run --rm local-codex-kit
```

Make sure your hardware can support the larger context window.

## State

The default Compose service keeps the following Docker-managed volumes:

- `/workspace`
- `/home/codex/.codex`
- `/home/codex/.ollama`

The image also contains the baked model store at `/opt/local-codex-kit/ollama-models`.

The service also includes one host bind mount at `/workspace/project`, which defaults to `./host-project` unless `LOCAL_CODEX_HOST_PROJECT_PATH` is set.

Rebuilding the image updates the launcher code and the baked model set without bind-mounting any host workspace into the container.

## Troubleshooting

If Ollama startup fails, the entrypoint prints log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
codex --version
code --version
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

If `codex-local` reports that a model is missing, rebuild the image with `LOCAL_CODEX_OLLAMA_PULL_MODELS` updated to include that model.

If you want to reset all Docker-managed state for this repo, remove the named volumes created by Compose and start again.

If the build fails early with a Docker Hub error such as `failed to resolve source metadata for docker.io/library/ubuntu:22.04` or `TLS handshake timeout`, the failure is happening before any Dockerfile step runs.

Useful recovery paths on the host:

```powershell
docker pull ubuntu:22.04
docker compose build local-codex-kit
```

```powershell
$env:LOCAL_CODEX_BASE_IMAGE='your-mirror-or-local-tag:22.04'
docker compose build local-codex-kit
```

The second option is intended for environments where you already have an internal mirror, a locally loaded tarball, or a differently tagged local copy of the Ubuntu base image.

## Files

- `Dockerfile`: builds the image, installs Codex, Ollama, PowerShell, and the extra Linux-native tooling, then pre-pulls the configured model set into the image
- `docker-compose.yml`: defines the offline hardened runtime, the Docker-managed state volumes, and the live host project bind mount at `/workspace/project`
- `docker-entrypoint.ps1`: starts Ollama, seeds the Codex OSS config, and opens the shell
- `docker-profile.ps1`: adds the `codex-local`, `codex-ollama`, and `ollama-local` convenience commands
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-ollama.ps1`: launches `ollama serve` with the configured context length and waits for readiness
- `import-workspace.ps1`: copies a host folder into the Docker-managed workspace volume through a temporary container
