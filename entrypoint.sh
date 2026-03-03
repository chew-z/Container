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

# ── 1. Copy ~/.claude config from host mount ──────────────────────────────────
if [[ -d /mnt/in/claude_dir ]]; then
    echo "[entrypoint] Copying ~/.claude config..." >&2
    mkdir -p /home/sandbox/.claude
    cp -rp /mnt/in/claude_dir/. /home/sandbox/.claude/
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

# ── 3. Copy workspace if in copy mode ────────────────────────────────────────
if [[ "${SANDBOX_COPY_MODE:-0}" == "1" ]]; then
    echo "[entrypoint] Copy mode: copying workspace..." >&2
    mkdir -p /workspace
    cp -rp /mnt/in/workspace/. /workspace/
fi

# ── 4. Change to workspace ────────────────────────────────────────────────────
echo "[entrypoint] Starting Claude Code in /workspace..." >&2
cd /workspace

# ── 5. Verify claude exists ───────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "[entrypoint] ERROR: claude not found in PATH" >&2
    exit 1
fi

# ── 6. Exec claude with any passed arguments ─────────────────────────────────
exec claude "$@"
