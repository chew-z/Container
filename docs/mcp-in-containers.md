# MCP in Containers — Revised Plan (Remote HTTP Only)

> **Action**: Save this plan to `docs/mcp-in-containers.md` (replacing the old version).

## Context

The original plan proposed a complex hybrid of in-container stdio servers (Approach A) + host HTTP servers (Approach B). However, the MCP servers we need (time, pushover, gemini) are **already running with HTTP transport** on `karma.rrj.pl`. This makes Approach C (remote HTTPS) the primary strategy — no Dockerfile changes, no binary installation, no host-side helper scripts.

**What changed**: Instead of installing MCP server binaries inside the container, we connect to existing remote HTTP endpoints. The `.mcp.json` from the host is NOT copied (it has broken macOS stdio paths). Instead, the entrypoint runs `claude mcp add` to register remote servers.

## Architecture

```
┌──────────────────────────────────────────┐
│  Linux Container                         │
│                                          │
│  entrypoint.sh                              │
│    └── claude mcp add --transport http      │
│        ├── pushover  (configurable)         │
│        ├── gemini    (configurable)         │
│        └── time      (optional)             │
│                                              │
│  Claude Code                                 │
│    ├── http ──▶ ${base_url}/pushover/mcp/   │
│    ├── http ──▶ ${base_url}/gemini/mcp/     │
│    ├── http ──▶ ${base_url}/time/mcp/       │
│    ├── http ──▶ ${base_url}/answer/mcp/ (future A)│
│    ├── stdio ──▶ answer mcp -t stdio    (future B)│
│    ├── stdio ──▶ postgres-mcp           (future) │
│    └── stdio ──▶ codex mcp-server       (future) │
└──────────────────────────────────────────┘
```

## Implementation

### 1. Config: `container-run.toml` + `container-run.example.toml`

Add `[mcp]` section. Uses `toml_get` for scalars and `toml_get_array` for the server list (both already exist).

```toml
[mcp]
# Enable MCP servers in the container (requires claude_simple_mode = false).
enabled = false

# Base URL for remote MCP servers (shared across all entries).
# Auth token comes from MCP_AUTH_TOKEN env var on the host.
base_url = "https://karma.rrj.pl"

# Remote MCP servers to register via `claude mcp add --transport http`.
# Format: "name path" pairs. Full URL = base_url + path.
# IMPORTANT: Server names MUST match host names (no "-remote" suffix!) so that
# existing permissions in .claude/settings.local.json are honored inside the container.
# e.g. "pushover" → mcp__pushover__send_notification (matches host permission rules)
# The list is user-configurable — comment out servers you don't need.
servers = [
    "pushover /pushover/mcp/",
    "gemini /gemini/mcp/",
    # "time /time/mcp/",       # optional — only provides current time
]
```

### 2. Auth token: `launch.sh`

Read `MCP_AUTH_TOKEN` from the host environment and pass it into the container.

In `launch.sh` (after reading `[mcp]` config):
- Check `mcp.enabled` is true AND `claude_simple_mode` is false
- Read `MCP_AUTH_TOKEN` from host env (user sets in shell profile / `.envrc`)
- Read `mcp.base_url` and `mcp.servers` from TOML
- Warn if MCP is enabled but token is missing
- Pass as `-e MCP_AUTH_TOKEN=...`, `-e MCP_BASE_URL=...`, `-e MCP_SERVERS=...` to the container

**Files**: `launch.sh`

### 3. Bridge `settings.local.json`: `entrypoint.sh`

Currently entrypoint copies `settings.json` and `CLAUDE.md` but **not** `settings.local.json`. This file contains:
- **`permissions.allow`**: pre-approved MCP tool calls (e.g., `mcp__pushover__send_notification`)
- **`enabledMcpjsonServers`**: servers auto-enabled from `.mcp.json` (e.g., `"pushover"`, `"gemini"`)

Without it, Claude inside the container will prompt the user to approve every MCP tool call and every server.

**Fix** (line 25 of `entrypoint.sh`):
```bash
# Before:
for f in settings.json CLAUDE.md; do
# After:
for f in settings.json settings.local.json CLAUDE.md; do
```

**Files**: `entrypoint.sh`

### 4. Server registration: `entrypoint.sh`

Add step between workspace copy (step 3) and CONTAINER.md generation (step 5):

```bash
# ── 3.5 Register MCP servers ─────────────────────────────────────────────
if [[ -n "${MCP_SERVERS:-}" && -n "${MCP_AUTH_TOKEN:-}" && -n "${MCP_BASE_URL:-}" ]]; then
    echo "[entrypoint] Registering MCP servers..." >&2
    while IFS= read -r _entry; do
        [[ -z "$_entry" ]] && continue
        _name="${_entry%% *}"
        _path="${_entry#* }"
        claude mcp add --transport http "$_name" "${MCP_BASE_URL}${_path}" \
            --header "Authorization: Bearer ${MCP_AUTH_TOKEN}" \
            -s project
    done <<< "$MCP_SERVERS"
fi
```

Uses `-s project` scope — writes `.mcp.json` to `/workspace/` inside the container. In copy mode this is ephemeral. In rw mode, `.mcp.json` should be in the project's `.gitignore`.

**Files**: `entrypoint.sh`

### 5. CONTAINER.md templates

Add conditional MCP section using existing template engine:

```
<if HAS_MCP>
## MCP Servers

Remote MCP servers are registered via HTTP transport:
{{MCP_SERVER_LIST}}

These servers are configured automatically. Use their tools normally.
</if>
```

Set `HAS_MCP=true` and `MCP_SERVER_LIST` (formatted list of server names) in entrypoint before template rendering.

**Files**: `templates/CONTAINER.python.md.tmpl`, `templates/CONTAINER.golang.md.tmpl`, `entrypoint.sh`

### 6. Documentation: `docs/mcp-in-containers.md`

Update the existing doc to reflect the simplified approach. Keep the transport analysis and strategy sections, replace the 6-phase implementation with the actual (simpler) approach.

**Files**: `docs/mcp-in-containers.md`

## Server Naming: No "-remote" suffix

Server names in the container MUST match the host names exactly (`pushover`, `gemini`, `time` — not `pushover-remote`, etc.). This is critical because:

1. **Permission matching**: `.claude/settings.local.json` defines permissions like `mcp__pushover__send_notification`. Claude derives the tool namespace from the server name. If the server is named `pushover-remote`, the tool becomes `mcp__pushover-remote__send_notification` — which doesn't match the existing permission rule.

2. **Transparent bridging**: From Claude's perspective inside the container, the MCP servers should look identical to the host. Same names, same tools, same permissions.

3. **`enabledMcpjsonServers`**: The host's `settings.local.json` lists enabled servers by name. Using matching names means these settings carry over when copied into the container.

## Auth Token Handling

The `MCP_AUTH_TOKEN` env var is set on the host and passed into the container — same pattern as `GH_TOKEN` (read from Keychain) and `CLAUDE_CREDS`. Options for where the user stores it:

1. **Shell profile** (`~/.zshrc`): `export MCP_AUTH_TOKEN="eyJ..."`
2. **direnv** (`.envrc`): project-scoped, not committed
3. **macOS Keychain**: most secure, like `GH_TOKEN` — would need a `security find-generic-password` call in `launch.sh`

**Decision**: Host env var. User sets `export MCP_AUTH_TOKEN="eyJ..."` in `~/.zshrc` or `.envrc`. `launch.sh` reads it directly — same pattern as `ANTHROPIC_API_KEY`.

## Files Changed

| File | Change |
|------|--------|
| `container-run.toml` | Add `[mcp]` section |
| `container-run.example.toml` | Add documented `[mcp]` section |
| `launch.sh` | Read `[mcp]` config, pass `MCP_AUTH_TOKEN` + `MCP_BASE_URL` + `MCP_SERVERS` env vars |
| `entrypoint.sh` | Bridge `settings.local.json` + add step 3.5: `claude mcp add` loop |
| `templates/CONTAINER.python.md.tmpl` | Add `<if HAS_MCP>` section |
| `templates/CONTAINER.golang.md.tmpl` | Add `<if HAS_MCP>` section |
| `docs/mcp-in-containers.md` | Update to reflect simplified approach |

## What's NOT needed anymore

- ~~Phase 4: Dockerfile changes / MCP binary installation~~
- ~~Phase 6: `mcp-host.sh` helper script~~
- ~~Complex `[[mcp.builtin]]` TOML array-of-tables parsing~~
- ~~`container-build.toml` changes~~ (revisit if/when Codex is added)

## Verification

1. Set `MCP_AUTH_TOKEN` in host env, set `mcp.enabled = true` + `claude_simple_mode = false` in `container-run.toml`
2. Launch container, verify Claude sees MCP tools (`What tools do you have?`)
3. Test: ask Claude to send a pushover notification or use gemini search
4. Verify copy mode: `.mcp.json` doesn't leak back to host
5. Verify rw mode: `.mcp.json` doesn't overwrite host files

## Future: Answer MCP (GPT web search)

**Not in scope for initial implementation** — two alternative approaches documented for future.

Answer is a custom Go project (`/Users/rrj/Projekty/Go/src/Answer`) that provides GPT-powered web search via MCP. Binary is ~10MB, pure Go, supports both stdio and HTTP transport.

Host config: `answer mcp --transport stdio` with `OPENAI_API_KEY` env var.

### Option A: Deploy on karma as HTTP (preferred — matches existing pattern)

Deploy the Answer binary on `karma.rrj.pl` behind nginx, same as time/pushover/gemini. Then it becomes just another entry in the `[mcp]` servers list:

```toml
servers = [
    "pushover /pushover/mcp/",
    "gemini /gemini/mcp/",
    "answer /answer/mcp/",           # ← add this
    # "time /time/mcp/",             # optional
]
```

**What's needed on karma:**
- Cross-compile: `GOOS=linux GOARCH=arm64 go build -o answer-linux` (from Answer project)
- Deploy binary, systemd service, nginx route `/answer/mcp/`
- Set `OPENAI_API_KEY` in systemd environment
- Same JWT auth as other MCP servers

**Container changes**: Zero — just add the server entry to `container-run.toml`.

### Option B: Bake into container image (alternative — for offline/low-latency use)

Cross-compile Answer for linux-arm64 and include in the Docker image, same pattern as potential Codex install.

**Dockerfile addition** (gated by `INSTALL_ANSWER` build arg):
```dockerfile
ARG INSTALL_ANSWER=false
# Answer binary is pre-built and copied in (no source compilation in Docker)
COPY --chown=root:root answer-linux /usr/local/bin/answer
```

**Build workflow:**
1. Cross-compile locally: `cd ~/Projekty/Go/src/Answer && GOOS=linux GOARCH=arm64 go build -o /path/to/Container/answer-linux`
2. Docker build picks up the binary via COPY

**Registration in entrypoint.sh:**
```bash
if command -v answer &>/dev/null && [[ -n "${OPENAI_API_KEY:-}" ]]; then
    claude mcp add answer -- answer mcp -t stdio
fi
```

**Credential bridging:** `OPENAI_API_KEY` env var — pass from host to container same as `MCP_AUTH_TOKEN`.

`container-build.toml` addition:
```toml
[features]
install_answer = false  # Adds ~10MB. Requires OPENAI_API_KEY at runtime.
```

### Comparison

| Criterion | A (karma HTTP) | B (bake in image) |
|-----------|:-:|:-:|
| Container changes | None | Dockerfile + build.toml + entrypoint |
| Consistent with HTTP plan | ++ | ~ |
| No extra karma infra | -- | ++ |
| Binary freshness | Deploy manually | Rebuild image |
| Network latency | Container → karma → OpenAI | Container → OpenAI (direct) |
| Image size impact | None | +10MB |

## Postgres MCP (HTTP, host-side)

Postgres MCP runs on the host Mac as an HTTP service. The container connects through the Apple Container gateway IP (`192.168.64.1`). This follows the same pattern as other remote MCP servers — no image rebuild needed.

### Architecture

```
Host Mac                              Container
┌─────────────────────────┐           ┌──────────────────────────┐
│ postgres-mcp            │           │ Claude Code              │
│   -t http -port 8090    │◀── HTTP ──│   mcp: postgres          │
│   -dsn "postgresql://…" │           │   http://192.168.64.1:…  │
│   --read-only           │           └──────────────────────────┘
│         │               │
│         ▼               │
│   PostgreSQL (local)    │
└─────────────────────────┘
```

### Setup

1. **Start postgres-mcp on the host:**
   ```bash
   postgres-mcp -t http -port 8090 -ip 0.0.0.0 -dsn "postgresql://user:pass@localhost:5432/dbname" --read-only
   ```

2. **Enable in `container-run.toml`:**
   ```toml
   [postgres]
   enabled = true
   url = "http://192.168.64.1:8090/mcp"
   ```

3. **Launch container** — entrypoint registers the MCP server automatically.

### How it works

- `launch.sh` reads `[postgres]` config, passes `PG_MCP_URL` env var to the container
- `entrypoint.sh` runs `claude mcp add postgres --transport http "$PG_MCP_URL"` if the URL is set
- No auth needed — local-only access via container gateway, MCP server enforces read-only
- No Dockerfile changes — no binary in the image

### Files involved

| File | Change |
|------|--------|
| `container-run.toml` | `[postgres] enabled, url` |
| `launch.sh` | Read `[postgres]` config, pass `PG_MCP_URL` env var |
| `entrypoint.sh` | Register `postgres` MCP via HTTP if `PG_MCP_URL` set |

### Alternative: stdio (in-container binary)

If lower latency or offline use is needed, the postgres-mcp binary (`go-postgres-mcp`, ~15MB) can be baked into the image and run via stdio transport. This would require Dockerfile changes and a `PG_DSN` env var instead of `PG_MCP_URL`. The HTTP approach is preferred for simplicity.

## Future: Codex MCP (stdio, in-container)

**Not in scope for initial implementation** — captured here for future reference.

If Codex CLI is baked into the image (optional, same pattern as `claude-agent-acp`), Codex MCP becomes a single stdio registration:

```bash
claude mcp add codex -- codex mcp-server
```

No HTTP transport needed — Codex runs locally inside the container.

### Binary installation

Pre-built linux-arm64 binary available from GitHub releases:
- **URL pattern**: `https://github.com/openai/codex/releases/download/rust-v{VERSION}/codex-aarch64-unknown-linux-gnu.tar.gz`
- **Latest**: v0.111.0 (as of 2026-03-05), ~35 MB
- **Install pattern**: Same as `claude-agent-acp` — gated by `INSTALL_CODEX` build arg in Dockerfile

`container-build.toml` addition:
```toml
[features]
install_codex = false  # Adds ~35MB. Requires codex credentials at runtime.

[versions]
codex = "latest"  # or pin: "0.111.0"
```

### Credential bridging

Codex stores credentials in `~/.codex/auth.json` (plaintext JSON with ChatGPT OAuth tokens — JWTs). Additionally, macOS Keychain has "Codex Safe Storage" entries (encryption keys).

Files needed inside the container:
- `/home/sandbox/.codex/auth.json` — OAuth tokens (essential)
- `/home/sandbox/.codex/config.toml` — model config, approval policy (optional — could generate a minimal one)

**Note**: The host `~/.codex/config.toml` contains macOS-specific paths (e.g., `[mcp_servers.postgres]` with host binary paths) — do NOT copy verbatim. Either strip MCP sections or generate a clean container-specific config.

Bridging approach (same pattern as `CLAUDE_CREDS`):
1. `launch.sh`: Read `~/.codex/auth.json` from host, pass as `CODEX_AUTH` env var
2. `entrypoint.sh`: Write to `/home/sandbox/.codex/auth.json` with `chmod 600`

### What's needed (summary)

| File | Change |
|------|--------|
| `container-build.toml` | `[features] install_codex = false`, `[versions] codex = "latest"` |
| `Dockerfile` | Conditional download of `codex-aarch64-unknown-linux-gnu.tar.gz` |
| `launch.sh` | Read `~/.codex/auth.json`, pass as `CODEX_AUTH` env var |
| `entrypoint.sh` | Write codex credentials + `claude mcp add codex -- codex mcp-server` |

### Open questions

- Does `codex mcp-server` work with just `auth.json`, or does it also need the Keychain "Safe Storage" encryption key?
- Should we generate a minimal `config.toml` for container use (model, approval_policy) or let Codex use defaults?

## Note: rw mode safety

`claude mcp add -s project` writes `.mcp.json` to `/workspace/`. In copy mode this is ephemeral (destroyed with container). In rw mode, `.mcp.json` is written to the host project — add it to `.gitignore` to prevent accidental commits.
