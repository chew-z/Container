# Running Hooks in Containers

A practical guide for running Claude Code hooks inside an Apple Container (or any Linux container) with the webhook server on the host.

## Why HTTP Hooks Matter for Containers

Command hooks run inside the container's Linux VM. They can't access macOS audio (`afplay`), host APIs, or services. HTTP hooks solve this by reaching the webhook server on the host:

```
┌─────────────────────────────┐     HTTP      ┌─────────────────────────────┐
│  Container (Linux VM)       │ ──────────────>│  Host (macOS)               │
│                             │               │                             │
│  Claude Code                │               │  Webhook Server :8765       │
│  ├─ HTTP hooks ─────────────│───────────────│──> TTS (ElevenLabs)         │
│  ├─ bash shims (curl) ──────│───────────────│──> AI Summaries             │
│  └─ MCP Talk tool ──────────│───────────────│──> Analytics                │
│                             │               │                             │
│  Local scripts run here     │               │  Audio plays here           │
└─────────────────────────────┘               └─────────────────────────────┘
```

## Prerequisites

- Apple Container (macOS 26+) or compatible container runtime
- Webhook server running on host (see [Quick Start](../README.md#quick-start))
- Claude Code installed in the container image

## Host Setup (One-Time)

### Webhook Server Running

```bash
# Verify it's running
curl http://localhost:8765/health

# If not running, deploy it
./deploy_hooks.py deploy-server
```

The server binds to `0.0.0.0` by default, making it reachable from containers via the Apple Container gateway IP (`192.168.64.1`). No DNS entries or `/etc/hosts` changes needed.

## Container Configuration

### Environment Variables

Set these two variables in the container environment — all URLs are derived from them:

| Variable | Value | Purpose |
|----------|-------|---------|
| `WEBHOOK_HOST` | `192.168.64.1` | Apple Container gateway IP (same as Postgres MCP) |
| `WEBHOOK_PORT` | `8765` | All hooks and shims target this port (default) |
| `HOOKS_WEBHOOK_TOKEN` | *(match host server)* | Bearer auth (only if enabled in `.env`) |

That's it. Both bash shims (`webhook_forward.sh`) and local Python scripts (`save_context_precompact.py`) derive their URLs from `WEBHOOK_HOST` + `WEBHOOK_PORT`. No separate URL variables needed.

**Claude Code limitation:** HTTP hook URLs in `settings.json` and `.mcp.json` don't support `$VAR` interpolation — they must contain literal URLs. Use `deploy_hooks.py` to generate them:

```bash
# Preview what URLs will be generated
WEBHOOK_HOST=192.168.64.1 ./deploy_hooks.py show-config

# Deploy with correct URLs to settings.json and .mcp.json
WEBHOOK_HOST=192.168.64.1 ./deploy_hooks.py deploy
```

### Files to Copy into the Container

**Global hooks** (`~/.claude/hooks/`):

```
notification_webhook.sh    # bash shim — uses WEBHOOK_HOST env var
session_end_webhook.sh     # bash shim — uses WEBHOOK_HOST env var
webhook_forward.sh         # shared forwarding logic for shims
```

**Project hooks** (`.claude/hooks/`):

```
skill-forced-eval.py               # runs locally in container
save_context_precompact.py          # runs locally, delegates AI via WEBHOOK_HOST
restore_context_postcompact.py      # runs locally in container
shared/                             # shared utilities (needed by local scripts)
```

### Generated Configs (via `deploy_hooks.py deploy`)

The deploy script generates `settings.json` and `.mcp.json` with literal URLs derived from `WEBHOOK_HOST` + `WEBHOOK_PORT`. Run deploy inside the container (or copy the generated files).

**Global Settings** (`~/.claude/settings.json` in container) — generated with correct host:

```json
{
  "hooks": {
    "Notification": [
      {
        "type": "command",
        "command": "$HOME/.claude/hooks/notification_webhook.sh"
      }
    ],
    "Stop": [
      {
        "type": "http",
        "url": "http://192.168.64.1:8765/hooks/stop",
        "timeout": 60
      }
    ],
    "SessionEnd": [
      {
        "type": "command",
        "command": "$HOME/.claude/hooks/session_end_webhook.sh"
      }
    ]
  }
}
```

Note: Stop uses native HTTP — the URL points directly to the host. Notification and SessionEnd use bash shims because they need to read the transcript file and embed its content in the request.

**Project Settings** (`.claude/settings.json` in container):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "type": "http",
        "url": "http://192.168.64.1:8765/hooks/prompt-analytics",
        "timeout": 10
      },
      {
        "type": "command",
        "command": "uv run --script .claude/hooks/skill-forced-eval.py"
      }
    ],
    "PreCompact": [
      {
        "type": "command",
        "command": "uv run --script .claude/hooks/save_context_precompact.py"
      }
    ],
    "SessionStart": [
      {
        "type": "command",
        "command": "uv run --script .claude/hooks/restore_context_postcompact.py",
        "matcher": "compact"
      }
    ]
  }
}
```

**MCP Talk Server** — register via CLI (safely merges into `.mcp.json`):

```bash
claude mcp add --transport http talk http://192.168.64.1:8765/mcp/ -s project
```

Claude Code connects to it via HTTP streamable transport. The `say` tool appears in Claude's tool list automatically.

## Example: container run Command

```bash
container run \
  --env WEBHOOK_HOST=192.168.64.1 \
  --env WEBHOOK_PORT=8765 \
  --volume "$HOME/.claude/hooks:$HOME/.claude/hooks:ro" \
  --volume "$PWD:/workspace" \
  my-claude-image
```

Or use an init script inside the container that writes the settings files on startup:

```bash
#!/bin/bash
set -euo pipefail

# Generate settings.json with correct URLs
# WEBHOOK_HOST and WEBHOOK_PORT are set in the container environment
cd /workspace && ./deploy_hooks.py deploy

# Register Talk MCP server (safely merges into .mcp.json)
WH="${WEBHOOK_HOST:-192.168.64.1}"
WP="${WEBHOOK_PORT:-8765}"
claude mcp add --transport http talk "http://${WH}:${WP}/mcp/" -s project

exec claude "$@"
```

## Verification

From inside the container:

```bash
# 1. Check host connectivity
curl http://192.168.64.1:8765/health
# Expected: {"status": "ok", ...}

# 2. Test notification shim
echo '{"notification":"Container test"}' | bash ~/.claude/hooks/notification_webhook.sh
# Expected: TTS audio plays on host

# 3. Test MCP endpoint
curl http://192.168.64.1:8765/mcp/
# Expected: connection accepted (SSE or upgrade response)
```

## What Works / What Doesn't

| Feature | In Container? | Why |
|---------|:---:|-----|
| TTS notifications | Yes | Via webhook server on host |
| AI summaries (Stop) | Yes | Via webhook server on host |
| Talk (MCP) | Yes | MCP over HTTP to host |
| Analytics logging | Yes | Via webhook server on host |
| Context save/restore | Yes | Local scripts + webhook for AI |
| Skill evaluation | Yes | Runs locally in container |
| Session end summary | Yes | Via webhook server on host |
| Direct audio (`afplay`) | No | macOS-only, not available in Linux VM |

## Troubleshooting

**"Connection refused" from container**
- Verify server is running: `curl http://localhost:8765/health` on the host
- Check the server binds to `0.0.0.0` (default), not just `127.0.0.1`
- Check `WEBHOOK_HOST` is set to `192.168.64.1` in the container

**No audio plays**
- Expected behavior — audio plays on the **host**, not in the container
- Check the host's webhook server logs for TTS errors

**MCP `say` tool not available in Claude**
- Verify `.mcp.json` exists in the project root with `192.168.64.1` URL
- Test the endpoint: `curl http://192.168.64.1:8765/mcp/`
- Restart Claude Code after adding/changing `.mcp.json`

**"Unauthorized" responses**
- If the host server has `HOOKS_WEBHOOK_TOKEN` set in `.env`, set the same value as `HOOKS_WEBHOOK_TOKEN` in the container environment

**Context save fails**
- Verify `WEBHOOK_HOST` is set correctly in the container environment
- The local script runs in the container but delegates AI summarization to the host
