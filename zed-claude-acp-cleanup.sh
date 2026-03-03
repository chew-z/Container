#!/usr/bin/env bash
# zed-claude-acp-cleanup.sh — manage persistent ACP containers
#
# Targets containers with the prefix "claude-acp-".
set -euo pipefail

ACP_PREFIX="claude-acp-"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Manage persistent Claude ACP containers (prefix: ${ACP_PREFIX}).

Commands:
  --list            List all ACP containers and their status (default)
  --stop-all        Stop all running ACP containers
  --remove-stopped  Delete all stopped ACP containers
  --prune           Stop all running + delete all stopped ACP containers
  -h, --help        Show this help and exit
EOF
}

# ── List ACP containers ───────────────────────────────────────────────────────
list_containers() {
    echo "ACP containers (prefix: ${ACP_PREFIX}):"
    echo ""
    local out
    out="$(container list --all --format json 2>/dev/null \
        | jq -r '.[] | [.configuration.id, .status] | @tsv' \
        | grep "^${ACP_PREFIX}" \
        | column -t)"
    if [[ -z "$out" ]]; then
        echo "  (none found)"
    else
        echo "$out"
    fi
}

# ── Get all ACP container names ───────────────────────────────────────────────
get_acp_containers() {
    container list --all --format json 2>/dev/null \
        | jq -r '.[].configuration.id' \
        | grep "^${ACP_PREFIX}" \
        || true
}

# ── Stop all running ACP containers ──────────────────────────────────────────
stop_all() {
    local containers
    containers="$(get_acp_containers)"
    if [[ -z "$containers" ]]; then
        echo "No ACP containers found."
        return
    fi
    echo "Stopping ACP containers..."
    while IFS= read -r name; do
        echo "  Stopping: $name"
        container stop "$name" 2>/dev/null && echo "    -> stopped" || echo "    -> already stopped or failed"
    done <<< "$containers"
}

# ── Remove stopped ACP containers ────────────────────────────────────────────
remove_stopped() {
    local containers
    containers="$(get_acp_containers)"
    if [[ -z "$containers" ]]; then
        echo "No ACP containers found."
        return
    fi
    echo "Removing stopped ACP containers..."
    while IFS= read -r name; do
        # Check if container is stopped (not running)
        if ! container exec "$name" true 2>/dev/null; then
            echo "  Deleting: $name"
            container delete "$name" 2>/dev/null && echo "    -> deleted" || echo "    -> failed"
        else
            echo "  Skipping (running): $name"
        fi
    done <<< "$containers"
}

# ── Main ──────────────────────────────────────────────────────────────────────
COMMAND="${1:---list}"

case "$COMMAND" in
    --list|-l)
        list_containers
        ;;
    --stop-all)
        stop_all
        ;;
    --remove-stopped)
        remove_stopped
        ;;
    --prune)
        stop_all
        echo ""
        remove_stopped
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
esac
