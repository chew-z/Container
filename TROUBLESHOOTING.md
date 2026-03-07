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

### Postgres MCP not connecting

- Verify `postgres-mcp` is running on host with `-ip 0.0.0.0` (not `localhost`)
- The container reaches the host via `192.168.64.1` (Apple Container gateway)
- Check `[postgres] enabled = true` in `container-run.toml`

## Zed ACP Mode

### "Query closed before response received" in Zed

ACP mode is on hold due to an upstream bug. Check logs: `tail -f /tmp/zed-claude-acp.log`
