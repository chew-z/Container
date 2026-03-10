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
| `zed-claude-acp.sh`    | Zed ACP integration (blocked upstream — not operational)                             |
| `container-build.toml` | Build-time versions (Claude, Python, Go, gh, fd, etc.)                               |
| `container-run.toml`   | Per-project runtime: resources, permissions, excludes                                |
| `templates/*.md.tmpl`  | CONTAINER.md templates rendered at startup with env vars                             |

## Key Concepts

- **Two images:** `claudecode-python` (Python 3.14 + uv) and `claudecode-golang` (Go 1.26 + gopls + golangci-lint)
- **Copy mode** (default): workspace is copied in; changes are ephemeral. `--rw` for live bind mount.
- **Simple mode** (`CLAUDE_CODE_SIMPLE=1`): skips hooks, agents, session memory; MCP via `claude mcp add` still works. Default in containers
- **Permission modes** via `container-run.toml`: `yolo` (skip all), `plan`, or `off`
- **Credentials:** OAuth from macOS Keychain, gh token, SSH keys — all bridged automatically

## Config Files

- `container-build.toml` — tool versions and feature flags (build-time)
- `container-run.toml` — runtime resources, Claude mode, workspace excludes, SSH hosts (per-project)
- `container-build.example.toml` / `container-run.example.toml` — documented examples

## Tech Stack

- Shell (bash) — all scripts
- Apple Container CLI — container runtime
- Debian bookworm-slim (arm64) — base image
- TOML config parsed with inline awk (no external dependencies)

## Conventions

- `entrypoint.sh` uses a custom template engine (`<if CONDITION>...</if>` blocks + `{{VAR}}` substitution)
- `launch.sh` resolves `latest` versions at build time for proper cache invalidation
- Container names: `claude-{project-slug}`, images: `claudecode-{lang}`

## TALK

- When User says `Talk to me Claude` or something similiar you MUST use `Talk` MCP server to communicate with User.
- Be brief. Give user only the gist of it via `Talk`
- After user says `Be quiet, Claude` or `Shut up Claude` or similiar never use `Talk` unless user encourages speech again by using phrase `Talk to me Claude` or similiar Non-root `sandbox` user inside containers
