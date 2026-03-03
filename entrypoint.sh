#!/usr/bin/env bash
# entrypoint.sh — runs inside the container at startup
set -euo pipefail

# ── Passthrough: if invoked as a non-claude command, exec it directly ─────────
# This handles persistent containers (sleep infinity) created by zed-claude-acp.sh
case "${1:-}" in
    sleep|/bin/sleep|bash|/bin/bash|sh|/bin/sh)
        exec "$@"
        ;;
esac

# ── 1. Copy ~/.claude config from host mount (essentials only) ────────────────
if [[ -d /mnt/in/claude_dir ]]; then
    echo "[entrypoint] Copying ~/.claude config (essentials only)..." >&2
    mkdir -p /home/sandbox/.claude

    # Top-level config files
    for f in settings.json CLAUDE.md claude-devtools-config.json; do
        [[ -f /mnt/in/claude_dir/$f ]] && cp -p "/mnt/in/claude_dir/$f" "/home/sandbox/.claude/$f"
    done

    # Essential directories
    for d in commands hooks skills plugins statsig; do
        [[ -d /mnt/in/claude_dir/$d ]] && cp -rp "/mnt/in/claude_dir/$d" "/home/sandbox/.claude/$d"
    done
fi

# ── 2. Copy .claude.json from host home ───────────────────────────────────────
if [[ -f /mnt/in/home/.claude.json ]]; then
    echo "[entrypoint] Copying .claude.json..." >&2
    cp /mnt/in/home/.claude.json /home/sandbox/.claude.json
fi

# ── 2.5 Write credentials file (Linux plaintext fallback for Keychain) ───────
if [[ -n "${CLAUDE_CREDS:-}" ]]; then
    echo "[entrypoint] Writing credentials file..." >&2
    echo "$CLAUDE_CREDS" > /home/sandbox/.claude/.credentials.json
    chmod 600 /home/sandbox/.claude/.credentials.json
fi

# ── 2.6 Copy SSH keys and git config from host ──────────────────────────────
if [[ -d /mnt/in/home/.ssh ]]; then
    echo "[entrypoint] Copying SSH keys..." >&2
    mkdir -p /home/sandbox/.ssh
    cp /mnt/in/home/.ssh/id_* /home/sandbox/.ssh/ 2>/dev/null || true
    cp /mnt/in/home/.ssh/config /home/sandbox/.ssh/ 2>/dev/null || true
    chmod 700 /home/sandbox/.ssh
    chmod 600 /home/sandbox/.ssh/* 2>/dev/null || true
    ssh-keyscan -T 5 -t ed25519 github.com >> /home/sandbox/.ssh/known_hosts 2>/dev/null || true
fi
if [[ -f /mnt/in/home/.gitconfig ]]; then
    echo "[entrypoint] Copying .gitconfig..." >&2
    cp /mnt/in/home/.gitconfig /home/sandbox/.gitconfig
fi

# ── 3. Copy workspace if in copy mode ────────────────────────────────────────
if [[ "${SANDBOX_COPY_MODE:-0}" == "1" ]]; then
    echo "[entrypoint] Copy mode: copying workspace (filtering build artifacts)..." >&2
    mkdir -p /workspace
    tar -C /mnt/in/workspace \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.DS_Store' \
        --exclude='.ruff_cache' \
        --exclude='.mypy_cache' \
        --exclude='.pytest_cache' \
        --exclude='.fastembed_cache' \
        --exclude='.vscode' \
        --exclude='.github' \
        --exclude='.codex' \
        --exclude='.codanna' \
        -cf - . | tar -C /workspace -xf -
fi

# ── 4. Generate CONTAINER.md ──────────────────────────────────────────────────
# Dynamic context file so Claude knows it's in a Linux container.
echo "[entrypoint] Generating CONTAINER.md..." >&2
cat > /workspace/CONTAINER.md << 'CONTAINERMD'
# Container Environment (auto-generated)

You are running inside a **Linux arm64** container (Debian bookworm), NOT macOS.
This is an isolated copy of the project — changes here do NOT affect the host.

## Available Tools

- git, gh (GitHub CLI), jq, ripgrep, fd, fzf, uv
- openssh-client (SSH keys are pre-configured for github.com)

## Python

If this is a Python project, the host `.venv/` was excluded (macOS binaries).
Create a fresh Linux virtual environment:

```bash
uv venv .venv && source .venv/bin/activate
uv pip install -r requirements.txt
```

## Anthropic API Environment

`ANTHROPIC_API_KEY` is set to an **empty string** in this container so that
Claude Code uses OAuth authentication. If your Python scripts call the
Anthropic SDK directly, the empty env var takes precedence over `.env` and
causes a `TypeError`.

**Fix:** use `load_dotenv(override=True)` so the real key from `.env` wins,
or pass `api_key=` explicitly to the `Anthropic()` client.

If `ANTHROPIC_BASE_URL` is set (e.g. to a proxy for Claude Code), Python scripts
that call the Anthropic API directly must reset it:

\`\`\`python
import os
os.environ.pop("ANTHROPIC_BASE_URL", None)   # remove proxy URL
\`\`\`

Or set `ANTHROPIC_BASE_URL=https://api.anthropic.com` in your `.env` alongside
the API key, and use `load_dotenv(override=True)` to restore both.

## Go

`go build` produces Linux arm64 binaries. This is an isolated container so there
are no cross-platform concerns — build normally.

## Build Artifacts

All compiled binaries and native extensions are Linux arm64.
This container is ephemeral — it is destroyed on exit.
CONTAINERMD

# ── 5. Change to workspace ──────────────────────────────────────────────────
echo "[entrypoint] Starting Claude Code in /workspace..." >&2
cd /workspace

# ── 6. Verify claude exists ───────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "[entrypoint] ERROR: claude not found in PATH" >&2
    exit 1
fi

# ── 7. Exec claude with any passed arguments ─────────────────────────────────
exec claude "$@"
