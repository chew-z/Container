#!/usr/bin/env bash
# zed-claude-acp.sh — Zed ACP integration using a persistent container
#
# Zed calls this script as a custom agent server. It creates or reuses a
# persistent container per project, then attaches ACP via `container exec -i`.
#
# ACP protocol: plain JSON-RPC lines over stdio (NOT LSP Content-Length framing).
# All log output goes to /tmp/zed-claude-acp.log to keep ACP stdio clean.

set -euo pipefail

LOG_FILE="/tmp/zed-claude-acp.log"

# Redirect stderr to log file for the entire script lifetime.
# This keeps Zed's stdio clean (it parses both stdout and stderr as JSON-RPC).
# The final `exec container exec -i` inherits this, so claude-agent-acp's
# debug output goes to the log file, not to Zed.
exec 2>>"$LOG_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${PWD}"
COPY_MODE=0
CONTAINER_TTL="${CONTAINER_TTL:-1800}"  # idle timeout in seconds (default: 30 min, 0=forever)

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Zed ACP agent server. Creates/reuses a persistent container per project and
attaches claude-agent-acp via container exec.

Options:
  -h, --help          Show this help and exit
  -C, --project PATH  Project directory (default: \$PWD)
  --copy              Mount workspace read-only; copy into container

Log file: $LOG_FILE
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -C|--project)
            PROJECT="${2:?--project requires a path}"
            shift 2
            ;;
        --copy)
            COPY_MODE=1
            shift
            ;;
        *)
            log "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ── Resolve project path ──────────────────────────────────────────────────────
PROJECT="$(cd "$PROJECT" && pwd)"

# ── Derive names from project basename ────────────────────────────────────────
project_slug() {
    basename "$1" | tr -cs 'a-zA-Z0-9._-' '-' | sed 's/^-*//;s/-*$//' | tr '[:upper:]' '[:lower:]'
}

SLUG="$(project_slug "$PROJECT")"
[[ -z "$SLUG" ]] && SLUG="sandbox"
IMAGE="claudecode-${CONTAINER_LANG:-python}"
CONTAINER_NAME="zed-${SLUG}"

# ── Extract OAuth credentials from macOS Keychain (full JSON blob) ────────────
CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [[ -z "$CLAUDE_CREDS" ]]; then
    log "WARNING: Could not extract credentials from Keychain."
fi

# ── Extract GitHub CLI token from macOS Keychain ─────────────────────────────
GH_TOKEN=""
GH_TOKEN_RAW="$(security find-generic-password -s "gh:github.com" -w 2>/dev/null || true)"
if [[ "$GH_TOKEN_RAW" == go-keyring-base64:* ]]; then
    GH_TOKEN="$(echo "${GH_TOKEN_RAW#go-keyring-base64:}" | base64 -d)"
elif [[ -n "$GH_TOKEN_RAW" ]]; then
    GH_TOKEN="$GH_TOKEN_RAW"
fi

log "Project:   $PROJECT"
log "Container: $CONTAINER_NAME"
log "Image:     $IMAGE"

# ── Mount args ────────────────────────────────────────────────────────────────
# Mount workspace at the SAME path as host so ACP cwd from Zed resolves correctly.
# Zed sends session/new with cwd=<host path>; claude-agent-acp uses it as-is.
if [[ "$COPY_MODE" == "1" ]]; then
    WORKSPACE_MOUNT="type=bind,source=${PROJECT},target=/mnt/in/workspace,readonly"
else
    WORKSPACE_MOUNT="type=bind,source=${PROJECT},target=${PROJECT}"
fi

CLAUDE_DIR_MOUNT="type=bind,source=${HOME}/.claude,target=/mnt/in/claude_dir,readonly"
HOME_MOUNT="type=bind,source=${HOME},target=/mnt/in/home,readonly"

# ── Setup config inside container ─────────────────────────────────────────────
setup_container_config() {
    log "Setting up config inside container..."
    container exec "$CONTAINER_NAME" /bin/bash -c \
        'mkdir -p /home/sandbox/.claude; for f in settings.json CLAUDE.md claude-devtools-config.json; do [ -f /mnt/in/claude_dir/$f ] && cp -p /mnt/in/claude_dir/$f /home/sandbox/.claude/$f; done; for d in commands hooks skills plugins statsig; do [ -d /mnt/in/claude_dir/$d ] && cp -rp /mnt/in/claude_dir/$d /home/sandbox/.claude/$d; done; cp /mnt/in/home/.claude.json /home/sandbox/.claude.json 2>/dev/null; true' >>"$LOG_FILE" 2>&1
    # Write credentials file (Linux plaintext fallback for Keychain)
    if [[ -n "${CLAUDE_CREDS:-}" ]]; then
        log "Writing credentials file into container..."
        container exec "$CONTAINER_NAME" /bin/bash -c \
            "mkdir -p /home/sandbox/.claude && \
             cat > /home/sandbox/.claude/.credentials.json << 'CREDS_EOF'
${CLAUDE_CREDS}
CREDS_EOF
chmod 600 /home/sandbox/.claude/.credentials.json" >>"$LOG_FILE" 2>&1
    fi
    # Copy SSH keys and git config
    # NOTE: Host SSH config references macOS-only agents (Secretive, Keychain)
    # that don't exist in the container. We copy the raw keys and write a
    # minimal config so SSH uses them directly.
    log "Setting up SSH keys and git config..."
    container exec "$CONTAINER_NAME" /bin/bash -c \
        'mkdir -p /home/sandbox/.ssh && \
         cp /mnt/in/home/.ssh/id_* /home/sandbox/.ssh/ 2>/dev/null || true && \
         chmod 700 /home/sandbox/.ssh && \
         chmod 600 /home/sandbox/.ssh/id_* 2>/dev/null || true && \
         chmod 644 /home/sandbox/.ssh/id_*.pub 2>/dev/null || true && \
         ssh-keyscan -T 5 -t ed25519 github.com >> /home/sandbox/.ssh/known_hosts 2>/dev/null || true && \
         cat > /home/sandbox/.ssh/config << '\''SSHEOF'\''
Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHEOF
         chmod 600 /home/sandbox/.ssh/config && \
         cp /mnt/in/home/.gitconfig /home/sandbox/.gitconfig 2>/dev/null || true' >>"$LOG_FILE" 2>&1
}

# ── Build watchdog command (replaces sleep infinity) ─────────────────────────
# Monitors for claude-agent-acp process. If idle for CONTAINER_TTL seconds,
# the container exits automatically. Set CONTAINER_TTL=0 for no timeout.
build_watchdog_cmd() {
    if [[ "$CONTAINER_TTL" == "0" ]]; then
        echo "sleep infinity"
    else
        cat <<'WATCHDOG'
idle=0; while true; do
  sleep 60
  if pgrep -x claude-agent-acp >/dev/null 2>&1; then
    idle=0
  else
    idle=$((idle + 60))
    if [ "$idle" -ge "$CONTAINER_TTL" ]; then exit 0; fi
  fi
done
WATCHDOG
    fi
}

# ── Create a new persistent container ────────────────────────────────────────
create_container() {
    log "Creating new persistent container: $CONTAINER_NAME (TTL=${CONTAINER_TTL}s)"
    local watchdog
    watchdog="$(build_watchdog_cmd)"
    container create \
        --name "$CONTAINER_NAME" \
        --arch arm64 \
        --mount "$WORKSPACE_MOUNT" \
        --mount "$CLAUDE_DIR_MOUNT" \
        --mount "$HOME_MOUNT" \
        -e "SANDBOX_COPY_MODE=${COPY_MODE}" \
        -e "CONTAINER_TTL=${CONTAINER_TTL}" \
        "$IMAGE" \
        /bin/bash -c "$watchdog" >>"$LOG_FILE" 2>&1

    container start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
    log "Container started."
    setup_container_config
}

# ── Container lifecycle management ────────────────────────────────────────────
ensure_container_running() {
    # Case 1: Container is already running — refresh credentials (tokens expire)
    if container exec "$CONTAINER_NAME" true &>/dev/null; then
        log "Container already running: $CONTAINER_NAME"
        setup_container_config
        return 0
    fi

    # Case 2: Container exists but is stopped — try to start it
    if container start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1; then
        log "Started existing container: $CONTAINER_NAME"
        sleep 1
        setup_container_config
        return 0
    fi

    # Case 3: Container does not exist — create fresh
    if create_container >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    # Case 4: Stale/broken container — force delete and recreate
    log "Removing stale container: $CONTAINER_NAME"
    container delete --force "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
    create_container
}

# ── Ensure Apple container system daemon is running ─────────────────────────
ensure_container_system() {
    if container system status &>/dev/null; then
        log "Container system service is running."
        return 0
    fi

    log "Container system service not running — starting it..."
    container system start >>"$LOG_FILE" 2>&1

    # Wait for daemon to become ready (up to 10s)
    local retries=10
    while (( retries-- > 0 )); do
        if container system status &>/dev/null; then
            log "Container system service started."
            return 0
        fi
        sleep 1
    done

    log "ERROR: Container system service failed to start."
    exit 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_container_system
ensure_container_running

# ── Environment for container exec ────────────────────────────────────────────
# Container-specific overrides
# NOTE: Do NOT set CLAUDE_CODE_EXECUTABLE — the ACP binary bundles its own
# Claude Code runtime and invokes itself with --cli. Pointing it at the
# standalone claude binary breaks the --cli handshake.
EXEC_ENV=(
    -e "HOME=/home/sandbox"
    -e "CLAUDE_CODE_SHELL=/bin/bash"
    -e "ANTHROPIC_API_KEY="
    -e "GH_TOKEN=${GH_TOKEN}"
)
# NOTE: ANTHROPIC_API_KEY="" is intentional — forces Claude Code / ACP to use
# OAuth (.credentials.json) instead of picking up an API key from the project's
# .env file. Python scripts that need the API key should use
# load_dotenv(override=True) to override this empty value.
# Forward host env vars (typically set via Zed agent_servers.env config)
# NOTE: ANTHROPIC_BASE_URL is required as an env var — claude-agent-acp spawns
# claude --cli which needs it to reach the auth proxy. It does leak into child
# processes; Python scripts that use the SDK directly should set their own
# base_url or unset ANTHROPIC_BASE_URL before calling the API.
for var in ANTHROPIC_BASE_URL API_TIMEOUT_MS \
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
           CLAUDE_CODE_SIMPLE DISABLE_NON_ESSENTIAL_MODEL_CALLS \
           MAX_THINKING_TOKENS; do
    [[ -n "${!var:-}" ]] && EXEC_ENV+=(-e "${var}=${!var}")
done

# ── Generate CONTAINER.md for Claude Code context ────────────────────────────
# Written to project dir (bind-mounted RW) so Claude reads it via CLAUDE.md reference.
# Detects project language from files (pyproject.toml, go.mod, etc.).
generate_container_md() {
    local md="${PROJECT}/CONTAINER.md"
    local content="# Container Environment (auto-generated)

You are running inside a **Linux arm64** container (Debian bookworm), NOT macOS.
The workspace is bind-mounted read-write — every file change is visible to the host and Zed immediately.

## Available Tools

- git, gh (GitHub CLI), jq, ripgrep, fd, fzf, curl, uv
- SSH is configured for github.com (key-based auth)

## Important Notes

- All binaries you build or install are **Linux arm64** — they will not run on macOS.
"

    # Detect Python project
    if [[ -f "${PROJECT}/pyproject.toml" || -f "${PROJECT}/requirements.txt" || \
          -f "${PROJECT}/setup.py" || -f "${PROJECT}/Pipfile" ]]; then
        content+="
## Python Projects

Follow these steps **before** running any Python code:

1. **Create a Linux virtualenv** (any existing \`.venv/\` contains macOS binaries — do not use it):
   \`\`\`bash
   uv venv .venv-container && source .venv-container/bin/activate
   \`\`\`
   Use \`.venv-container\` to avoid conflicts with the host \`.venv/\`.

2. **Install dependencies** (use \`uv pip\`, never bare \`pip\`):
   \`\`\`bash
   uv pip install -r requirements.txt   # or: uv pip install -e .
   \`\`\`

3. **Fix \`.env\` loading** — \`ANTHROPIC_API_KEY\` is set to an empty string in this
   container (for Claude Code OAuth). \`load_dotenv()\` will NOT override it.
   Change every \`load_dotenv()\` call to:
   \`\`\`python
   load_dotenv(override=True)
   \`\`\`

4. **Set \`ANTHROPIC_BASE_URL\`** — \`ANTHROPIC_BASE_URL\` is set to a proxy in this
   container. Add this line to \`.env\`:
   \`\`\`
   ANTHROPIC_BASE_URL=https://api.anthropic.com
   \`\`\`
   \`load_dotenv(override=True)\` from step 3 will restore it.
"
    fi

    # Detect Go project
    if [[ -f "${PROJECT}/go.mod" ]]; then
        content+="
## Go Environment

\`go build\` produces **Linux arm64** binaries that will not run on macOS.
To avoid overwriting host binaries, use a platform-specific output directory:

\`\`\`bash
go build -o ./bin/linux/ .
\`\`\`
"
    fi

    echo "$content" > "$md"
    log "Generated $md (detected: $(cd "$PROJECT" && ls pyproject.toml go.mod 2>/dev/null | tr '\n' ' ' || echo 'generic'))"
}

generate_container_md

log "Attaching claude-agent-acp via exec..."
exec container exec -i \
    "${EXEC_ENV[@]}" \
    -w "${PROJECT}" \
    "$CONTAINER_NAME" \
    /home/sandbox/.local/bin/claude-agent-acp
