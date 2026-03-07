# Configuration

Two config files: `container-build.toml` (build-time, lives with this repo) and `container-run.toml` (runtime, lives in your project).

## container-build.toml

Tool versions and build features. Changes require `./launch.sh --rebuild`.

```toml
[versions]
claude_code = "latest"          # "latest" resolves at build time
claude_agent_acp = "latest"
gh = "2.87.3"
fd = "10.3.0"
python = "3.14"                 # Python image only
go = "1.26.0"                   # Go image only
golangci_lint = "v2.4.0"        # Go image only

[builder]
cpus = 2                        # Override with BUILD_CPUS env var
memory = "4g"                   # Override with BUILD_MEMORY env var

[features]
install_claude_agent_acp = false # Zed ACP binary (~50MB, on hold)
```

**Priority:** env vars (`BUILD_CPUS`, `BUILD_MEMORY`) > TOML `[builder]` > defaults.

## container-run.toml

Per-project runtime configuration. Place in your project root. Read on every `launch.sh` run — no rebuild needed.

A full example is at `container-run.example.toml`.

### [resources] — VM Resources

```toml
[resources]
memory = "4g"     # Default: "2g"
cpus = 4          # Default: 4
```

**Priority:** CLI flags (`--memory`, `--cpus`) > TOML > defaults.

Override config path: `CONTAINER_RUN_CONFIG=/path/to/config.toml`.

### [claude] — Runtime Flags

```toml
[claude]
claude_simple_mode = true       # Default: true
claude_skip_permissions = "yolo" # Default: "yolo"
claude_additional_system_prompt = ""
claude_model = "haiku"          # Default: "" (use settings.json default)
claude_query = "Read @CONTAINER.md and verify environment"  # Default: ""
```

#### `claude_simple_mode`

**Default:** `true` — sets `CLAUDE_CODE_SIMPLE=1`.

| Simple mode ON (default) | Simple mode OFF |
|--------------------------|-----------------|
| No hooks, MCP servers from `.mcp.json`, attachments, or CLAUDE.md processing | Full features enabled |
| Skips copying `hooks/`, `agents/` from `~/.claude/` | Copies `hooks/`, `agents/` (needs Python 3.12+ for hooks) |
| Still works: core Claude, settings.json, commands, skills, plugins, credentials, CONTAINER.md | Everything works |

**Note:** Remote MCP servers configured in `[mcp]` section work regardless of simple mode — they're registered via `claude mcp add`, not `.mcp.json`.

#### `claude_skip_permissions`

**Default:** `"yolo"` — safe because the container is ephemeral and isolated.

| Value | Claude flags | Behavior |
|-------|-------------|----------|
| `"yolo"` | `--dangerously-skip-permissions` | Full autonomy |
| `"plan"` | `--permission-mode plan --allow-dangerously-skip-permissions` | Plan mode, can escalate |
| `"false"` | _(none)_ | Normal interactive prompts |

#### `claude_model`

Override the model for container sessions. Accepts aliases (`sonnet`, `opus`, `haiku`) or full model IDs. Empty = use default from `settings.json`.

#### `claude_query`

Initial prompt sent to Claude at session start. Useful for environment verification on a cheap model before switching.

#### `claude_additional_system_prompt`

Appended after the built-in "read CONTAINER.md" prompt via `--append-system-prompt`.

### [workspace] — Copy Excludes

```toml
[workspace]
additional_excludes = ["vendor", "dist", ".next"]
```

Added to the built-in exclude list. Patterns follow `tar --exclude` glob syntax.

Special case: `"bin"` excludes only workspace-root `./bin/` (not nested like `src/bin`).

### [environment] — Container Environment

```toml
[environment]
timezone = "Europe/Warsaw"      # Default: Europe/Warsaw
```

Sets `TZ` env var — affects git timestamps, logs, etc.

### [credentials] — SSH Hosts

```toml
[credentials]
ssh_known_hosts = ["github.com", "gitlab.com"]
```

Hosts added to `known_hosts` via `ssh-keyscan`. Default: `["github.com"]`.

### [postgres] — Host-Side Postgres MCP

```toml
[postgres]
enabled = false
url = "http://192.168.64.1:8090/mcp"
```

Connects to `postgres-mcp` running on the host Mac via the Apple Container gateway IP (`192.168.64.1`).

**Host setup:**
```bash
postgres-mcp -t http -port 8090 -ip 0.0.0.0 -dsn "postgresql://user:pass@localhost:5432/dbname" --read-only
```

`-ip 0.0.0.0` is required — the default `localhost` is unreachable from the container. No auth needed — local-only access, MCP server enforces read-only.

### [mcp] — Remote MCP Servers

The host's `.mcp.json` is not copied — it has macOS-specific stdio paths. Instead, `entrypoint.sh` writes a clean `.mcp.json` and re-registers servers via `claude mcp add -s project`. Global MCP servers (from `~/.claude.json` or `settings.json`) are unaffected.

```toml
[mcp]
enabled = false
base_url = "https://karma.rrj.pl"
servers = [
    "pushover /pushover/mcp/ mcp:pushover",
    "gemini /gemini/mcp/ mcp:gemini",
    "time /time/mcp/ mcp:time",
    "answer /answer/mcp/ mcp:gemini"
]
```

Each entry: `"name path keychain-service"` — 3 fields separated by spaces.

- **name** — MCP server name (should match host names — see "Server naming" below)
- **path** — appended to `base_url` to form the full URL
- **keychain-service** — used to look up auth token

**Token resolution** (first match wins):
1. macOS Keychain: `security find-generic-password -s "mcp:pushover" -w`
2. Env var: `MCP_TOKEN_PUSHOVER` (uppercased name after `mcp:`)

**One-time Keychain setup:**
```bash
security add-generic-password -s "mcp:pushover" -a "$USER" -w "TOKEN_HERE"
security add-generic-password -s "mcp:gemini"   -a "$USER" -w "TOKEN_HERE"
```

Servers sharing a token reference the same keychain service (e.g., `answer` and `gemini` both use `mcp:gemini`).

**Server naming:** Use the same names as on the host (`pushover`, not `pushover-remote`). Claude derives tool namespaces from server names — `pushover` gives `mcp__pushover__*` tools. If your host's `settings.local.json` already pre-approves these tools, the same approvals carry over into the container automatically. Otherwise you'd have to re-approve every tool on each container run.

## CONTAINER.md Templates

At startup, `entrypoint.sh` renders `CONTAINER.md` from templates telling Claude about the container environment.

| Template | Used when |
|----------|-----------|
| `templates/CONTAINER.python.md.tmpl` | Python image (default) |
| `templates/CONTAINER.golang.md.tmpl` | Go image |

### Placeholders

`{{PYTHON_VERSION}}`, `{{GO_VERSION}}`, `{{GOLANGCI_LINT_VERSION}}`, `{{CLAUDE_VERSION}}`, `{{MCP_SERVER_LIST}}`

### Conditional blocks

```
<if HAS_MCP>
MCP servers are available: {{MCP_SERVER_LIST}}
</if>
```

Available conditions: `HAS_ACP`, `HAS_GOLANGCI_CONFIG`, `HAS_MCP`. Negate with `!` prefix.

## System Prompt Injection

`launch.sh` injects via `--append-system-prompt`:

1. `"You MUST read CONTAINER.md in the workspace root before doing anything else."`
2. `claude_additional_system_prompt` value (if configured)
