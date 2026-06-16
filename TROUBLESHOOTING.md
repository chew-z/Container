# Troubleshooting

## Authentication

### "Not logged in" inside container

- Verify host login: `claude login`
- Check Keychain: `security find-generic-password -s "Claude Code-credentials" -w | jq .`
- Must be logged in with your Plan account on macOS

### 401 "invalid x-api-key" errors

Your project's `.env` file likely contains `ANTHROPIC_API_KEY`. Claude Code autoloads `.env`, overriding OAuth with a stale key. Both scripts set `ANTHROPIC_API_KEY=` (empty) to prevent this.

### GitHub push/PR not working

- Verify on host: `gh auth status`
- Check Keychain: `security find-generic-password -s "gh:github.com"`
- Inside container, git uses HTTPS+GH_TOKEN (not SSH) — macOS Secure Enclave keys don't work in Linux

## Container System

### "Image not found"

Build first: `./launch.sh --rebuild`

### Container system not running

```bash
container system start
```

### Build OOM ("cannot allocate memory")

Increase builder memory:

```bash
BUILD_MEMORY=12g ./launch.sh --rebuild
```

### Build uses stale cached layers

`./launch.sh --rebuild` resolves "latest" to actual versions for proper cache busting. If still stale:

```bash
# Full no-cache rebuild
./launch.sh --full-rebuild

# Nuclear: clear builder cache entirely
./cleanup.sh --builder-clear-cache
./launch.sh --rebuild
```

### Disk space issues

```bash
./cleanup.sh --disk-usage         # Check usage
./cleanup.sh --full-cleanup       # Remove everything
./launch.sh --rebuild             # Rebuild fresh
```

## MCP Servers

### MCP server not registering

Check entrypoint output for `[entrypoint] Registering MCP servers...` and per-server OK/FAIL/SKIP messages.

Common causes:
- **SKIP: no token** — token not found in Keychain or env var. Add it:
  ```bash
  security add-generic-password -s "mcp:pushover" -a "$USER" -w "TOKEN_HERE"
  ```
- **FAILED** — server URL unreachable, or `claude mcp add` failed. Verify the remote server is running.

### MCP tools require re-approval on every run

If server names in `[mcp] servers` don't match your host names, tool namespaces differ. For example, `pushover` gives `mcp__pushover__*` tools, but `pushover-remote` gives `mcp__pushover-remote__*` — which won't match the pre-approved rules in your host's `settings.local.json`. Use matching names so approvals carry over.

### Stdio MCP servers connected but tools not appearing

**Symptom:** `claude mcp list` shows the server as "connected", but its tools don't appear in Claude's tool list. HTTP servers work fine.

**Root cause:** The host's `~/.claude/settings.local.json` contains a whitelist:

```json
{
  "enableAllProjectMcpServers": false,
  "enabledMcpjsonServers": ["answer", "pushover", "time", ...]
}
```

When `enableAllProjectMcpServers` is `false`, only servers named in `enabledMcpjsonServers` get their tools loaded. `launch.sh` reads this whitelist and passes it to the container as `ENABLED_MCP_SERVERS`. All servers (HTTP and stdio) are only registered if they appear in the list — you control exactly which MCP servers are active.

**Fix:** Add the server names to `enabledMcpjsonServers` in your host's `~/.claude/settings.local.json`:

```json
{
  "enabledMcpjsonServers": ["answer", "pushover", "time", "codex", "godoc"]
}
```

Or enable all project MCP servers:

```json
{
  "enableAllProjectMcpServers": true
}
```

**Verification:** Check entrypoint output for `SKIP: godoc (not in enabledMcpjsonServers)` — this means the server was excluded by the whitelist.

**Manual stdio server test:**

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' \
  | /home/sandbox/.local/bin/codex mcp-server 2>/dev/null
```

A valid response means the server binary works. If it outputs non-JSON to stdout (stdout pollution), that breaks the MCP protocol.

**Checklist:**
- Server binary exists at absolute path (`which codex`, `which godoc-mcp`)
- Server name is in `enabledMcpjsonServers` (or `enableAllProjectMcpServers: true`)
- `claude mcp list` shows the server
- Manual `printf | server` test returns valid JSON-RPC response
- No stdout pollution (all logs must go to stderr)

### Codex MCP defaults to read-only sandbox

**Symptom:** Codex MCP tools fail with filesystem access errors even though `~/.codex/config.toml` has `sandbox_mode = "danger-full-access"` and `codex mcp-server` is launched with `--sandbox danger-full-access`.

**Root cause:** The Codex MCP server exposes `sandbox` as a per-call parameter. Claude defaults to `sandbox: "read-only"` in its tool calls, overriding both the CLI flag and config.toml. Neither server-side setting can prevent this — the per-call parameter always wins.

**Fix:** Instruct Claude via CONTAINER.md to always pass `sandbox: "danger-full-access"` and `approval-policy: "never"` in every Codex MCP call. The templates (`templates/CONTAINER.*.md.tmpl`) include this instruction in the `<if HAS_CODEX>` section.

**Verification:** When Codex works, calls look like:
```
codex(prompt: "...", cwd: "/workspace", sandbox: "danger-full-access", approval-policy: "never")
```

If Claude omits `sandbox` or uses `read-only`, Codex will fail to read files.

**Key insight:** For MCP servers that expose sandbox/permission parameters, prompt-level instructions to Claude are more reliable than server-side configuration, because Claude controls the per-call parameters.

### Postgres MCP not connecting

- Verify `postgres-mcp` is running on host with `-ip 0.0.0.0` (not `localhost`)
- The container reaches the host via `192.168.64.1` (Apple Container gateway)
- Check `[postgres] enabled = true` in `container-run.toml`
