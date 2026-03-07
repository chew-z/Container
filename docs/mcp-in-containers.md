# MCP in Containers

MCP servers connect to containers via HTTP transport — no binaries baked into images, no Dockerfile changes.

## Architecture

```
Host Mac                              Container (Linux arm64)
┌─────────────────────────────┐       ┌──────────────────────────────┐
│                             │       │  entrypoint.sh               │
│  macOS Keychain             │       │    └── claude mcp add        │
│    mcp:<name> → token       │       │        --transport http      │
│                             │       │                              │
│  postgres-mcp               │       │  Claude Code                 │
│    -t http -port 8090       │◀──────│    ├── http → remote servers │
│    -ip 0.0.0.0              │  HTTP │    │     (HTTPS + token)     │
│                             │       │    └── http → postgres       │
└─────────────────────────────┘       └──────────────────────────────┘
         │                                     │
         ▼                                     │ via 192.168.64.1
    PostgreSQL                                 │ (gateway)
                                               │
    Remote MCP host ◀──────────────────────────┘
      /<server>/mcp/                     via HTTPS + bearer token
```

## How MCP Registration Works

The host's `.mcp.json` is **not** copied into the container — it contains macOS-specific stdio paths that won't work in Linux. Instead, `entrypoint.sh` starts with a clean slate:

1. Writes an empty `.mcp.json` to `/workspace/` (`{"mcpServers": {}}`)
2. Re-registers each configured server via `claude mcp add -s project`
3. This writes project-scoped entries into the fresh `.mcp.json`

**Global MCP servers** (configured in `~/.claude.json` or `settings.json`) are unaffected — Claude loads those separately. Only project-scoped servers (`.mcp.json`) are rebuilt.

In copy mode, the generated `.mcp.json` is ephemeral — destroyed with the container. In `--rw` mode it's written to the host project directory, so add `.mcp.json` to `.gitignore`.

## Two Types of MCP Connections

### 1. Remote HTTP Servers (`[mcp]` config)

MCP servers accessible over HTTP. The container connects via HTTPS with bearer token auth.

**Config:** `container-run.toml`

```toml
[mcp]
enabled = true
base_url = "https://example.com"
servers = [
    "pushover /pushover/mcp/ mcp:pushover",
    "gemini /gemini/mcp/ mcp:gemini",
    "time /time/mcp/ mcp:time",
    "answer /answer/mcp/ mcp:gemini"
]
```

**Token flow:**

1. `launch.sh` reads each server's keychain-service name
2. Looks up token from macOS Keychain (`security find-generic-password -s "mcp:pushover"`)
3. Falls back to env var (`MCP_TOKEN_PUSHOVER`)
4. Passes tokens into container as `MCP_TOKENS` env var
5. `entrypoint.sh` runs `claude mcp add --transport http --header "Authorization: Bearer $token"`

### 2. Host-Side Postgres (`[postgres]` config)

A Postgres MCP server running on the host Mac, reachable from the container through the Apple Container gateway IP (`192.168.64.1`).

**Host setup:**

```bash
postgres-mcp -t http -port 8090 -ip 0.0.0.0 -dsn "postgresql://user:pass@localhost:5432/dbname" --read-only
```

**Config:** `container-run.toml`

```toml
[postgres]
enabled = true
url = "http://192.168.64.1:8090/mcp"
```

No auth needed — local-only access via container gateway, MCP server enforces read-only.

## Server Naming

Use the same server names as on the host (`pushover`, not `pushover-remote`). This isn't a technical requirement — it's a convenience. Claude derives tool namespaces from the server name: `pushover` produces `mcp__pushover__send_notification`, while `pushover-remote` would produce `mcp__pushover-remote__send_notification`.

If your host's `settings.local.json` already pre-approves tools like `mcp__pushover__*`, matching names means those approvals carry over into the container. Otherwise you'd be prompted to approve every MCP tool on each container run.

## Files Involved

| File                 | Role                                                                  |
| -------------------- | --------------------------------------------------------------------- |
| `container-run.toml` | `[mcp]` and `[postgres]` configuration                                |
| `launch.sh`          | Reads config, resolves tokens from Keychain, passes env vars          |
| `entrypoint.sh`      | Registers servers via `claude mcp add`, bridges `settings.local.json` |

## Verification

1. Set tokens in Keychain, enable `[mcp]` in `container-run.toml`
2. Launch container — watch for `[entrypoint] OK: pushover` etc.
3. Inside container: ask Claude "What MCP tools do you have?"
4. Test: send a pushover notification, use gemini search

## Future

- **Codex MCP** — if Codex CLI is baked into the image, register via stdio: `claude mcp add codex -- codex mcp-server`
- **In-container binaries** — any MCP server with a small Go/Rust binary (~10-35MB) could be baked into the image and run via stdio transport for lower latency or offline use.
