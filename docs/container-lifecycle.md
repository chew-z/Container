# Container, Image, and Builder Lifecycle

Understanding how containers, images, and the builder interact — and what gets cached where — is essential for keeping your Claude Code sandbox up to date.

## Overview

Three independent subsystems collaborate when you run `launch.sh` (ephemeral mode) or `machine-launch.sh` (machine mode):

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}, "flowchart": {"htmlLabels": false, "useMaxWidth": false}}}%%
flowchart LR
    subgraph BuildTime["Build Time"]
        Builder["Builder<br/><i>(BuildKit VM)</i>"]
        Cache["Layer Cache<br/><i>(inside builder)</i>"]
        Builder --- Cache
    end

    subgraph Storage["Image Storage"]
        Image["OCI Image<br/><i>claudecode-python</i>"]
    end

    subgraph Runtime["Run Time"]
        Container["Container<br/><i>lightweight VM</i>"]
    end

    Builder -->|"container build"| Image
    Image -->|"container run"| Container
```

Each subsystem has its own lifecycle. Removing an image does **not** clear the builder cache, and stopping a container does **not** affect images.

## The Builder

The builder is a utility container running [BuildKit](https://github.com/moby/buildkit) inside a lightweight VM. It processes `Dockerfile` instructions and produces OCI images.

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}}}%%
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Running: container builder start
    Running --> Running: container build (uses existing)
    Running --> Stopped: container builder stop
    Stopped --> [*]: container builder delete
    Running --> Stopped: cleanup.sh --builder-clear-cache

    note right of Running
        Layer cache lives here.
        Survives across builds.
        Only cleared by deleting
        the builder.
    end note
```

### Builder layer cache

BuildKit caches every Dockerfile layer by computing a **cache key** from the instruction and its inputs (build-args, source files, base image digest). On subsequent builds:

- **Cache hit** — same cache key → layer is reused instantly (no download, no install)
- **Cache miss** — different cache key → layer is rebuilt, and all subsequent layers are also rebuilt

This is why `container image rm` alone doesn't force a fresh build — the builder is a separate VM with its own cache. Even after deleting all images, running `container build` will still find cached layers in the builder.

### The "latest" problem

When a build-arg like `CLAUDE_CODE_VERSION=latest` is passed, BuildKit sees the literal string `"latest"` — the same string every time. This produces a cache hit, so the old binary is reused even when a new version exists upstream.

**Solution (`launch.sh --rebuild`):** The script resolves `"latest"` to the actual version number on the host *before* calling `container build`. BuildKit then sees a new cache key (e.g., `1.0.33` → `1.0.34`) and rebuilds the affected layers.

### Builder commands

| Command | What happens |
|---------|-------------|
| `container builder start --cpus N --memory SIZE` | Start the builder VM with given resources |
| `container builder status` | Show builder state |
| `container builder stop` | Stop the builder VM (cache preserved on disk) |
| `container builder delete` | Delete the builder VM **and all cached layers** |
| `cleanup.sh --builder-clear-cache` | Stop + delete (convenience wrapper) |
| `cleanup.sh --builder-restart` | Clear cache + restart with configured resources |

> See also: Apple Container [how-to — configure builder resources](https://github.com/apple/container/blob/main/docs/how-to.md#configure-memory-and-cpus-for-large-builds) and [command reference — builder](https://github.com/apple/container/blob/main/docs/command-reference.md).

## Images

An image is a read-only OCI artifact stored locally. It contains the filesystem layers that a container boots from.

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}}}%%
stateDiagram-v2
    [*] --> Built: container build -t name
    Built --> Listed: container image list
    Built --> Pulled: container image pull (registry)
    Built --> [*]: container image rm name
    Built --> Running: container run name

    note right of Built
        Images are immutable.
        Rebuilding creates a
        new image with the
        same tag.
    end note
```

### Image management commands

| Command | What happens |
|---------|-------------|
| `container image list` | List local images |
| `container image list --verbose` | List with sizes |
| `container image rm NAME` | Delete a specific image |
| `cleanup.sh --images` | List claudecode-* images with sizes |
| `cleanup.sh --images --prune` | Delete all claudecode-* images |

> See also: Apple Container [command reference — image](https://github.com/apple/container/blob/main/docs/command-reference.md).

## Containers

Each container is a lightweight VM running a Linux kernel. In this project, containers are ephemeral — they are created with `--rm` and destroyed when Claude Code exits.

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}}}%%
stateDiagram-v2
    [*] --> Created: container run --rm
    Created --> Running: (immediate)
    Running --> Stopped: claude exits / container stop
    Stopped --> [*]: auto-removed (--rm)

    Running --> Running: user works inside

    note right of Running
        Workspace is copied in
        at startup. Changes live
        only inside the VM.
    end note
```

### Container management commands

| Command | What happens |
|---------|-------------|
| `container list --all` | List all containers |
| `container stop NAME` | Stop a running container |
| `container delete NAME` | Delete a stopped container |
| `cleanup.sh --list` | List managed containers (claude-*) |
| `cleanup.sh --stop` | Stop all managed containers |
| `cleanup.sh --prune` | Stop + delete all managed containers |

> See also: Apple Container [how-to — configure container resources](https://github.com/apple/container/blob/main/docs/how-to.md#configure-memory-and-cpus-for-your-containers) and [technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md).

## Machines

Machines are persistent Linux VMs created via `container machine` with `--home-mount none`. Unlike containers, they survive stop/start cycles — tools, cloned repos, and Claude's session state persist. Startup is ~2s after first provisioning.

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}}}%%
stateDiagram-v2
    [*] --> Absent
    Absent --> Created: machine create --home-mount none
    Created --> Provisioned: first-boot setup (Claude + clone)
    Provisioned --> Running: machine run → claude
    Running --> Stopped: session ends / machine stop
    Stopped --> Running: machine run (~2s, state intact)
    Stopped --> Absent: machine delete

    note right of Provisioned
        Tools + cloned repo persist.
        Re-entry: git fetch only.
    end note
```

### Machine management commands

| Command | What happens |
|---------|-------------|
| `container machine list` | List all machines |
| `container machine stop NAME` | Stop a running machine |
| `container machine delete NAME` | Delete a machine (destroys storage) |
| `cleanup.sh --machines` | List managed machines (`claude-machine-*`) |
| `cleanup.sh --machines --stop` | Stop all managed machines |
| `cleanup.sh --machines --remove` | Delete all stopped machines |
| `cleanup.sh --machines --prune` | Stop + delete all managed machines |

> See also: [Machine Mode](machine-mode.md) and [RUNNING.md](../RUNNING.md#machine-mode-machine-launchsh).

## Full Lifecycle: Build → Run → Cleanup

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}, "flowchart": {"htmlLabels": false, "useMaxWidth": false}}}%%
flowchart TB
    subgraph build["launch.sh --rebuild"]
        B1["Resolve 'latest' versions<br/><i>curl GCS / GitHub API</i>"]
        B2["Start builder VM"]
        B3["container build<br/><i>with resolved versions</i>"]
        B4["Image stored locally"]
        B1 --> B2 --> B3 --> B4
    end

    subgraph run["launch.sh"]
        R1["Read credentials<br/><i>from macOS Keychain</i>"]
        R2["container run --rm<br/><i>mount workspace + config</i>"]
        R3["entrypoint.sh<br/><i>copy workspace, setup env</i>"]
        R4["Claude Code session"]
        R1 --> R2 --> R3 --> R4
    end

    subgraph cleanup["cleanup.sh"]
        C1["--prune<br/><i>stop + delete containers</i>"]
        C2["--images --prune<br/><i>delete images</i>"]
        C3["--builder-clear-cache<br/><i>delete builder + cache</i>"]
    end

    build --> run
    run --> cleanup
```

## Rebuild Strategies

| Strategy | Command | When to use |
|----------|---------|-------------|
| **Smart rebuild** | `launch.sh --rebuild` | Regular updates. Resolves "latest" to real versions — cache busts only for changed layers. Fast when nothing changed upstream. |
| **Full rebuild** | `launch.sh --full-rebuild` | Suspect corrupted cache or want a completely fresh image. Passes `--no-cache` to BuildKit — every layer is rebuilt from scratch. |
| **Clear cache + rebuild** | `cleanup.sh --builder-clear-cache` then `launch.sh --rebuild` | Nuclear option. Deletes the entire builder VM and its cache, then does a smart rebuild. Equivalent to a first-time build. |
| **Full cleanup + rebuild** | `cleanup.sh --full-cleanup` then `launch.sh --rebuild` | Start completely fresh — remove all containers, images, and builder cache, then rebuild everything. |

### Which to choose?

```mermaid
%%{init: {"themeVariables": {"fontSize": "9pt"}, "flowchart": {"htmlLabels": false, "useMaxWidth": false}}}%%
flowchart TB
    Q1{"Need latest<br/>Claude Code?"}
    Q1 -->|Yes| A1["launch.sh --rebuild<br/><i>resolves version, rebuilds changed layers</i>"]

    Q1 -->|"Still stale"| Q2{"Tried --rebuild<br/>already?"}
    Q2 -->|Yes| A2["launch.sh --full-rebuild<br/><i>--no-cache, rebuilds everything</i>"]

    Q2 -->|"Still broken"| Q3{"Cache corruption?"}
    Q3 -->|Maybe| A3["cleanup.sh --builder-clear-cache<br/>then launch.sh --rebuild"]

    Q3 -->|"Want clean slate"| A4["cleanup.sh --full-cleanup<br/>then launch.sh --rebuild"]

    classDef action fill:#c8e6c9
    class A1,A2,A3,A4 action
```

## Disk Usage

Use `cleanup.sh --disk-usage` (wraps `container system df`) to see how much space containers, images, and the builder cache are consuming.

> See also: Apple Container [command reference — system](https://github.com/apple/container/blob/main/docs/command-reference.md).

## Reference

- [Apple Container — Technical Overview](https://github.com/apple/container/blob/main/docs/technical-overview.md) — how `container` runs lightweight VMs
- [Apple Container — How-to](https://github.com/apple/container/blob/main/docs/how-to.md) — configure builder/container resources, mounts, networking
- [Apple Container — Command Reference](https://github.com/apple/container/blob/main/docs/command-reference.md) — full CLI documentation
- [RUNNING.md](../RUNNING.md) — building images, running containers, machine mode
- [Machine Mode](machine-mode.md) — persistent isolated containers architecture
- [CONFIGURATION.md](../CONFIGURATION.md) — build config, feature flags, permission modes
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common errors and fixes
