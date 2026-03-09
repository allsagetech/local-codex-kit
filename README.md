# Local Codex Kit (Container-Only Codex + Official gpt-oss Weights)

This repo packages Codex and a local `transformers serve` runtime into a single Docker environment with the security boundary at the container:

- no host bind mount onto `/workspace` itself
- runtime networking disabled with `network_mode: "none"`
- non-root runtime user
- read-only root filesystem
- tmpfs-backed `/tmp`
- `no-new-privileges`
- all Linux capabilities dropped

The current runtime path is based on the official OpenAI `gpt-oss` weights from Hugging Face, not a GGUF conversion.

## What this repo does

- installs the OpenAI `codex` CLI in the image
- installs Hugging Face `transformers[serving]`
- downloads the official Hugging Face model weights during the image build
- seeds those weights into a writable Hugging Face cache at container startup
- runs `transformers serve` inside the same container
- keeps runtime network access disabled

`codex-local` is the convenience entrypoint inside the container. It points Codex at the embedded OpenAI-compatible server and applies the container-safe defaults for this repo.

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
codex -m openai/gpt-oss-20b
```

To chat against the embedded server directly:

```powershell
transformers-local
```

## Model handling

Official models are selected at image-build time through `LOCAL_CODEX_OFFICIAL_PULL_MODELS`.

Default:

```powershell
$env:LOCAL_CODEX_OFFICIAL_PULL_MODELS='openai/gpt-oss-20b'
docker compose build local-codex-kit
```

Accepted aliases:

- `openai/gpt-oss-20b`
- `gpt-oss-20b`
- `gpt-oss:20b`
- `openai/gpt-oss-120b`
- `gpt-oss-120b`
- `gpt-oss:120b`

If the download step needs authentication or your connection is slow, set these before the build:

```powershell
$env:HF_TOKEN='hf_...'
$env:HF_HUB_DOWNLOAD_TIMEOUT='300'
docker compose build local-codex-kit
```

Set `LOCAL_CODEX_OFFICIAL_PULL_MODELS=none` to skip build-time downloads entirely.

At runtime, the image-seeded Hugging Face cache is copied into the writable cache volume at `/home/codex/.cache/huggingface` before the server starts. To change the available model set, rebuild the image.

To select a different baked model at runtime:

```powershell
$env:LOCAL_CODEX_OFFICIAL_MODEL_ALIAS='openai/gpt-oss-120b'
docker compose run --rm local-codex-kit
```

If you need to override the Codex model name explicitly, set `LOCAL_CODEX_CODEX_MODEL` to the official model id, for example `openai/gpt-oss-20b`.

## Runtime

The embedded server is `transformers serve`, which exposes an OpenAI-compatible API.

Default runtime settings:

- `LOCAL_CODEX_TRANSFORMERS_PORT=8000`
- `LOCAL_CODEX_TRANSFORMERS_DTYPE=auto`
- `LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING=0`

Optional tuning:

```powershell
$env:LOCAL_CODEX_TRANSFORMERS_DTYPE='float16'
$env:LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING='1'
$env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION='sdpa'
docker compose run --rm local-codex-kit
```

This path is more faithful to the official weights, but it is also heavier than the GGUF/Ollama path. You should expect stronger hardware requirements.

## State

The default Compose service keeps the following Docker-managed volumes:

- `/workspace`
- `/home/codex/.codex`
- `/home/codex/.cache/huggingface`

The service also includes one host bind mount at `/workspace/project`, which defaults to `./host-project` unless `LOCAL_CODEX_HOST_PROJECT_PATH` is set.

## Troubleshooting

If the Transformers server fails to start, the entrypoint prints log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

Useful checks inside the container:

```powershell
codex --version
transformers --help
python -c "import transformers; print(transformers.__version__)"
python -c "import torch; print(torch.__version__)"
huggingface-cli whoami
Get-Content /opt/local-codex-kit/official-models.manifest.json
Get-ChildItem /tmp/local-codex-kit
Get-Content /tmp/local-codex-kit/transformers.err.log -Tail 100
Get-Content /tmp/local-codex-kit/transformers.out.log -Tail 100
```

If `codex-local` reports that a model is missing, rebuild the image with `LOCAL_CODEX_OFFICIAL_PULL_MODELS` updated to include that model.

## Files

- `Dockerfile`: builds the image, installs Codex and Transformers serving dependencies, then pre-downloads the configured official model set into a Hugging Face cache seed
- `docker-compose.yml`: defines the offline hardened runtime, the Docker-managed state volumes, and the live host project bind mount at `/workspace/project`
- `docker-entrypoint.ps1`: starts `transformers serve`, seeds the Codex OSS config, and opens the shell
- `docker-profile.ps1`: adds the `codex-local`, `codex-official`, and `transformers-local` convenience commands
- `official-models.ps1`: shared official model alias and manifest helpers
- `pull-official-models.ps1`: downloads the configured official models during image build
- `start-transformers-server.ps1`: launches `transformers serve` and waits for readiness
- `import-workspace.ps1`: copies a host folder into the Docker-managed workspace volume through a temporary container
