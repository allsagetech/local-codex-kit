# Local Codex Kit (Container-Only Codex + llama.cpp)

This repo packages Codex and `llama.cpp` into a single Docker runtime with the security boundary at the container:

- no host bind mount onto `/workspace` itself
- runtime networking disabled with `network_mode: "none"`
- non-root runtime user
- read-only root filesystem
- tmpfs-backed `/tmp`
- `no-new-privileges`
- all Linux capabilities dropped

The intended workflow is:

1. build the image with the GGUF model set you want baked in
2. import code into the Docker-managed workspace volume
3. run Codex inside the container against `/workspace`

## What this repo does

- installs the OpenAI `codex` CLI in the image
- builds `llama.cpp` tools in the image
- runs `llama-server` inside the same container
- defaults to the Unsloth GGUF repo for `gpt-oss-20b`
- stores the workspace and runtime state in Docker-managed volumes
- stores the baked GGUF payload inside the image at `/opt/local-codex-kit/llama-models`
- keeps runtime network access disabled

`codex-local` is the convenience entrypoint inside the container. It points Codex at the embedded `llama.cpp` OpenAI-compatible endpoint and applies the container-safe defaults for this repo.

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
codex-local
```

Equivalent manual Codex command inside the container after the entrypoint writes config:

```powershell
codex -m gpt-oss-20b
```

To run the baked model directly:

```powershell
llama-local
```

## Security model

This setup assumes the container is the trust boundary.

- project files live in a Docker volume mounted at `/workspace`
- Codex state lives in a Docker volume mounted at `/home/codex/.codex`
- model files are baked into the image at `/opt/local-codex-kit/llama-models`

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

## Model handling

Models are selected at image-build time through `LOCAL_CODEX_LLAMACPP_PULL_MODELS`.

The default value is:

```powershell
$env:LOCAL_CODEX_LLAMACPP_PULL_MODELS='gpt-oss-20b'
```

For OpenAI's current `gpt-oss` models, the helper script maps the aliases below to the `unsloth` GGUF repos that `llama.cpp` can serve:

- `gpt-oss-20b`
- `gpt-oss:20b`
- `openai/gpt-oss-20b`
- `gpt-oss-120b`
- `gpt-oss:120b`
- `openai/gpt-oss-120b`

By default the build pulls a single lighter-weight `Q4_K_M` quant instead of every GGUF variant.

You can also provide a direct Hugging Face GGUF repo id, for example:

```powershell
$env:LOCAL_CODEX_LLAMACPP_PULL_MODELS='unsloth/gpt-oss-20b-GGUF'
docker compose build local-codex-kit
```

If you want a different GGUF file pattern, override it before the build:

```powershell
$env:LOCAL_CODEX_LLAMACPP_GGUF_INCLUDE='gpt-oss-20b-Q8_0.gguf'
docker compose build local-codex-kit
```

Set `LOCAL_CODEX_LLAMACPP_PULL_MODELS=none` to skip build-time downloads entirely.

At runtime, `llama-server` reads models from the image-baked model store at `/opt/local-codex-kit/llama-models`. To change the available model set, rebuild the image.

To select a different baked model at runtime:

```powershell
$env:LOCAL_CODEX_LLAMACPP_MODEL_ALIAS='gpt-oss-120b'
docker compose run --rm local-codex-kit
```

If you need to override the Codex model name explicitly, set `LOCAL_CODEX_CODEX_MODEL` to the served alias, for example `gpt-oss-20b`.

## Default behavior

- `codex-local`: runs Codex against the embedded `llama.cpp` endpoint and repo defaults
- `codex`: works directly once the entrypoint has written the managed `~/.codex/config.toml`
- `llama-local`: runs the baked model directly with `llama-cli`

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
- `llama-cli`, `llama-server`, `llama-bench`

`code .` inside this headless container does not open your Windows desktop VS Code.

## Runtime tuning

The defaults are intentionally conservative so `llama.cpp` stays lighter on CPU/RAM:

- `LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH=65536`
- `LOCAL_CODEX_LLAMACPP_BATCH_SIZE=512`
- `LOCAL_CODEX_LLAMACPP_UBATCH_SIZE=512`
- `LOCAL_CODEX_LLAMACPP_GPU_LAYERS=0`

You can override them for the next container run:

```powershell
$env:LOCAL_CODEX_LLAMACPP_CONTEXT_LENGTH='32768'
$env:LOCAL_CODEX_LLAMACPP_BATCH_SIZE='256'
$env:LOCAL_CODEX_LLAMACPP_UBATCH_SIZE='256'
docker compose run --rm local-codex-kit
```

If you do have a GPU-enabled container runtime, you can offload layers:

```powershell
$env:LOCAL_CODEX_LLAMACPP_GPU_LAYERS='999'
docker compose run --rm local-codex-kit
```

## State

The default Compose service keeps the following Docker-managed volumes:

- `/workspace`
- `/home/codex/.codex`

The image also contains the baked model store at `/opt/local-codex-kit/llama-models`.

The service also includes one host bind mount at `/workspace/project`, which defaults to `./host-project` unless `LOCAL_CODEX_HOST_PROJECT_PATH` is set.

## Troubleshooting

If `llama.cpp` startup fails, the entrypoint prints log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
codex --version
llama-server --version
llama-cli --version
code --version
chromium --version
go version
python --version
helm version --short
zarf version
Get-Content /opt/local-codex-kit/llama-models/manifest.json
Get-ChildItem /tmp/local-codex-kit
Get-Content /tmp/local-codex-kit/llama.err.log -Tail 100
Get-Content /tmp/local-codex-kit/llama.out.log -Tail 100
```

If `codex-local` reports that a model is missing, rebuild the image with `LOCAL_CODEX_LLAMACPP_PULL_MODELS` updated to include that model.

If the build fails while downloading model weights, the failure is usually in the Hugging Face fetch step. In that case, either rebuild later, provide a different GGUF repo id, or set `HF_TOKEN` for private or gated model access before the build.

## Files

- `Dockerfile`: builds the image, installs Codex and `llama.cpp`, then pre-downloads the configured GGUF model set into the image
- `docker-compose.yml`: defines the offline hardened runtime, the Docker-managed state volumes, and the live host project bind mount at `/workspace/project`
- `docker-entrypoint.ps1`: starts `llama-server`, seeds the Codex OSS config, and opens the shell
- `docker-profile.ps1`: adds the `codex-local`, `codex-llama`, and `llama-local` convenience commands
- `llama-models.ps1`: shared model alias and manifest helpers
- `pull-llama-models.ps1`: downloads the configured GGUF models during image build
- `start-llama-server.ps1`: launches `llama-server` and waits for readiness
- `import-workspace.ps1`: copies a host folder into the Docker-managed workspace volume through a temporary container
