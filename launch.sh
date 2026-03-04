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
LANG_TARGET="${CONTAINER_LANG:-python}"
EXTRA_CLAUDE_ARGS=()

BUILD_CPUS="${BUILD_CPUS:-2}"
BUILD_MEMORY="${BUILD_MEMORY:-4g}"
CONFIG_FILE="${CONTAINER_BUILD_CONFIG:-$SCRIPT_DIR/container-build.toml}"

RUN_MEMORY=""
RUN_CPUS=""

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
  --lang LANG              Language target: python (default) or golang
  --memory SIZE            Container memory (e.g., 4g, 8g). Overrides config/defaults
  --cpus N                 Container CPUs. Overrides config/defaults
  --rw                     Mount workspace read-write directly (live, no isolation)
  --config PATH            Build config file (default: ./container-build.toml)
  --                       Pass remaining arguments to claude inside the container

Environment:
  CONTAINER_LANG           Language target (default: python)
  BUILD_CPUS               CPUs for builder (default: 2)
  BUILD_MEMORY             Memory for builder (default: 4g)
  CONTAINER_BUILD_CONFIG   Build config path override
  CONTAINER_RUN_CONFIG     Per-project runtime config path override
  CLAUDE_CODE_SIMPLE       Set to 1 (default via claude_simple_mode in config)
                           to disable hooks, MCP servers, attachments, and
                           CLAUDE.md files inside the container.
                           To disable: set claude_simple_mode = false in
                           container-build.toml (requires Python 3.12+ and uv
                           for hooks)

Config (container-build.toml [features]):
  skip_permissions         "yolo" (default): --dangerously-skip-permissions
                           "plan": --permission-mode plan
                                   --allow-dangerously-skip-permissions
                           false:  normal interactive prompts
EOF
}

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
                if (line ~ /^".*"$/) {
                    sub(/^"/, "", line)
                    sub(/"$/, "", line)
                }
                print line
                exit
            }
        }
    ' "$file"
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
        --config)
            CONFIG_FILE="${2:?--config requires a path}"
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
        --lang)
            LANG_TARGET="${2:?--lang requires python or golang}"
            shift 2
            ;;
        --memory)
            RUN_MEMORY="${2:?--memory requires a size (e.g., 4g)}"
            shift 2
            ;;
        --cpus)
            RUN_CPUS="${2:?--cpus requires a number}"
            shift 2
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

if [[ "$LANG_TARGET" != "python" && "$LANG_TARGET" != "golang" ]]; then
    echo "ERROR: Unsupported language target '$LANG_TARGET'. Use 'python' or 'golang'." >&2
    exit 1
fi

# ── Resolve paths ─────────────────────────────────────────────────────────────
PROJECT="$(cd "$PROJECT" && pwd)"

# ── Derive names from project basename ────────────────────────────────────────
project_slug() {
    basename "$1" | tr -cs 'a-zA-Z0-9._-' '-' | sed 's/^-*//;s/-*$//' | tr '[:upper:]' '[:lower:]'
}

SLUG="$(project_slug "$PROJECT")"
[[ -z "$SLUG" ]] && SLUG="sandbox"
IMAGE="claudecode-${LANG_TARGET}"
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
    local cfg="$CONFIG_FILE"

    local fd_version gh_version claude_code_version claude_agent_acp_version
    local python_version go_version golangci_lint_version install_acp_raw install_acp

    fd_version="10.3.0"
    gh_version="2.87.3"
    claude_code_version="latest"
    claude_agent_acp_version="latest"
    python_version="3.14"
    go_version="1.26.0"
    golangci_lint_version="v2.4.0"
    install_acp="0"

    if [[ -f "$cfg" ]]; then
        fd_version="$(toml_get versions fd "$cfg" || true)"
        gh_version="$(toml_get versions gh "$cfg" || true)"
        claude_code_version="$(toml_get versions claude_code "$cfg" || true)"
        claude_agent_acp_version="$(toml_get versions claude_agent_acp "$cfg" || true)"
        python_version="$(toml_get versions python "$cfg" || true)"
        go_version="$(toml_get versions go "$cfg" || true)"
        golangci_lint_version="$(toml_get versions golangci_lint "$cfg" || true)"
        install_acp_raw="$(toml_get features install_claude_agent_acp "$cfg" || true)"

        fd_version="${fd_version:-10.3.0}"
        gh_version="${gh_version:-2.87.3}"
        claude_code_version="${claude_code_version:-latest}"
        claude_agent_acp_version="${claude_agent_acp_version:-latest}"
        python_version="${python_version:-3.14}"
        go_version="${go_version:-1.26.0}"
        golangci_lint_version="${golangci_lint_version:-v2.4.0}"

        case "${install_acp_raw,,}" in
            true|1|yes|on) install_acp="1" ;;
            *) install_acp="0" ;;
        esac

    else
        echo "WARNING: Build config '$cfg' not found. Using built-in defaults." >&2
    fi

    echo "==> Starting builder..."
    container builder start --cpus "$BUILD_CPUS" --memory "$BUILD_MEMORY"
    echo "==> Building image: $IMAGE (target: $LANG_TARGET, config: $cfg)"
    container build -t "$IMAGE" \
        --target "$LANG_TARGET" \
        --arch arm64 \
        --build-arg "FD_VERSION=$fd_version" \
        --build-arg "GH_VERSION=$gh_version" \
        --build-arg "CLAUDE_CODE_VERSION=$claude_code_version" \
        --build-arg "CLAUDE_AGENT_ACP_VERSION=$claude_agent_acp_version" \
        --build-arg "INSTALL_CLAUDE_AGENT_ACP=$install_acp" \
        --build-arg "PYTHON_VERSION=$python_version" \
        --build-arg "GO_VERSION=$go_version" \
        --build-arg "GOLANGCI_LINT_VERSION=$golangci_lint_version" \
        "$TEMPLATE_DIR"
    echo "==> Build complete."
}

ensure_system_running

if [[ "$REBUILD" == "1" ]]; then
    build_image
elif ! image_exists; then
    echo "ERROR: Image '$IMAGE' not found. Run with --rebuild to build it first." >&2
    exit 1
fi

# ── Read runtime flags from config ────────────────────────────────────────────
CLAUDE_SIMPLE_MODE="1"
SKIP_PERMISSIONS="yolo"
if [[ -f "$CONFIG_FILE" ]]; then
    _simple_raw="$(toml_get features claude_simple_mode "$CONFIG_FILE" || true)"
    case "${_simple_raw,,}" in
        false|0|no|off) CLAUDE_SIMPLE_MODE="0" ;;
    esac
    _skip_raw="$(toml_get features skip_permissions "$CONFIG_FILE" || true)"
    case "${_skip_raw,,}" in
        yolo|true|1|yes|on) SKIP_PERMISSIONS="yolo" ;;
        plan)               SKIP_PERMISSIONS="plan" ;;
        false|0|no|off)     SKIP_PERMISSIONS="off" ;;
        *)                  SKIP_PERMISSIONS="yolo" ;;
    esac
fi

# ── Read per-project runtime config ──────────────────────────────────────────
PROJECT_RUN_CONFIG="${CONTAINER_RUN_CONFIG:-$PROJECT/container-run.toml}"
if [[ -f "$PROJECT_RUN_CONFIG" ]]; then
    [[ -z "$RUN_MEMORY" ]] && RUN_MEMORY="$(toml_get resources memory "$PROJECT_RUN_CONFIG" || true)"
    [[ -z "$RUN_CPUS" ]]   && RUN_CPUS="$(toml_get resources cpus "$PROJECT_RUN_CONFIG" || true)"
fi

# Defaults (CLI flags > container-run.toml > defaults)
RUN_MEMORY="${RUN_MEMORY:-2g}"
RUN_CPUS="${RUN_CPUS:-4}"

# Compose permission flags for claude
case "$SKIP_PERMISSIONS" in
    yolo)
        EXTRA_CLAUDE_ARGS=("--dangerously-skip-permissions" "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")
        ;;
    plan)
        EXTRA_CLAUDE_ARGS=("--permission-mode" "plan" "--allow-dangerously-skip-permissions" "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")
        ;;
esac

# Inject system prompt to ensure Claude reads CONTAINER.md at session start
EXTRA_CLAUDE_ARGS=("--append-system-prompt" "You MUST read CONTAINER.md in the workspace root before doing anything else." "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")

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

# ── Extract GitHub CLI token from macOS Keychain ─────────────────────────────
GH_TOKEN=""
GH_TOKEN_RAW="$(security find-generic-password -s "gh:github.com" -w 2>/dev/null || true)"
if [[ "$GH_TOKEN_RAW" == go-keyring-base64:* ]]; then
    GH_TOKEN="$(echo "${GH_TOKEN_RAW#go-keyring-base64:}" | base64 -d)"
elif [[ -n "$GH_TOKEN_RAW" ]]; then
    GH_TOKEN="$GH_TOKEN_RAW"
fi

# ── Run container ─────────────────────────────────────────────────────────────
echo "==> Launching Claude Code for: $PROJECT"
echo "==> Container: $CONTAINER_NAME"
echo "==> Image: $IMAGE"
echo "==> Resources: ${RUN_MEMORY} memory, ${RUN_CPUS} CPUs"

RUN_ARGS=(
    container run -it --rm
    --name "$CONTAINER_NAME"
    --arch arm64
    --memory "$RUN_MEMORY"
    --cpus "$RUN_CPUS"
    --mount "$WORKSPACE_MOUNT"
    --mount "type=bind,source=${HOME}/.claude,target=/mnt/in/claude_dir,readonly"
    --mount "type=bind,source=${HOME},target=/mnt/in/home,readonly"
    -e "HOME=/home/sandbox"
    -e "CLAUDE_CREDS=${CLAUDE_CREDS}"
    -e "SANDBOX_COPY_MODE=${COPY_MODE}"
    -e "CLAUDE_AUTO_UPDATE=${CLAUDE_AUTO_UPDATE}"
    -e "ANTHROPIC_API_KEY="
    -e "GH_TOKEN=${GH_TOKEN}"
)

if [[ "$CLAUDE_SIMPLE_MODE" == "1" ]]; then
    RUN_ARGS+=(-e "CLAUDE_CODE_SIMPLE=1")
fi

RUN_ARGS+=("$IMAGE" "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")

exec "${RUN_ARGS[@]}"
