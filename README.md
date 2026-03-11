# Local Codex Kit (Container-Only Codex + Official gpt-oss Weights)

This repo packages Codex and a local `transformers serve` runtime into a single Docker environment with the security boundary at the container:

- no host bind mount onto `/workspace` itself
- runtime networking disabled with `network_mode: "none"`
- non-root runtime user
- read-only root filesystem
- tmpfs-backed `/tmp`
- `no-new-privileges`
- all Linux capabilities dropped

The current runtime path is based on official OpenAI `gpt-oss` weights pulled as Toolchain packages, not a GGUF conversion.

## What this repo does

- installs the OpenAI `codex` CLI in the image
- installs the `Toolchain` PowerShell module in the image
- installs `transformers[serving]`
- pulls the configured official Toolchain model package during the image build
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

If you want Docker GPU passthrough on Compose builds that do not accept `run --gpus ...`, add the GPU override file:

```powershell
docker compose -f docker-compose.yml -f docker-compose.gpu.yml run --rm local-codex-kit
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

The entrypoint writes a managed custom provider config that points Codex at the embedded OpenAI-compatible endpoint and uses the Responses API expected by current Codex CLI builds. It does not rely on the built-in `--oss` provider, which is reserved for LM Studio/Ollama.

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

By default, `openai/gpt-oss-20b` maps to the Toolchain package ref `openai-gpt-oss-20b:1.0.0`.

If you need to override the package mapping, set this before the build:

```powershell
$env:LOCAL_CODEX_TOOLCHAIN_PACKAGE_GPT_OSS_20B='openai-gpt-oss-20b:1.0.0'
docker compose build local-codex-kit
```

If the Toolchain registry requires authentication, set credentials before the build:

```powershell
$env:TOOLCHAIN_TOKEN='...'
docker compose build local-codex-kit
```

`Toolchain` also supports `TOOLCHAIN_USERNAME` and `TOOLCHAIN_PASSWORD`.

Set `LOCAL_CODEX_OFFICIAL_PULL_MODELS=none` to skip build-time downloads entirely.

At runtime, `transformers serve` is pointed at the pulled Toolchain package content baked into the image. To change the available model set, rebuild the image.

If you need to override the Codex model name explicitly, set `LOCAL_CODEX_CODEX_MODEL` to the official model id, for example `openai/gpt-oss-20b`.

## Runtime

The embedded server is `transformers serve`, which exposes an OpenAI-compatible API.

Default runtime settings:

- `LOCAL_CODEX_TRANSFORMERS_PORT=8000`
- `LOCAL_CODEX_TRANSFORMERS_DEVICE=auto`
- `LOCAL_CODEX_TRANSFORMERS_DTYPE=auto`
- `LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING=0`
- `LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK=0`

Optional tuning:

```powershell
$env:LOCAL_CODEX_TRANSFORMERS_DTYPE='float16'
$env:LOCAL_CODEX_TRANSFORMERS_DEVICE='cuda'
$env:LOCAL_CODEX_TRANSFORMERS_CONTINUOUS_BATCHING='1'
$env:LOCAL_CODEX_TRANSFORMERS_ATTN_IMPLEMENTATION='sdpa'
docker compose -f docker-compose.yml -f docker-compose.gpu.yml run --rm local-codex-kit
```

This path is more faithful to the official weights, but it is also heavier than the GGUF/Ollama path. You should expect stronger hardware requirements.

On CPU-only hosts, the default `auto` device selection is disabled up front for the bundled MXFP4 `gpt-oss-20b` weights because current `transformers serve` falls over during auto offload. If you want to try a CPU run anyway, opt in explicitly:

```powershell
$env:LOCAL_CODEX_TRANSFORMERS_DEVICE='cpu'
$env:LOCAL_CODEX_TRANSFORMERS_ALLOW_CPU_FALLBACK='1'
docker compose run --rm local-codex-kit
```

## State

The default Compose service keeps the following Docker-managed volumes:

- `/workspace`
- `/home/codex/.codex`
- `/home/codex/.cache`

The service also includes one host bind mount at `/workspace/project`, which defaults to `./host-project` unless `LOCAL_CODEX_HOST_PROJECT_PATH` is set.

## Troubleshooting

If the Transformers server fails to start, the entrypoint prints log file paths from `/tmp/local-codex-kit` before dropping you into the shell.

If `codex-local` refuses to start, it now means the embedded runtime is disabled or unreachable; fix the startup warning first instead of retrying the Codex CLI against a dead local endpoint.

Useful checks inside the container:

```powershell
codex --version
transformers --help
python -c "import transformers; print(transformers.__version__)"
python -c "import torch; print(torch.__version__)"
Get-Content /opt/local-codex-kit/official-models.manifest.json
Get-ChildItem /tmp/local-codex-kit
Get-Content /tmp/local-codex-kit/transformers.err.log -Tail 100
Get-Content /tmp/local-codex-kit/transformers.out.log -Tail 100
```

If `codex-local` reports that a model is missing, rebuild the image with `LOCAL_CODEX_OFFICIAL_PULL_MODELS` updated to include that model.

## Files

- `Dockerfile`: builds the image, installs Codex, Toolchain, and Transformers serving dependencies, then pulls the configured official model package into the image
- `docker-compose.yml`: defines the offline hardened runtime, the Docker-managed state volumes, and the live host project bind mount at `/workspace/project`
- `docker-entrypoint.ps1`: starts `transformers serve`, seeds the Codex OSS config, and opens the shell
- `docker-profile.ps1`: adds the `codex-local`, `codex-official`, and `transformers-local` convenience commands
- `official-models.ps1`: shared official model alias and manifest helpers
- `pull-official-models.ps1`: pulls the configured official model packages via Toolchain during image build
- `start-transformers-server.ps1`: launches `transformers serve` and waits for readiness
- `import-workspace.ps1`: copies a host folder into the Docker-managed workspace volume through a temporary container
