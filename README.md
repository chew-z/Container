# Claude Code Container

Run Claude Code inside a sandboxed Linux container on macOS — full isolation, ephemeral by default, credentials bridged automatically from Keychain.

```mermaid
%%{init: {"themeVariables": {"fontSize": "12px"}}}%%
flowchart LR
    subgraph Host["macOS Host"]
        Terminal["Terminal"]
        Keychain["macOS Keychain"]
        Project["Project Files"]
    end

    subgraph Container["Linux Container (arm64)"]
        Claude["Claude Code"]
        Tools["git, gh, ripgrep, fd, fzf"]
    end

    Terminal -->|"launch.sh"| Claude
    Keychain -.->|"OAuth + GH token"| Container
    Project -->|"copy or bind mount"| Container
```

## Prerequisites

- macOS with Apple Silicon
- Apple's [`container`](https://github.com/apple/container-manager) CLI
- Claude Code authenticated on host (`claude login`)
- GitHub CLI authenticated on host (`gh auth login`) — optional, for git push/PR workflows

## Quick Start

```bash
./launch.sh --rebuild          # Build image (first time)
./launch.sh                    # Run Claude Code interactively
./launch.sh -C /path/to/project  # Run on a specific project
./launch.sh --rebuild --lang golang  # Build Go image
```

## Documentation

| Document                                 | What's inside                                                         |
| ---------------------------------------- | --------------------------------------------------------------------- |
| [CONFIGURATION.md](CONFIGURATION.md)     | Build config, feature flags, permission modes, simple mode, templates |
| [RUNNING.md](RUNNING.md)                 | Building images, running containers, workspace isolation, cleanup     |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common errors and quick fixes                                         |

## Files

| File                            | Purpose                                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Dockerfile`                    | Multi-target image: base + Python or Go                                                                    |
| `entrypoint.sh`                 | Container startup: copies config, credentials, SSH keys, workspace                                         |
| `launch.sh`                     | Main runner: optionally builds image, then starts an interactive Claude session in an ephemeral container  |
| `zed-claude-acp.sh`             | Zed ACP mode (not operational — see below)                                                                 |
| `cleanup.sh`                    | Manage containers and images (list/stop/remove/prune)                                                      |
| `container-build.toml`          | Build-time versions and feature flags                                                                      |
| `container-run.toml`            | Per-project runtime settings (VM resources, Claude mode/permissions, workspace excludes, credential hosts) |
| `templates/CONTAINER.*.md.tmpl` | Language-specific CONTAINER.md templates                                                                   |
| `CONTAINER.md`                  | Auto-generated at runtime; tells Claude it's in a Linux container                                          |
| `.dockerignore`                 | Limits build context to Dockerfile + entrypoint + templates                                                |

## Container Images

Multi-target Dockerfile with a shared base and language-specific stages:

```mermaid
%%{init: {"themeVariables": {"fontSize": "12px"}}}%%
flowchart TB
    Base["base stage<br/><i>Debian bookworm-slim, arm64</i>"] --> Python["python stage"]
    Base --> Golang["golang stage"]

    subgraph python_img["claudecode-python"]
        P1["Python via uv"]
    end

    subgraph golang_img["claudecode-golang"]
        G1["Go + gopls, goimports"]
        G2["golangci-lint, gotestsum, govulncheck"]
    end

    Python --> python_img
    Golang --> golang_img
```

Plain-language view:

- **Base stage** = preinstalled common tools used in every image (Claude, git, gh, jq, ripgrep, fd, fzf, uv, ssh client).
- **Python/Go stages** = add language-specific toolchains on top of that base.
- This keeps builds faster and simpler because shared tools are defined once.

**Base tooling (both images):** Claude Code (binary), git, gh, jq, ripgrep, fd, fzf, uv, openssh-client. Non-root `sandbox` user.

| Image               | Build command                         |
| ------------------- | ------------------------------------- |
| `claudecode-python` | `./launch.sh --rebuild`               |
| `claudecode-golang` | `./launch.sh --rebuild --lang golang` |

## Zed ACP Mode (On Hold)

> **Blocked by upstream bug in `claude-agent-acp` v0.20.1 static binary (linux-arm64).**
>
> The ACP static binary (Bun SEA) crashes with a JavaScript TDZ error (`Cannot access 'z4' before initialization`) during `session/prompt`. The bug is in the binary's `--cli` mode — a code path used only by the static build. The Homebrew (Node.js) distribution of the same version works fine on macOS because it uses the SDK's `cli.js` module directly instead of `--cli`.
>
> `zed-claude-acp.sh` itself is correct and ready — it's waiting for a fixed ACP binary. Track the issue at [zed-industries/claude-agent-acp](https://github.com/zed-industries/claude-agent-acp/issues).

## Troubleshooting

Moved to [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) to keep this README focused on setup and architecture.
