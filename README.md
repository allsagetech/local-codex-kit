# Local Codex Kit

This folder is meant to be handed to someone as a working local Codex launcher.

## Fast handoff

Give them the `local-codex-kit` folder, then have them do these steps in PowerShell:

```powershell
cd D:\local-codex-kit
.\install.ps1
. $PROFILE
```

That installs Toolchain if needed, ensures the Toolchain `codex:latest` package is available, installs LM Studio desktop if needed, bootstraps the LM Studio CLI if needed, downloads the default models, and writes a managed `codex` function into their PowerShell profile that points at this kit.

Install a different default preset if needed:

```powershell
.\install.ps1 -Preset qwen
.\install.ps1 -Preset small
```

Skip the default model downloads if needed:

```powershell
.\install.ps1 -SkipModelDownload
```

Choose the model setup mode explicitly if needed:

```powershell
.\install.ps1 -ModelSetup default
.\install.ps1 -ModelSetup interactive
.\install.ps1 -ModelSetup skip
```

Preview the install without changing the machine:

```powershell
.\install.ps1 -DryRun
```

Remove the changes later if needed:

```powershell
.\delete.ps1
```

Preview the uninstall without removing anything:

```powershell
.\delete.ps1 -DryRun
```

Build the Docker image if you want a packaged CLI environment:

```powershell
docker build -t local-codex-kit .
docker compose run --rm local-codex-kit
```

Inside the container shell:

```powershell
codex
codex-qwen
codex-small
```

The container PowerShell profile maps `codex` to the local GPT OSS route and
`codex-qwen` / `codex-small` to the local Qwen routes.

If they want to do it manually instead, this is the exact profile snippet:

```powershell
function codex {
    D:\local-codex-kit\codex-here.ps1 -Preset local @args
}
```

Then from any repo:

```powershell
cd D:\some-repo
codex
```

## What they need installed

- Git in PATH
- LM Studio desktop will be installed by `.\install.ps1` if it is missing
- Toolchain will be installed by `.\install.ps1` if it is missing
- the Toolchain `codex:latest` package will be fetched by `.\install.ps1`
- the Toolchain `lmstudio:latest` package is used to bootstrap `lms` if needed
- the default model downloads are `openai/gpt-oss-20b` and `qwen2.5-coder-32b-instruct`
- the smaller model option is `qwen2.5-coder-7b-instruct`
- by default, `.\install.ps1` prompts for default downloads, interactive selection, or skip

## What `codex` does here

The default route is:

- preset: `local`
- mode: `local-balanced`
- Codex model slug: `gpt-oss-20b`
- LM Studio model: `openai/gpt-oss-20b`

Other options:

- `codex -Preset qwen`
- `codex -Preset small`

## Expected startup output

When it is working, startup should show all of these:

- `Selected model: Local GPT OSS 20B`
- `Codex model slug: gpt-oss-20b`
- `Codex sandbox: workspace-write`
- `LM Studio model: openai/gpt-oss-20b`
- `Toolchain: enabled`

Then the Codex TUI should open with:

- `model: gpt-oss-20b`

## Best way to share this

The fastest path is:

1. Give them the whole `D:\local-codex-kit` folder.
2. Tell them to run `.\install.ps1` or `.\install.ps1 -Preset qwen`.
3. For lower-memory machines, tell them to use `.\install.ps1 -Preset small`.
4. Tell them to run `. $PROFILE`.
5. Tell them to run `codex` inside a Git repo.

That is simpler than asking them to hand-edit their profile.

## Files that matter

- `codex-here.ps1`: entry point with `local`, `qwen`, and `small`
- `install.ps1`: installs Toolchain, ensures `codex:latest` is available, installs LM Studio if needed, bootstraps `lms`, downloads the default models, and sets the default preset
- `delete.ps1`: removes the managed profile block and can remove Toolchain, LM Studio, and downloaded models
- `start-codex.ps1`: prints launch info and starts Codex
- `codex-backend.ps1`: model routing, Git checks, and LM Studio integration
- `bootstrap-toolchain.ps1`: ensures Toolchain is installed
- `Dockerfile`: builds a PowerShell image with Git and Codex CLI for packaging the kit
- `docker-entrypoint.ps1`: starts an interactive container shell in the mounted workspace
- `docker-profile.ps1`: makes `codex`, `codex-qwen`, and `codex-small` use the local LM Studio-backed wrappers inside the container
- `docker-lmstudio-bridge.js`: forwards container-local `127.0.0.1:1234` traffic to host LM Studio
- `docker-compose.yml`: mounts the kit and a target workspace into the container

## Notes

- run `Remove-Item Function:\codex` if you want the stock Codex CLI in the current shell
- run `. $PROFILE` or open a new PowerShell window after changing your profile
- starting from a Git repo gives better repo-aware behavior
- `Codex sandbox: workspace-write` is the Codex CLI permission sandbox; the Docker image is only a packaging/container layer around the CLI

## License

- code in this repo is licensed under Apache-2.0; see `LICENSE`
- required attribution notices are in `NOTICE`
- AllSageTech, LLC is the copyright owner
- company branding usage is described in `TRADEMARKS.md`
