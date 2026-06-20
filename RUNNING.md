# Running Claude Code Containers

Containers are ephemeral by default — all local changes are lost on exit. Push via git to persist work.

## Building Images

```bash
# Python image (default)
./launch.sh --rebuild

# Go image
./launch.sh --rebuild --lang golang

# Full no-cache rebuild (suspect corrupted cache)
./launch.sh --full-rebuild
```

### When to Rebuild

- After changing tool versions in `container-build.toml`
- To pick up a new Claude Code binary (`claude_code = "latest"` resolves at build time)
- After toggling `install_godoc_mcp` or `install_codex`

Runtime config (`container-run.toml`) changes never require a rebuild.

### Builder Resources

The Apple `container` builder has limited defaults. Override if builds are slow or OOM:

```bash
BUILD_CPUS=4 BUILD_MEMORY=8g ./launch.sh --rebuild
```

## Running Containers (`launch.sh`)

### Startup Sequence

1. Extract Claude OAuth + GH token from macOS Keychain
2. Read per-project `container-run.toml` (resources, Claude mode, MCP config)
3. Resolve MCP tokens from Keychain (per-server)
4. `container run -it --rm` with all env vars and mounts
5. `entrypoint.sh`: copy config, credentials, SSH keys, workspace
6. Register MCP servers (postgres, remote HTTP)
7. Render `CONTAINER.md` from template
8. `exec claude [flags] [query]`

### Command Reference

| Flag | Description |
|------|-------------|
| `--rebuild` | Smart rebuild — resolves "latest" versions, uses cache |
| `--full-rebuild` | No-cache rebuild from scratch |
| `-C, --project PATH` | Project directory (default: `$PWD`) |
| `--lang LANG` | Language target: `python` (default) or `golang` |
| `--memory SIZE` | Container VM memory (e.g., `4g`). Overrides config |
| `--cpus N` | Container VM CPUs. Overrides config |
| `--rw` | Mount workspace read-write (no isolation) |
| `--update-claude` | Allow Claude to auto-update inside the container |
| `--config PATH` | Build config path (overrides layered resolution) |
| `-- ARGS...` | Pass remaining arguments to claude |

## Machine Mode (`machine-launch.sh`)

Persistent, isolated containers using Apple's `container machine` with `--home-mount none`. Unlike ephemeral containers, machines survive stop/start cycles — tools, cloned repos, and Claude's session state persist across runs. Startup is ~2s after first provisioning.

### First Run (Provisioning)

```bash
./machine-launch.sh                            # Provision + launch Claude
./machine-launch.sh -C /path/to/project        # Specific project
./machine-launch.sh --memory 8g --cpus 4       # Custom resources
```

1. Creates machine `claude-machine-<project-slug>` from `alpine:latest`
2. Installs system packages (git, curl, ripgrep, etc.) via `apk`
3. Downloads Claude Code binary (direct, no Node.js)
4. Clones project repo via GH_TOKEN/HTTPS
5. Configures git, registers MCP servers, renders CONTAINER.md
6. Launches `claude` interactively

### Subsequent Runs (Re-entry)

```bash
./machine-launch.sh                            # Detects existing machine, ~2s startup
```

1. Detects existing machine (checks provisioning sentinel)
2. Runs `git fetch --all` to update remote refs (working tree preserved)
3. Launches `claude` interactively

### Key Differences from Ephemeral Mode

| Aspect | Ephemeral (`launch.sh`) | Machine (`machine-launch.sh`) |
|--------|------------------------|-------------------------------|
| Lifecycle | Destroyed on exit | Persists across stop/start |
| Startup | Image build + container create | ~2s (after first provision) |
| Workspace | Copied from host mount | `git clone` inside machine |
| Uncommitted work | Lost unless pushed | Preserved in machine filesystem |
| Untracked files | Carried in (copy mode) | Must be injected manually |
| SSH support | Copied but non-functional | Not supported |
| Host filesystem | Read-only mounts | No access (`--home-mount none`) |
| Work output | PR-based | PR-based (same) |
| Base image | `claudecode-python`/`claudecode-golang` | `alpine:latest` |

> **Important:** Uncommitted local work and untracked files (`.env`, etc.) do NOT auto-arrive in machine mode. You must commit + push before running, or inject secrets via env vars.

> **Credential staleness:** Credentials (GH_TOKEN, OAuth token) are baked into the machine at provision time. If you rotate a token, run `--reprovision` to re-inject it — re-entry does not refresh credentials.

### Command Reference

| Flag | Description |
|------|-------------|
| `-C, --project PATH` | Project directory (default: `$PWD`) |
| `--memory SIZE` | Machine VM memory (e.g., `4g`). Overrides config |
| `--cpus N` | Machine VM CPUs. Overrides config |
| `--reprovision` / `--reset` | Delete machine and re-create from scratch |
| `--status` | Show machine state (exists, provisioned) and exit |
| `--shell` | Drop into bash instead of launching Claude |
| `-- ARGS...` | Pass remaining arguments to claude |

### Machine Cleanup

```bash
./cleanup.sh --machines                    # List machines
./cleanup.sh --machines --stop             # Stop all machines
./cleanup.sh --machines --remove           # Delete all stopped machines
./cleanup.sh --machines --prune            # Stop + delete all machines
```

### Manual Spike Validation (Phase 0)

Before relying on machine mode, manually validate the core assumptions:

```bash
# 1. Create a machine with no host mount
container machine create --home-mount none --name spike --arch arm64 alpine:latest

# 2. Confirm host $HOME is NOT visible inside
container machine run --name spike -- ls /Users   # expect: empty or absent

# 3. Install Claude Code and verify it works
container machine run --name spike --root -- sh -c \
    'apk add --no-cache curl && curl -fsSL \
    "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/$(curl -fsSL https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest)/linux-arm64/claude" \
    -o /usr/local/bin/claude && chmod +x /usr/local/bin/claude && claude --version'

# 4. Verify persistence across stop/start
container machine stop spike
container machine run --name spike -- claude --version   # expect: version persists

# 5. Cleanup
container machine delete spike
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_LANG` | `python` | Language target |
| `BUILD_CPUS` | `2` | CPUs for image builder |
| `BUILD_MEMORY` | `4g` | Memory for image builder |
| `CONTAINER_BUILD_CONFIG` | _(resolved)_ | Build config path override |
| `CONTAINER_RUN_CONFIG` | _(resolved)_ | Runtime config path override |

## Workspace Isolation

### Copy Mode (default)

Project is bind-mounted read-only, then `entrypoint.sh` copies it to `/workspace` (filtered). Changes stay in the container — host untouched.

**Excluded:** `.venv/`, `venv/`, `node_modules/`, `__pycache__/`, `*.pyc`, `.DS_Store`, `.ruff_cache/`, `.mypy_cache/`, `.pytest_cache/`, `.fastembed_cache/`, `.vscode/`, `.github/`, `.codex/`, `.codanna/`, `.uv/`, `*.egg-info`, `dist/`, `build/`, `container-run.toml`, `.mcp.json`

**Kept:** source code, `.git/`, `.claude/`, `.env`, docs

Additional excludes via `container-run.toml` `[workspace] additional_excludes`. The value `"bin"` is treated as workspace-root only (`./bin/`).

### Read-Write Mode (`--rw`)

Project mounted directly at `/workspace`. Changes visible on host immediately — no isolation.

## Authentication Bridge

| Credential | Source | How |
|------------|--------|-----|
| Claude OAuth | macOS Keychain (`Claude Code-credentials`) | Written to `.credentials.json` in container |
| GitHub token | macOS Keychain (`gh:github.com`) | `GH_TOKEN` env var + git URL rewrite to HTTPS |
| SSH keys | `~/.ssh/id_*` | Copied (but macOS Secure Enclave keys don't work — git uses GH_TOKEN) |
| MCP tokens | macOS Keychain (`mcp:*`) per server | Passed as env vars, used in `claude mcp add --header` |
| `.gitconfig` | `~/.gitconfig` | Copied (SSH-to-HTTPS rewrites stripped) |

`ANTHROPIC_API_KEY` is set to empty string to prevent `.env` files from overriding OAuth.

## Cross-Platform Notes

The container runs Linux arm64 but the host is macOS:

- Python `.venv/` from macOS contains Mach-O binaries — unusable in Linux
- Go binaries built inside are Linux ELF — won't run on macOS
- C extensions (`.so`) are platform-specific

`CONTAINER.md` is auto-generated at startup from templates to inform Claude about these issues.

## Container Cleanup

The `cleanup.sh` script manages containers (`claude-*`), machines (`claude-machine-*`), images (`claudecode-*`), and builder cache.

### Containers

| Command | Description |
|---------|-------------|
| `./cleanup.sh` | List all managed containers and status |
| `./cleanup.sh --stop [NAME]` | Stop specific or all containers |
| `./cleanup.sh --remove [NAME]` | Delete specific or all stopped containers |
| `./cleanup.sh --prune` | Stop and delete all containers |

### Machines

| Command | Description |
|---------|-------------|
| `./cleanup.sh --machines` | List all `claude-machine-*` machines |
| `./cleanup.sh --machines --stop [NAME]` | Stop a machine, or all if no name given |
| `./cleanup.sh --machines --remove [NAME]` | Delete a machine, or all stopped |
| `./cleanup.sh --machines --prune` | Stop and delete all machines |

### Images

| Command | Description |
|---------|-------------|
| `./cleanup.sh --images` | List `claudecode-*` images with sizes |
| `./cleanup.sh --images --prune` | Delete all `claudecode-*` images |

### Builder Cache

| Command | Description |
|---------|-------------|
| `./cleanup.sh --builder-clear-cache` | Stop and delete builder (clears all cached layers) |
| `./cleanup.sh --builder-restart` | Clear cache + restart with configured resources |

### Full Reset

| Command | Description |
|---------|-------------|
| `./cleanup.sh --full-cleanup` | Stop/remove all containers + machines + delete images + clear builder cache |
| `./cleanup.sh --disk-usage` | Show container system disk usage |

### Rebuild Strategies

| Strategy | Command | When |
|----------|---------|------|
| Smart rebuild | `launch.sh --rebuild` | Regular updates (resolves "latest", cache-aware) |
| Full rebuild | `launch.sh --full-rebuild` | Suspect corrupted cache (`--no-cache`) |
| Clear + rebuild | `cleanup.sh --builder-clear-cache` then `launch.sh --rebuild` | Nuclear: delete builder VM and all cached layers |
| Total reset | `cleanup.sh --full-cleanup` then `launch.sh --rebuild` | Start completely fresh |
