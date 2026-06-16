# Container — Claude Code in Apple Container

Sandboxed Linux containers for running Claude Code on macOS (Apple Silicon).
Builds ephemeral arm64 containers with full tooling, credential bridging, and workspace isolation.

## Project Structure

| File                   | Purpose                                                                              |
| ---------------------- | ------------------------------------------------------------------------------------ |
| `Dockerfile`           | Multi-target image: shared base + `python` / `golang` stages                         |
| `entrypoint.sh`        | Container startup: copies config, creds, SSH keys, workspace; generates CONTAINER.md |
| `launch.sh`            | Main CLI: builds image, reads config, launches interactive Claude session            |
| `cleanup.sh`           | Container/image lifecycle management (list/stop/remove/prune)                        |
| `container-build.toml` | Build-time versions (Claude, Python, Go, gh, fd, etc.)                               |
| `container-run.toml`   | Per-project runtime: resources, permissions, excludes                                |
| `templates/*.md.tmpl`  | CONTAINER.md templates rendered at startup with env vars                             |

## Key Concepts

- **Two images:** `claudecode-python` (Python 3.14 + uv) and `claudecode-golang` (Go 1.26 + gopls + golangci-lint)
- **Copy mode** (default): workspace is copied in; changes are ephemeral. `--rw` for live bind mount.
- **Simple mode** (`CLAUDE_CODE_SIMPLE=1`): skips hooks, agents, session memory; MCP via `claude mcp add` still works. **Incompatible with subscription (Plan) auth** — requires `ANTHROPIC_API_KEY` (API billing)
- **Full mode** (`claude_simple_mode = false`): hooks, agents, session memory, CLAUDE.md active. Required for subscription credentials (Plan billing)
- **Permission modes** via `container-run.toml`: `yolo` (skip all), `plan`, or `off`
- **Credentials:** Subscription credentials from macOS Keychain, gh token, SSH keys — all bridged automatically. Simple mode disables credential reading
- **Symlink-safe:** `launch.sh` and `cleanup.sh` resolve symlink chains, so they work from `~/.local/bin` or similar

## Config Files

Layered config resolution (first existing file wins, no merging):

1. Env var override (`CONTAINER_BUILD_CONFIG` / `CONTAINER_RUN_CONFIG`)
2. Project-local: `$PROJECT/container-build.toml` or `$PROJECT/container-run.toml`
3. Global: `~/.config/container/container-build.toml` or `~/.config/container/container-run.toml`
4. Repo fallback (build config only): `$SCRIPT_DIR/container-build.toml`

- `container-build.example.toml` / `container-run.example.toml` — documented examples

### Resource precedence (CPU / memory)

```
CLI flags (--cpus, --memory)         ← highest priority
  └── container-run.toml [resources]
        └── ~/.config/container/config.toml [container]   ← Apple Container system defaults
              └── Built-in defaults (4 CPUs, 1 GiB RAM)   ← lowest priority
```

Apple Container 1.0.0 introduced `~/.config/container/config.toml` for system-wide defaults.
Our `container-run.toml` overrides those per-project, and CLI flags override everything.

## Tech Stack

- Shell (bash) — all scripts
- Apple Container CLI — container runtime
- Debian bookworm-slim (arm64) — base image
- TOML config parsed with inline awk (no external dependencies)

## Conventions

- `entrypoint.sh` uses a custom template engine (`<if CONDITION>...</if>` blocks + `{{VAR}}` substitution)
- `launch.sh` resolves `latest` versions at build time for proper cache invalidation
- `launch.sh` and `cleanup.sh` resolve symlink chains for `SCRIPT_DIR` (portable, no `realpath` dependency)
- Container names: `claude-{project-slug}`, images: `claudecode-{lang}`

## TALK

- When User says `Talk to me Claude` or something similiar you MUST use `Talk` MCP server to communicate with User.
- Be brief. Give user only the gist of it via `Talk`
- After user says `Be quiet, Claude` or `Shut up Claude` or similiar never use `Talk` unless user encourages speech again by using phrase `Talk to me Claude` or similiar Non-root `sandbox` user inside containers
