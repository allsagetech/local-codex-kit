# Local Ollama Kit (Container-Only Ollama)

This repo packages Ollama into a single Docker runtime with the security boundary at the container:

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
3. run Ollama inside the container against `/workspace`

## What this repo does

- runs `ollama serve` inside the same container
- defaults to Ollama tag `gpt-oss:20b`
- stores the workspace and runtime state in Docker-managed volumes
- stores the Ollama model payload inside the image at `/opt/local-ollama-kit/ollama-models`
- keeps runtime network access disabled

`ollama-local` is the convenience entrypoint inside the container. It runs the default Ollama model selected for this image.

## Quick start

Build the image on the host:

```powershell
docker compose build local-ollama-kit
```

If Docker Hub is flaky in your environment, you can override the base image without editing the repo:

```powershell
$env:LOCAL_OLLAMA_BASE_IMAGE='your-mirror-or-local-tag:22.04'
docker compose build local-ollama-kit
```

Import a host project into the Docker workspace volume:

```powershell
.\import-workspace.ps1 -SourcePath C:\path\to\project -Destination /workspace/project
```

Start the container:

```powershell
docker compose run --rm local-ollama-kit
```

Inside the container:

```powershell
Set-Location /workspace/project
ollama list
ollama-local
```

Equivalent manual Ollama command inside the container:

```powershell
ollama run gpt-oss:20b
```

## Security model

This setup assumes the container is the trust boundary.

- project files live in a Docker volume mounted at `/workspace`
- Ollama runtime state lives in a Docker volume mounted at `/home/ollama/.ollama`
- Ollama model blobs are baked into the image at `/opt/local-ollama-kit/ollama-models`

## Workspace handling

The Compose service includes a live host project bind mount at `/workspace/project`.

By default, it binds `./host-project` from this repo. You can instead point it at any host project path by setting `LOCAL_OLLAMA_HOST_PROJECT_PATH` before starting the container:

```powershell
$env:LOCAL_OLLAMA_HOST_PROJECT_PATH='C:\path\to\your\project'
docker compose run --rm local-ollama-kit
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

Models are selected at image-build time through `LOCAL_OLLAMA_PULL_MODELS`.

Common examples:

```powershell
$env:LOCAL_OLLAMA_PULL_MODELS='gpt-oss:20b'
docker compose build local-ollama-kit
```

```powershell
$env:LOCAL_OLLAMA_PULL_MODELS='gpt-oss:20b,gpt-oss:120b'
docker compose build local-ollama-kit
```

Set `LOCAL_OLLAMA_PULL_MODELS=none` to skip build-time pulls entirely.

At runtime, Ollama reads models from the image-baked model store at `/opt/local-ollama-kit/ollama-models`. To change the available model set, rebuild the image.

To select a different baked model at runtime:

```powershell
$env:LOCAL_OLLAMA_MODEL_ALIAS='gpt-oss:120b'
docker compose run --rm local-ollama-kit
```

## Default behavior

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

- `LOCAL_OLLAMA_CONTEXT_LENGTH=65536`

To change it for the next container run:

```powershell
$env:LOCAL_OLLAMA_CONTEXT_LENGTH='131072'
docker compose run --rm local-ollama-kit
```

Make sure your hardware can support the larger context window.

## State

The default Compose service keeps the following Docker-managed volumes:

- `/workspace`
- `/home/ollama/.ollama`

The image also contains the baked model store at `/opt/local-ollama-kit/ollama-models`.

The service also includes one host bind mount at `/workspace/project`, which defaults to `./host-project` unless `LOCAL_OLLAMA_HOST_PROJECT_PATH` is set.

Rebuilding the image updates the launcher code and the baked model set without bind-mounting any host workspace into the container.

## Troubleshooting

If Ollama startup fails, the entrypoint prints log file paths from `/tmp/local-ollama-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
code --version
dpkg-query -W -f='${binary:Package} ${Version}\n' code
chromium --version
go version
python --version
helm version --short
zarf version
ollama list
Get-ChildItem /tmp/local-ollama-kit
Get-Content /tmp/local-ollama-kit/ollama.err.log -Tail 100
Get-Content /tmp/local-ollama-kit/ollama.out.log -Tail 100
```

If `ollama-local` reports that a model is missing, rebuild the image with `LOCAL_OLLAMA_PULL_MODELS` updated to include that model.

If you want to reset all Docker-managed state for this repo, remove the named volumes created by Compose and start again.

If the build fails early with a Docker Hub error such as `failed to resolve source metadata for docker.io/library/ubuntu:22.04` or `TLS handshake timeout`, the failure is happening before any Dockerfile step runs.

Useful recovery paths on the host:

```powershell
docker pull ubuntu:22.04
docker compose build local-ollama-kit
```

```powershell
$env:LOCAL_OLLAMA_BASE_IMAGE='your-mirror-or-local-tag:22.04'
docker compose build local-ollama-kit
```

The second option is intended for environments where you already have an internal mirror, a locally loaded tarball, or a differently tagged local copy of the Ubuntu base image.

## Files

- `Dockerfile`: builds the image, installs Ollama, PowerShell, and the extra Linux-native tooling, then pre-pulls the configured model set into the image
- `docker-compose.yml`: defines the offline hardened runtime, the Docker-managed state volumes, and the live host project bind mount at `/workspace/project`
- `docker-entrypoint.ps1`: starts Ollama and opens the shell
- `docker-profile.ps1`: adds the `ollama-local` convenience command
- `pull-ollama-models.ps1`: pulls the configured Ollama models during image build
- `start-ollama.ps1`: launches `ollama serve` with the configured context length and waits for readiness
- `import-workspace.ps1`: copies a host folder into the Docker-managed workspace volume through a temporary container
