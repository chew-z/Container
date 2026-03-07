#!/usr/bin/env bash
# launch.sh — run Claude Code interactively in a sandbox container
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"
PROJECT="$PWD"
REBUILD=0
FRESH_BUILD=0
COPY_MODE=1
CLAUDE_AUTO_UPDATE=0
LANG_TARGET="${CONTAINER_LANG:-python}"
EXTRA_CLAUDE_ARGS=()

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
  --rebuild                Smart rebuild — resolves "latest" versions, uses cache
  --full-rebuild           Complete no-cache rebuild from scratch
  --update-claude          Allow Claude to auto-update inside the container
  --lang LANG              Language target: python (default) or golang
  --memory SIZE            Container memory (e.g., 4g, 8g). Overrides config/defaults
  --cpus N                 Container CPUs. Overrides config/defaults
  --rw                     Mount workspace read-write directly (live, no isolation)
  --config PATH            Build config file (default: ./container-build.toml)
  --                       Pass remaining arguments to claude inside the container

Environment:
  CONTAINER_LANG           Language target (default: python)
  BUILD_CPUS               CPUs for builder (overrides [builder] config)
  BUILD_MEMORY             Memory for builder (overrides [builder] config)
  CONTAINER_BUILD_CONFIG   Build config path override
  CONTAINER_RUN_CONFIG     Per-project runtime config path override
  CLAUDE_CODE_SIMPLE       Set to 1 (default via claude_simple_mode in config)
                           to disable hooks, MCP servers, attachments, and
                           CLAUDE.md files inside the container.
                           To disable: set claude_simple_mode = false in
                           container-run.toml (requires Python 3.12+ and uv
                           for hooks)

Config (container-run.toml [claude]):
  claude_simple_mode       true (default): lean runtime — no hooks, MCP, CLAUDE.md
                           false: full-featured (needs Python 3.12+ and uv)
  claude_skip_permissions  "yolo" (default): --dangerously-skip-permissions
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
                if (line ~ /^"/) {
                    # Quoted value: extract content between first pair of quotes
                    sub(/^"/, "", line)
                    sub(/".*/, "", line)
                } else {
                    # Unquoted value: strip everything from first # onward
                    sub(/[ \t]*#.*$/, "", line)
                    line = rtrim(line)
                }
                print line
                exit
            }
        }
    ' "$file"
}

toml_get_array() {
    local section="$1"
    local key="$2"
    local file="$3"
    local raw
    raw="$(awk -v section="$section" -v key="$key" '
        function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
        function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
        function trim(s) { return rtrim(ltrim(s)) }

        /^[ \t]*#/ { next }
        /^[ \t]*\[/ {
            in_section = ($0 ~ "^[ \\t]*\\[" section "\\][ \\t]*$")
            next
        }

        in_section && accumulating {
            line = $0
            # Strip inline comments
            sub(/#.*$/, "", line)
            buf = buf " " trim(line)
            if (buf ~ /\]/) {
                print buf
                exit
            }
            next
        }

        in_section {
            line = $0
            if (line ~ "^[ \\t]*" key "[ \\t]*=") {
                sub(/^[^=]*=/, "", line)
                line = trim(line)
                # Strip inline comment outside the array
                sub(/\][ \t]*#.*$/, "]", line)
                if (line ~ /\[/ && line !~ /\]/) {
                    # Opening bracket but no closing — multi-line array
                    buf = line
                    accumulating = 1
                    next
                }
                print line
                exit
            }
        }
    ' "$file")"

    [[ -z "$raw" ]] && return

    # Strip surrounding brackets and split on comma
    raw="${raw#\[}"
    raw="${raw%\]}"
    local IFS=','
    for elem in $raw; do
        elem="$(echo "$elem" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"
        [[ -n "$elem" ]] && printf '%s\n' "$elem"
    done
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
        --full-rebuild)
            FRESH_BUILD=1
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

    # Builder resources: env var > TOML [builder] > hardcoded default
    local build_cpus="${BUILD_CPUS:-}"
    local build_memory="${BUILD_MEMORY:-}"
    if [[ -f "$cfg" ]]; then
        [[ -z "$build_cpus" ]]   && build_cpus="$(toml_get builder cpus "$cfg" || true)"
        [[ -z "$build_memory" ]] && build_memory="$(toml_get builder memory "$cfg" || true)"
    fi
    build_cpus="${build_cpus:-2}"
    build_memory="${build_memory:-4g}"

    # ── Resolve "latest" on host so BuildKit sees a new cache key ──────────
    local CLAUDE_CODE_GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

    if [[ "$claude_code_version" == "latest" ]]; then
        claude_code_version="$(curl -fsSL --retry 3 --retry-delay 2 "$CLAUDE_CODE_GCS/latest")"
        echo "==> Resolved Claude Code latest -> v${claude_code_version}"
    fi

    if [[ "$install_acp" == "1" && "$claude_agent_acp_version" == "latest" ]]; then
        claude_agent_acp_version="$(curl -fsSL --retry 3 --retry-delay 2 \
            "https://api.github.com/repos/zed-industries/claude-agent-acp/releases/latest" | jq -r '.tag_name')"
        echo "==> Resolved claude-agent-acp latest -> ${claude_agent_acp_version}"
    fi

    # ── Build ────────────────────────────────────────────────────────────────
    local no_cache_flag=""
    [[ "$FRESH_BUILD" == "1" ]] && no_cache_flag="--no-cache"

    echo "==> Starting builder..."
    container builder start --cpus "$build_cpus" --memory "$build_memory"
    echo "==> Building image: $IMAGE (target: $LANG_TARGET, config: $cfg)"
    container build $no_cache_flag -t "$IMAGE" \
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

# ── Read per-project runtime config ──────────────────────────────────────────
PROJECT_RUN_CONFIG="${CONTAINER_RUN_CONFIG:-$PROJECT/container-run.toml}"
CLAUDE_SIMPLE_MODE="1"
SKIP_PERMISSIONS="yolo"
EXTRA_EXCLUDES=""
SSH_KNOWN_HOSTS=""
CONTAINER_TZ=""
CLAUDE_ADDITIONAL_SYSTEM_PROMPT=""
if [[ -f "$PROJECT_RUN_CONFIG" ]]; then
    [[ -z "$RUN_MEMORY" ]] && RUN_MEMORY="$(toml_get resources memory "$PROJECT_RUN_CONFIG" || true)"
    [[ -z "$RUN_CPUS" ]]   && RUN_CPUS="$(toml_get resources cpus "$PROJECT_RUN_CONFIG" || true)"

    _simple_raw="$(toml_get claude claude_simple_mode "$PROJECT_RUN_CONFIG" || true)"
    case "${_simple_raw,,}" in
        false|0|no|off) CLAUDE_SIMPLE_MODE="0" ;;
    esac
    _skip_raw="$(toml_get claude claude_skip_permissions "$PROJECT_RUN_CONFIG" || true)"
    case "${_skip_raw,,}" in
        yolo|true|1|yes|on) SKIP_PERMISSIONS="yolo" ;;
        plan)               SKIP_PERMISSIONS="plan" ;;
        false|0|no|off)     SKIP_PERMISSIONS="off" ;;
        *)                  SKIP_PERMISSIONS="yolo" ;;
    esac

    CLAUDE_ADDITIONAL_SYSTEM_PROMPT="$(toml_get claude claude_additional_system_prompt "$PROJECT_RUN_CONFIG" || true)"
    CLAUDE_MODEL="$(toml_get claude claude_model "$PROJECT_RUN_CONFIG" || true)"
    CLAUDE_QUERY="$(toml_get claude claude_query "$PROJECT_RUN_CONFIG" || true)"

    # [workspace] additional_excludes — newline-separated list
    _excludes_lines="$(toml_get_array workspace additional_excludes "$PROJECT_RUN_CONFIG" || true)"
    if [[ -n "$_excludes_lines" ]]; then
        EXTRA_EXCLUDES="$_excludes_lines"
    fi

    # [credentials] ssh_known_hosts — newline-separated list
    _hosts_lines="$(toml_get_array credentials ssh_known_hosts "$PROJECT_RUN_CONFIG" || true)"
    if [[ -n "$_hosts_lines" ]]; then
        SSH_KNOWN_HOSTS="$_hosts_lines"
    fi

    # [environment] timezone
    CONTAINER_TZ="$(toml_get environment timezone "$PROJECT_RUN_CONFIG" || true)"

    # [postgres] — host-side Postgres MCP (HTTP)
    _pg_enabled_raw="$(toml_get postgres enabled "$PROJECT_RUN_CONFIG" || true)"
    case "${_pg_enabled_raw,,}" in
        true|1|yes|on) PG_ENABLED=1 ;;
        *) PG_ENABLED=0 ;;
    esac
    if [[ "$PG_ENABLED" == "1" ]]; then
        PG_MCP_URL="$(toml_get postgres url "$PROJECT_RUN_CONFIG" || true)"
    fi

    # [mcp] remote MCP servers
    _mcp_enabled_raw="$(toml_get mcp enabled "$PROJECT_RUN_CONFIG" || true)"
    case "${_mcp_enabled_raw,,}" in
        true|1|yes|on) MCP_ENABLED=1 ;;
        *) MCP_ENABLED=0 ;;
    esac
    if [[ "$MCP_ENABLED" == "1" ]]; then
        MCP_BASE_URL="$(toml_get mcp base_url "$PROJECT_RUN_CONFIG" || true)"
        # Read servers array as newline-separated "name path keychain-service" entries
        MCP_SERVERS_RAW="$(toml_get_array mcp servers "$PROJECT_RUN_CONFIG" || true)"

        # Extract per-server tokens from Keychain (fallback: environment variables)
        # Collect unique keychain service names, fetch each token once
        MCP_TOKENS=""
        declare -A _token_cache=()
        _missing_tokens=0
        while IFS= read -r _entry; do
            [[ -z "$_entry" ]] && continue
            _keychain="$(echo "$_entry" | awk '{print $3}')"
            [[ -z "$_keychain" ]] && continue
            # Skip if already fetched
            [[ -n "${_token_cache[$_keychain]+x}" ]] && continue
            # Try Keychain first, then environment variable
            _token="$(security find-generic-password -s "$_keychain" -w 2>/dev/null || true)"
            if [[ -z "$_token" ]]; then
                # Fallback: MCP_TOKEN_PUSHOVER from "mcp:pushover"
                _env_name="MCP_TOKEN_$(echo "${_keychain#mcp:}" | tr '[:lower:]' '[:upper:]')"
                _token="${!_env_name:-}"
            fi
            if [[ -n "$_token" ]]; then
                _token_cache[$_keychain]="$_token"
            else
                echo "WARNING: No token found for '$_keychain' (Keychain or \$$_env_name)" >&2
                _token_cache[$_keychain]=""
                _missing_tokens=1
            fi
        done <<< "$MCP_SERVERS_RAW"

        # Build MCP_TOKENS as newline-separated "keychain-service token" pairs
        for _k in "${!_token_cache[@]}"; do
            [[ -z "${_token_cache[$_k]}" ]] && continue
            MCP_TOKENS+="${_k} ${_token_cache[$_k]}"$'\n'
        done
        unset _token_cache
    fi
fi

# Defaults (CLI flags > container-run.toml > defaults)
RUN_MEMORY="${RUN_MEMORY:-2g}"
RUN_CPUS="${RUN_CPUS:-4}"
CONTAINER_TZ="${CONTAINER_TZ:-Europe/Warsaw}"

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

# Append project-specific system prompt if configured
if [[ -n "$CLAUDE_ADDITIONAL_SYSTEM_PROMPT" ]]; then
    EXTRA_CLAUDE_ARGS=("--append-system-prompt" "$CLAUDE_ADDITIONAL_SYSTEM_PROMPT" "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")
fi

# Apply model override if configured
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
    EXTRA_CLAUDE_ARGS+=("--model" "$CLAUDE_MODEL")
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
    -e "TZ=${CONTAINER_TZ}"
)

if [[ "$CLAUDE_SIMPLE_MODE" == "1" ]]; then
    RUN_ARGS+=(-e "CLAUDE_CODE_SIMPLE=1")
fi

if [[ -n "$EXTRA_EXCLUDES" ]]; then
    RUN_ARGS+=(-e "EXTRA_EXCLUDES=${EXTRA_EXCLUDES}")
fi

if [[ -n "$SSH_KNOWN_HOSTS" ]]; then
    RUN_ARGS+=(-e "SSH_KNOWN_HOSTS=${SSH_KNOWN_HOSTS}")
fi

if [[ "${PG_ENABLED:-0}" == "1" && -n "${PG_MCP_URL:-}" ]]; then
    RUN_ARGS+=(-e "PG_MCP_URL=${PG_MCP_URL}")
    echo "==> Postgres MCP: ${PG_MCP_URL}"
fi

if [[ "${MCP_ENABLED:-0}" == "1" ]]; then
    if [[ -n "${MCP_TOKENS:-}" && -n "${MCP_BASE_URL:-}" && -n "${MCP_SERVERS_RAW:-}" ]]; then
        RUN_ARGS+=(-e "MCP_TOKENS=${MCP_TOKENS}")
        RUN_ARGS+=(-e "MCP_BASE_URL=${MCP_BASE_URL}")
        RUN_ARGS+=(-e "MCP_SERVERS=${MCP_SERVERS_RAW}")
        echo "==> MCP: ${MCP_BASE_URL} with $(echo "$MCP_SERVERS_RAW" | wc -l | tr -d ' ') server(s)"
    else
        echo "WARNING: MCP enabled but missing vars — TOKENS=${MCP_TOKENS:+set}, BASE_URL=${MCP_BASE_URL:+set}, SERVERS=${MCP_SERVERS_RAW:+set}" >&2
    fi
fi

RUN_ARGS+=("$IMAGE" "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")

# Append initial query if configured
if [[ -n "${CLAUDE_QUERY:-}" ]]; then
    RUN_ARGS+=("$CLAUDE_QUERY")
fi

exec "${RUN_ARGS[@]}"
