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
IMAGE="claudecode"
CONTAINER_NAME="zed-${SLUG}"

# ── Extract OAuth credentials from macOS Keychain (full JSON blob) ────────────
CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [[ -z "$CLAUDE_CREDS" ]]; then
    log "WARNING: Could not extract credentials from Keychain."
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
        'mkdir -p /home/sandbox/.claude && \
         cp -a /mnt/in/claude_dir/. /home/sandbox/.claude/ && \
         cp /mnt/in/home/.claude.json /home/sandbox/.claude.json 2>/dev/null || true'
    # Write credentials file (Linux plaintext fallback for Keychain)
    if [[ -n "${CLAUDE_CREDS:-}" ]]; then
        log "Writing credentials file into container..."
        container exec "$CONTAINER_NAME" /bin/bash -c \
            "mkdir -p /home/sandbox/.claude && \
             cat > /home/sandbox/.claude/.credentials.json << 'CREDS_EOF'
${CLAUDE_CREDS}
CREDS_EOF
chmod 600 /home/sandbox/.claude/.credentials.json"
    fi
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
        /bin/bash -c "$watchdog"

    container start "$CONTAINER_NAME"
    log "Container started."
    setup_container_config
}

# ── Container lifecycle management ────────────────────────────────────────────
ensure_container_running() {
    # Case 1: Container is already running — refresh credentials (tokens expire)
    if container exec "$CONTAINER_NAME" true 2>/dev/null; then
        log "Container already running: $CONTAINER_NAME"
        setup_container_config
        return 0
    fi

    # Case 2: Container exists but is stopped — try to start it
    if container start "$CONTAINER_NAME" 2>/dev/null; then
        log "Started existing container: $CONTAINER_NAME"
        sleep 1
        setup_container_config
        return 0
    fi

    # Case 3: Container does not exist — create fresh
    if create_container 2>/dev/null; then
        return 0
    fi

    # Case 4: Stale/broken container — force delete and recreate
    log "Removing stale container: $CONTAINER_NAME"
    container delete --force "$CONTAINER_NAME" 2>/dev/null || true
    create_container
}

# ── Main ──────────────────────────────────────────────────────────────────────
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
)
# Forward host env vars (typically set via Zed agent_servers.env config)
for var in ANTHROPIC_BASE_URL API_TIMEOUT_MS \
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
           CLAUDE_CODE_SIMPLE DISABLE_NON_ESSENTIAL_MODEL_CALLS \
           MAX_THINKING_TOKENS; do
    [[ -n "${!var:-}" ]] && EXEC_ENV+=(-e "${var}=${!var}")
done

log "Attaching claude-agent-acp via exec..."
exec container exec -i \
    "${EXEC_ENV[@]}" \
    -w "${PROJECT}" \
    "$CONTAINER_NAME" \
    /home/sandbox/.local/bin/claude-agent-acp
