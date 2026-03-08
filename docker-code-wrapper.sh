#!/usr/bin/env bash

set -euo pipefail

CODE_BIN="/usr/bin/code"

if [[ ! -x "$CODE_BIN" ]]; then
    echo "VS Code launcher not found at $CODE_BIN" >&2
    exit 1
fi

# Docker Desktop on Windows exposes a Microsoft kernel string, which makes the
# stock launcher show the WSL-only prompt even inside this container.
export DONT_PROMPT_WSL_INSTALL=1

extra_args=()
needs_root_flags=0

if [[ "$(id -u)" == "0" ]]; then
    needs_root_flags=1
    for arg in "$@"; do
        case "$arg" in
            --user-data-dir|--user-data-dir=*|--file-write|tunnel|serve-web)
                needs_root_flags=0
                break
                ;;
        esac
    done

    if [[ "$needs_root_flags" == "1" ]]; then
        mkdir -p /tmp/local-codex-kit-vscode-root
        extra_args+=(--no-sandbox --user-data-dir /tmp/local-codex-kit-vscode-root)
    fi
fi

exec "$CODE_BIN" "${extra_args[@]}" "$@"
