#!/usr/bin/env bash
# cleanup.sh — manage all Claude Code containers and images
set -euo pipefail

# Container prefixes managed by this toolkit
PREFIXES=("claude-" "zed-")
IMAGE_PREFIX="claudecode"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Manage Claude Code containers (claude-*, zed-*) and images (claudecode-*).

Commands:
  --list              List all containers and their status (default)
  --stop [NAME]       Stop a specific container, or all if no name given
  --remove [NAME]     Delete a specific stopped container, or all stopped
  --prune             Stop and delete all containers
  --images            List claudecode-* images
  --images --prune    Delete all claudecode-* images
  -h, --help          Show this help and exit
EOF
}

# ── Helpers ───────────────────────────────────────────────────────────────────
TIMEOUT=10  # seconds — container CLI hangs on corrupted/stopped containers

is_managed() {
    local name="$1"
    for prefix in "${PREFIXES[@]}"; do
        [[ "$name" == "${prefix}"* ]] && return 0
    done
    return 1
}

get_containers_json() {
    container list --all --format json 2>/dev/null || echo "[]"
}

# Cache the JSON once per invocation — avoids repeated `container list` calls
CONTAINERS_JSON=""
cached_containers_json() {
    if [[ -z "$CONTAINERS_JSON" ]]; then
        CONTAINERS_JSON="$(get_containers_json)"
    fi
    echo "$CONTAINERS_JSON"
}

get_managed_containers() {
    cached_containers_json | jq -r '.[].configuration.id' | while IFS= read -r name; do
        is_managed "$name" && echo "$name"
    done
}

container_status() {
    local name="$1"
    local state
    state="$(cached_containers_json | jq -r --arg n "$name" '.[] | select(.configuration.id == $n) | .status // "unknown"')"
    echo "${state:-unknown}"
}

# ── List ──────────────────────────────────────────────────────────────────────
cmd_list() {
    local containers
    containers="$(get_managed_containers)"
    if [[ -z "$containers" ]]; then
        echo "No containers found."
        return
    fi
    printf "%-30s  %-10s\n" "CONTAINER" "STATUS"
    printf "%-30s  %-10s\n" "---------" "------"
    while IFS= read -r name; do
        printf "%-30s  %-10s\n" "$name" "$(container_status "$name")"
    done <<< "$containers"
}

# ── Stop ──────────────────────────────────────────────────────────────────────
cmd_stop() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        echo "Stopping: $target"
        timeout "$TIMEOUT" container stop "$target" 2>/dev/null && echo "  stopped" || echo "  already stopped"
        return
    fi
    local containers
    containers="$(get_managed_containers)"
    if [[ -z "$containers" ]]; then
        echo "No containers found."
        return
    fi
    while IFS= read -r name; do
        echo "Stopping: $name"
        timeout "$TIMEOUT" container stop "$name" 2>/dev/null && echo "  stopped" || echo "  already stopped"
    done <<< "$containers"
}

# ── Remove ────────────────────────────────────────────────────────────────────
cmd_remove() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        if [[ "$(container_status "$target")" == "running" ]]; then
            echo "Container '$target' is running. Stop it first (--stop $target)."
            return 1
        fi
        echo "Deleting: $target"
        timeout "$TIMEOUT" container delete "$target" 2>/dev/null && echo "  deleted" || echo "  failed (hung — may need: container delete --all --force)"
        return
    fi
    local containers
    containers="$(get_managed_containers)"
    if [[ -z "$containers" ]]; then
        echo "No containers found."
        return
    fi
    while IFS= read -r name; do
        if [[ "$(container_status "$name")" == "running" ]]; then
            echo "Skipping (running): $name"
        else
            echo "Deleting: $name"
            timeout "$TIMEOUT" container delete "$name" 2>/dev/null && echo "  deleted" || echo "  failed (hung — may need: container delete --all --force)"
        fi
    done <<< "$containers"
}

# ── Prune ─────────────────────────────────────────────────────────────────────
cmd_prune() {
    cmd_stop
    echo ""
    cmd_remove
}

# ── Images ────────────────────────────────────────────────────────────────────
get_managed_images() {
    container image list 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | grep "^${IMAGE_PREFIX}" \
        || true
}

cmd_images() {
    local do_prune="${1:-}"
    local images
    images="$(get_managed_images)"
    if [[ -z "$images" ]]; then
        echo "No claudecode-* images found."
        return
    fi
    if [[ "$do_prune" == "--prune" ]]; then
        while IFS= read -r img; do
            echo "Deleting image: $img"
            container image rm "$img" 2>/dev/null && echo "  deleted" || echo "  failed (in use?)"
        done <<< "$images"
    else
        printf "%-40s\n" "IMAGE"
        printf "%-40s\n" "-----"
        while IFS= read -r img; do
            echo "$img"
        done <<< "$images"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
COMMAND="${1:---list}"

case "$COMMAND" in
    --list|-l)
        cmd_list
        ;;
    --stop)
        cmd_stop "${2:-}"
        ;;
    --remove)
        cmd_remove "${2:-}"
        ;;
    --prune)
        cmd_prune
        ;;
    --images)
        cmd_images "${2:-}"
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
esac
