# Claude Code in Apple Container

**Run Claude Code inside a sandboxed Linux container on macOS** — full isolation, ephemeral by default, credentials bridged automatically (so uses your Claude Code plan).

Claude Code runs in an ephemeral, isolated container — a strong fit for YOLO permission modes like `--dangerously-skip-permissions`: risky actions are sandboxed, and local changes disappear unless you explicitly persist them via git.

## Why Apple Container

[Apple Container](https://github.com/apple/container) provides Apple Silicon-native Linux containers with lightweight-VM isolation. Superior to the Seatbelt sandbox that Claude Code uses by default.

## Prerequisites

- macOS with Apple Silicon
- Apple's [`container`](https://github.com/apple/container) CLI
- Claude Code authenticated on host (`claude login`)
- GitHub CLI authenticated on host (`gh auth login`) — optional, for git push/PR workflows

## Quick Start

```bash
./launch.sh --rebuild                  # Build image (first time)
./launch.sh                            # Run Claude Code in container
./launch.sh -C /path/to/project       # Specific project
./launch.sh --rebuild --lang golang    # Go image
```

## Documentation

| Document | What's inside |
|----------|---------------|
| [RUNNING.md](RUNNING.md) | Building images, running containers, workspace modes, cleanup |
| [CONFIGURATION.md](CONFIGURATION.md) | Build config, runtime config, MCP servers, permissions |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common errors and fixes |
| [Container Lifecycle](docs/container-lifecycle.md) | How containers, images, and builder cache interact |
| [MCP in Containers](docs/mcp-in-containers.md) | MCP server architecture and setup details |

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-target image: base + Python or Go |
| `entrypoint.sh` | Container startup: config, credentials, workspace, MCP registration |
| `launch.sh` | Main runner: builds image, extracts credentials, launches container |
| `cleanup.sh` | Container/image/builder lifecycle management |
| `container-build.toml` | Build-time versions and feature flags |
| `container-run.toml` | Per-project runtime: resources, Claude mode, MCP, workspace excludes |
| `container-run.example.toml` | Annotated example with all options |
| `templates/CONTAINER.*.md.tmpl` | Language-specific CONTAINER.md templates |

## Container Images

Multi-target Dockerfile with shared base and language-specific stages:

- **Base** = Debian bookworm-slim (arm64) + Claude Code, git, gh, jq, ripgrep, fd, fzf, uv, openssh-client. Non-root `sandbox` user.
- **Python** (`claudecode-python`) = Python 3.14 via uv
- **Go** (`claudecode-golang`) = Go 1.26 + gopls, goimports, golangci-lint, gotestsum, govulncheck, delve

| Image | Build command |
|-------|---------------|
| `claudecode-python` | `./launch.sh --rebuild` |
| `claudecode-golang` | `./launch.sh --rebuild --lang golang` |

## MCP Server Support

Containers can connect to MCP servers via HTTP transport — no binaries baked into images:

- **Remote HTTP servers** — configured in `[mcp]` section, tokens from macOS Keychain
- **Host-side Postgres** — reached via Apple Container gateway (`192.168.64.1`)

See [CONFIGURATION.md](CONFIGURATION.md#mcp---remote-mcp-servers) and [MCP in Containers](docs/mcp-in-containers.md) for setup.

## Zed ACP Mode (On Hold)

> Blocked by an upstream bug in the `claude-agent-acp` static binary (linux-arm64) — crashes with a JavaScript TDZ error (`Cannot access 'z4' before initialization`) during `session/prompt`. The Homebrew (Node.js) build works fine; only the static Bun SEA binary is affected. `zed-claude-acp.sh` is ready — waiting for a fix.
