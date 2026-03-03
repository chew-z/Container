#!/usr/bin/env bash
# launch.sh — run Claude Code interactively in a sandbox container
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"
PROJECT="$PWD"
REBUILD=0
COPY_MODE=1
CLAUDE_AUTO_UPDATE=0
EXTRA_CLAUDE_ARGS=()

BUILD_CPUS="${BUILD_CPUS:-4}"
BUILD_MEMORY="${BUILD_MEMORY:-12g}"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- CLAUDE_ARGS...]

Run Claude Code interactively inside a sandboxed container.

Options:
  -h, --help               Show this help and exit
  -C, --project PATH       Project directory to mount (default: \$PWD)
  --template-dir DIR       Directory containing Dockerfile and entrypoint.sh
                           (default: directory containing this script)
  --rebuild                Rebuild the container image before running
  --update-claude          Allow Claude to auto-update inside the container
  --rw                     Mount workspace read-write directly (live, no isolation)
  --                       Pass remaining arguments to claude inside the container

Environment:
  BUILD_CPUS               CPUs for builder (default: 4)
  BUILD_MEMORY             Memory for builder (default: 12g)
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
        --template-dir)
            TEMPLATE_DIR="${2:?--template-dir requires a path}"
            shift 2
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        --update-claude)
            CLAUDE_AUTO_UPDATE=1
            shift
            ;;
        --rw)
            COPY_MODE=0
            shift
            ;;
        --)
            shift
            EXTRA_CLAUDE_ARGS=("$@")
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Resolve paths ─────────────────────────────────────────────────────────────
PROJECT="$(cd "$PROJECT" && pwd)"

# ── Derive image name from project basename ───────────────────────────────────
image_slug() {
    basename "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/^-*//;s/-*$//'
}

SLUG="$(image_slug "$PROJECT")"
[[ -z "$SLUG" ]] && SLUG="sandbox"
IMAGE="claudecode-${SLUG}"

# ── Derive container name ─────────────────────────────────────────────────────
CONTAINER_NAME="claude-${SLUG}"

# ── Check image exists ────────────────────────────────────────────────────────
image_exists() {
    container image list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$IMAGE"
}

# ── Build image ───────────────────────────────────────────────────────────────
ensure_system_running() {
    if ! container list &>/dev/null; then
        echo "==> Starting container system service..."
        container system start
    fi
}

build_image() {
    ensure_system_running
    echo "==> Starting builder..."
    container builder start --cpus "$BUILD_CPUS" --memory "$BUILD_MEMORY"
    echo "==> Building image: $IMAGE"
    container build -t "$IMAGE" --arch arm64 "$TEMPLATE_DIR"
    echo "==> Build complete."
}

ensure_system_running

if [[ "$REBUILD" == "1" ]]; then
    build_image
elif ! image_exists; then
    echo "ERROR: Image '$IMAGE' not found. Run with --rebuild to build it first." >&2
    exit 1
fi

# ── Construct mount arguments ─────────────────────────────────────────────────
if [[ "$COPY_MODE" == "1" ]]; then
    WORKSPACE_MOUNT="type=bind,source=${PROJECT},target=/mnt/in/workspace,readonly"
else
    WORKSPACE_MOUNT="type=bind,source=${PROJECT},target=/workspace"
fi

# ── Extract OAuth credentials from macOS Keychain (full JSON blob) ────────────
CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [[ -z "$CLAUDE_CREDS" ]]; then
    echo "WARNING: Could not extract credentials from Keychain." >&2
fi

# ── Run container ─────────────────────────────────────────────────────────────
echo "==> Launching Claude Code for: $PROJECT"
echo "==> Container: $CONTAINER_NAME"
echo "==> Image: $IMAGE"

exec container run -it --rm \
    --name "$CONTAINER_NAME" \
    --arch arm64 \
    --mount "$WORKSPACE_MOUNT" \
    --mount "type=bind,source=${HOME}/.claude,target=/mnt/in/claude_dir,readonly" \
    --mount "type=bind,source=${HOME},target=/mnt/in/home,readonly" \
    -e "HOME=/home/sandbox" \
    -e "CLAUDE_CREDS=${CLAUDE_CREDS}" \
    -e "SANDBOX_COPY_MODE=${COPY_MODE}" \
    -e "CLAUDE_AUTO_UPDATE=${CLAUDE_AUTO_UPDATE}" \
    "$IMAGE" \
    "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}"
