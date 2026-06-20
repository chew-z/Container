#!/usr/bin/env bash
# cleanup.sh — manage all Claude Code containers, images, and builder cache
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
    _dir="$(cd "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

GLOBAL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/container"

# Container prefixes managed by this toolkit
PREFIXES=("claude-")
MACHINE_PREFIX="claude-machine-"
IMAGE_PREFIX="claudecode"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Manage Claude Code containers (claude-*), images, and builder cache.

Containers:
  --list                  List all containers and their status (default)
  --stop [NAME]           Stop a specific container, or all if no name given
  --remove [NAME]         Delete a specific stopped container, or all stopped
  --prune                 Stop and delete all containers

Images:
  --images                List claudecode-* images with sizes
  --images --prune        Delete all claudecode-* images

Builder cache:
  --builder-clear-cache   Stop and delete the builder (clears BuildKit layer cache)
  --builder-restart       Clear cache and restart builder with configured resources

Full cleanup:
  --full-cleanup          Stop/remove all containers + delete images + clear builder cache
  --disk-usage            Show container system disk usage

Machines:
  --machines                List all claude-machine-* machines
  --machines --stop [NAME]  Stop a machine, or all if no name given
  --machines --remove [NAME] Delete a machine, or all stopped
  --machines --prune        Stop and delete all machines

Other:
  -h, --help              Show this help and exit
EOF
}

# ── TOML reader (copied from launch.sh) ──────────────────────────────────────
toml_get() {
    local section="$1"
    local key="$2"
    local file="$3"
    awk -v section="$section" -v key="$key" '
        function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
        function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
        function trim(s) { return rtrim(ltrim(s)) }

        /^[ \t]*#/ { next }
        /^[ \t]*\[/ {
            in_section = ($0 ~ "^[ \\t]*\\[" section "\\][ \\t]*$")
            next
        }

        in_section {
            line = $0
            if (line ~ "^[ \\t]*" key "[ \\t]*=") {
                sub(/^[^=]*=/, "", line)
                line = trim(line)
                if (line ~ /^"/) {
                    sub(/^"/, "", line)
                    sub(/".*/, "", line)
                } else {
                    sub(/[ \t]*#.*$/, "", line)
                    line = rtrim(line)
                }
                print line
                exit
            }
        }
    ' "$file"
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

ensure_system_running() {
    if container system status &>/dev/null; then
        return 0
    fi
    printf "Container system service is not running. Start it now? [Y/n] "
    read -r answer
    if [[ "${answer,,}" =~ ^(y|yes)?$ ]]; then
        echo "Starting container system service..."
        container system start
        sleep 2
    else
        echo "Container system service is required. Start it with: container system start"
        exit 1
    fi
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
        is_managed "$name" && echo "$name" || true
    done
}

container_status() {
    local name="$1"
    local state
    state="$(cached_containers_json | jq -r --arg n "$name" '.[] | select(.configuration.id == $n) | .status.state // "unknown"')"
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
        echo "claudecode-* images:"
        container image list --verbose 2>/dev/null | head -1
        container image list --verbose 2>/dev/null | grep "^${IMAGE_PREFIX}" || true
    fi
}

# ── Builder cache ─────────────────────────────────────────────────────────────
cmd_builder_clear_cache() {
    echo "Stopping builder..."
    container builder stop 2>/dev/null || true
    echo "Deleting builder (clears build cache)..."
    container builder delete 2>/dev/null || true
    echo "Builder cache cleared."
}

cmd_builder_restart() {
    cmd_builder_clear_cache
    local cfg
    if [[ -n "${CONTAINER_BUILD_CONFIG:-}" ]]; then
        cfg="$CONTAINER_BUILD_CONFIG"
    elif [[ -f "$GLOBAL_CONFIG_DIR/container-build.toml" ]]; then
        cfg="$GLOBAL_CONFIG_DIR/container-build.toml"
    else
        cfg="$SCRIPT_DIR/container-build.toml"
    fi
    local build_cpus=2 build_memory="4g"
    if [[ -f "$cfg" ]]; then
        local _cpus _mem
        _cpus="$(toml_get builder cpus "$cfg" || true)"
        _mem="$(toml_get builder memory "$cfg" || true)"
        build_cpus="${_cpus:-2}"
        build_memory="${_mem:-4g}"
    fi
    echo "Restarting builder (${build_cpus} CPUs, ${build_memory} memory)..."
    container builder start --cpus "$build_cpus" --memory "$build_memory"
}

# ── Full cleanup ─────────────────────────────────────────────────────────────
cmd_full_cleanup() {
    cmd_prune
    echo ""
    cmd_machines_prune
    echo ""
    cmd_images --prune
    echo ""
    cmd_builder_clear_cache
}

# ── Machine helpers ──────────────────────────────────────────────────────────
get_managed_machines() {
    container machine list --quiet 2>/dev/null | grep "^${MACHINE_PREFIX}" || true
}

machine_status() {
    local name="$1"
    container machine list --format json 2>/dev/null \
        | jq -r --arg n "$name" '.[] | select(.id == $n) | .status // "unknown"' 2>/dev/null \
        || echo "unknown"
}

cmd_machines_list() {
    local machines
    machines="$(get_managed_machines)"
    if [[ -z "$machines" ]]; then
        echo "No machines found."
        return
    fi
    printf "%-35s  %-10s\n" "MACHINE" "STATUS"
    printf "%-35s  %-10s\n" "-------" "------"
    while IFS= read -r name; do
        printf "%-35s  %-10s\n" "$name" "$(machine_status "$name")"
    done <<< "$machines"
}

cmd_machines_stop() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        echo "Stopping machine: $target"
        container machine stop "$target" 2>/dev/null && echo "  stopped" || echo "  already stopped"
        return
    fi
    local machines
    machines="$(get_managed_machines)"
    [[ -z "$machines" ]] && { echo "No machines found."; return; }
    while IFS= read -r name; do
        echo "Stopping machine: $name"
        container machine stop "$name" 2>/dev/null && echo "  stopped" || echo "  already stopped"
    done <<< "$machines"
}

cmd_machines_remove() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        echo "Deleting machine: $target"
        container machine delete "$target" 2>/dev/null && echo "  deleted" || echo "  failed"
        return
    fi
    local machines
    machines="$(get_managed_machines)"
    [[ -z "$machines" ]] && { echo "No machines found."; return; }
    while IFS= read -r name; do
        echo "Deleting machine: $name"
        container machine delete "$name" 2>/dev/null && echo "  deleted" || echo "  failed"
    done <<< "$machines"
}

cmd_machines_prune() {
    cmd_machines_stop
    echo ""
    cmd_machines_remove
}

# ── Disk usage ───────────────────────────────────────────────────────────────
cmd_disk_usage() {
    container system df
}

# ── Main ──────────────────────────────────────────────────────────────────────
COMMAND="${1:---list}"

# Ensure service is running for all commands except --help
if [[ "$COMMAND" != "-h" && "$COMMAND" != "--help" ]]; then
    ensure_system_running
fi

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
    --builder-clear-cache)
        cmd_builder_clear_cache
        ;;
    --builder-restart)
        cmd_builder_restart
        ;;
    --full-cleanup)
        cmd_full_cleanup
        ;;
    --disk-usage)
        cmd_disk_usage
        ;;
    --machines)
        case "${2:-}" in
            --stop)
                cmd_machines_stop "${3:-}"
                ;;
            --remove)
                cmd_machines_remove "${3:-}"
                ;;
            --prune)
                cmd_machines_prune
                ;;
            *)
                cmd_machines_list
                ;;
        esac
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
