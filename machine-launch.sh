#!/usr/bin/env bash
# machine-launch.sh — run Claude Code in a persistent, isolated container machine
# Uses `container machine` with --home-mount none for filesystem isolation.
# The repo is cloned via GH_TOKEN/HTTPS; work flows back as git pushes/PRs.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
    _dir="$(cd "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

GLOBAL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/container"

# ── Constants ─────────────────────────────────────────────────────────────────
MACHINE_PREFIX="claude-machine-"
BASE_IMAGE="alpine:latest"
PROVISION_SENTINEL="/var/lib/claude-machine-provisioned"
MACHINE_UID="1000"
WORK_ROOT="/work"

# ── Config resolution ────────────────────────────────────────────────────────
resolve_config() {
    local env_override="$1" name="$2" fallback="${3:-}"
    if [[ -n "$env_override" ]]; then echo "$env_override"
    elif [[ -f "$PROJECT/$name" ]]; then echo "$PROJECT/$name"
    elif [[ -f "$GLOBAL_CONFIG_DIR/$name" ]]; then echo "$GLOBAL_CONFIG_DIR/$name"
    elif [[ -n "$fallback" && -f "$fallback" ]]; then echo "$fallback"
    fi
}

TEMPLATE_DIR="$SCRIPT_DIR"
PROJECT="$PWD"
REPROVISION=0
SHOW_STATUS=0
SHELL_MODE=0
EXTRA_CLAUDE_ARGS=()
PASSTHROUGH_CLAUDE_ARGS=()

RUN_MEMORY=""
RUN_CPUS=""
CLI_MEMORY=""
CLI_CPUS=""

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- CLAUDE_ARGS...]

Run Claude Code interactively inside a persistent, isolated container machine.
Uses \`container machine\` with --home-mount none — no host filesystem access.
The repo is cloned via GH_TOKEN/HTTPS; work flows back as git pushes/PRs.

Options:
  -h, --help               Show this help and exit
  -C, --project PATH       Project directory (default: \$PWD)
  --template-dir DIR       Directory containing CONTAINER.md templates
                           (default: directory containing this script)
  --memory SIZE            Machine memory (e.g., 4g, 8g). Overrides config/defaults
  --cpus N                 Machine CPUs. Overrides config/defaults
  --reprovision            Delete machine and re-create from scratch
  --reset                  Alias for --reprovision
  --status                 Show machine state and exit
  --shell                  Drop into a shell instead of launching Claude
  --                       Pass remaining arguments to claude inside the machine

Environment:
  CONTAINER_RUN_CONFIG     Runtime config path override (skips layered resolution)
  CLAUDE_CODE_OAUTH_TOKEN  Long-lived OAuth token (alternative to Keychain credentials)

Config (container-run.toml):
  [machine]                Machine-specific settings (git identity, resources)
  [claude]                 Claude mode, permissions, model, query
  [resources]              Fallback memory/CPUs
  [mcp]                    Remote MCP servers
  [postgres]               Postgres MCP
  [hooks]                  Webhook integration
  [environment]            Timezone

Differences from ephemeral mode (launch.sh):
  - Workspace is git-cloned, not copied from host mount
  - Uncommitted local work must be pushed before running
  - Untracked files (e.g., .env) must be injected via --env-file or tar
  - Machine persists across stop/start (~2s startup after first provision)
  - No SSH support — all git operations use GH_TOKEN/HTTPS
EOF
}

# ── TOML readers ─────────────────────────────────────────────────────────────
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
                sub(/\][ \t]*#.*$/, "]", line)
                if (line ~ /\[/ && line !~ /\]/) {
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

    raw="${raw#\[}"
    raw="${raw%\]}"
    local IFS=','
    for elem in $raw; do
        elem="$(echo "$elem" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"
        [[ -n "$elem" ]] && printf '%s\n' "$elem"
    done
}

# ── Argument parsing ─────────────────────────────────────────────────────────
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
        --memory)
            CLI_MEMORY="${2:?--memory requires a size (e.g., 4g)}"
            shift 2
            ;;
        --cpus)
            CLI_CPUS="${2:?--cpus requires a number}"
            shift 2
            ;;
        --reprovision|--reset)
            REPROVISION=1
            shift
            ;;
        --status)
            SHOW_STATUS=1
            shift
            ;;
        --shell)
            SHELL_MODE=1
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

# Preserve pass-through args before config reads overwrite EXTRA_CLAUDE_ARGS
PASSTHROUGH_CLAUDE_ARGS=("${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")

# ── Resolve paths ─────────────────────────────────────────────────────────────
PROJECT="$(cd "$PROJECT" && pwd)"

# ── Derive names ──────────────────────────────────────────────────────────────
project_slug() {
    basename "$1" | tr -cs 'a-zA-Z0-9._-' '-' | sed 's/^-*//;s/-*$//' | tr '[:upper:]' '[:lower:]'
}

SLUG="$(project_slug "$PROJECT")"
[[ -z "$SLUG" ]] && SLUG="sandbox"
MACHINE_NAME="${MACHINE_PREFIX}${SLUG}"

# ── System check ─────────────────────────────────────────────────────────────
ensure_system_running() {
    if container system status &>/dev/null; then
        return 0
    fi
    echo "==> Starting container system service..."
    container system start
}

# ── Machine helpers ───────────────────────────────────────────────────────────
machine_exists() {
    container machine list --quiet 2>/dev/null | grep -qx "$MACHINE_NAME"
}

is_provisioned() {
    container machine run --name "$MACHINE_NAME" -- \
        test -f "$PROVISION_SENTINEL" 2>/dev/null
}

get_machine_status() {
    container machine list --format json 2>/dev/null \
        | jq -r --arg n "$MACHINE_NAME" '.[] | select(.id == $n) | .status // "unknown"' 2>/dev/null \
        || echo "unknown"
}

# ── Resolve config files ─────────────────────────────────────────────────────
PROJECT_RUN_CONFIG="$(resolve_config "${CONTAINER_RUN_CONFIG:-}" container-run.toml)"
[[ -n "$PROJECT_RUN_CONFIG" ]] && echo "==> Run config: $PROJECT_RUN_CONFIG"

# ── Read runtime config ──────────────────────────────────────────────────────
CLAUDE_SIMPLE_MODE="1"
SKIP_PERMISSIONS="yolo"
CLAUDE_ADDITIONAL_SYSTEM_PROMPT=""
CLAUDE_MODEL=""
CLAUDE_QUERY=""
CONTAINER_TZ=""
CODEX_SANDBOX=""

# [resources] fallback
if [[ -f "$PROJECT_RUN_CONFIG" ]]; then
    [[ -z "$RUN_MEMORY" ]] && RUN_MEMORY="$(toml_get resources memory "$PROJECT_RUN_CONFIG" || true)"
    [[ -z "$RUN_CPUS" ]]   && RUN_CPUS="$(toml_get resources cpus "$PROJECT_RUN_CONFIG" || true)"
fi

# [machine] overrides
MACHINE_MEMORY=""
MACHINE_CPUS=""
if [[ -f "$PROJECT_RUN_CONFIG" ]]; then
    MACHINE_MEMORY="$(toml_get machine memory "$PROJECT_RUN_CONFIG" || true)"
    MACHINE_CPUS="$(toml_get machine cpus "$PROJECT_RUN_CONFIG" || true)"
fi

# Resource precedence: CLI > [machine] > [resources] > defaults
if [[ -n "$CLI_MEMORY" ]]; then
    machine_memory="$CLI_MEMORY"
elif [[ -n "$MACHINE_MEMORY" ]]; then
    machine_memory="$MACHINE_MEMORY"
elif [[ -n "$RUN_MEMORY" ]]; then
    machine_memory="$RUN_MEMORY"
else
    machine_memory="4g"
fi

if [[ -n "$CLI_CPUS" ]]; then
    machine_cpus="$CLI_CPUS"
elif [[ -n "$MACHINE_CPUS" ]]; then
    machine_cpus="$MACHINE_CPUS"
elif [[ -n "$RUN_CPUS" ]]; then
    machine_cpus="$RUN_CPUS"
else
    machine_cpus="4"
fi

# [claude]
if [[ -f "$PROJECT_RUN_CONFIG" ]]; then
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

    # [codex]
    CODEX_SANDBOX="$(toml_get codex sandbox_mode "$PROJECT_RUN_CONFIG" || true)"

    # [environment]
    CONTAINER_TZ="$(toml_get environment timezone "$PROJECT_RUN_CONFIG" || true)"

    # [postgres]
    _pg_enabled_raw="$(toml_get postgres enabled "$PROJECT_RUN_CONFIG" || true)"
    case "${_pg_enabled_raw,,}" in
        true|1|yes|on) PG_ENABLED=1 ;;
        *) PG_ENABLED=0 ;;
    esac
    if [[ "$PG_ENABLED" == "1" ]]; then
        PG_MCP_URL="$(toml_get postgres url "$PROJECT_RUN_CONFIG" || true)"
    fi

    # [mcp]
    _mcp_enabled_raw="$(toml_get mcp enabled "$PROJECT_RUN_CONFIG" || true)"
    case "${_mcp_enabled_raw,,}" in
        true|1|yes|on) MCP_ENABLED=1 ;;
        *) MCP_ENABLED=0 ;;
    esac
    if [[ "$MCP_ENABLED" == "1" ]]; then
        MCP_BASE_URL="$(toml_get mcp base_url "$PROJECT_RUN_CONFIG" || true)"
        MCP_SERVERS_RAW="$(toml_get_array mcp servers "$PROJECT_RUN_CONFIG" || true)"

        MCP_TOKENS=""
        declare -A _token_cache=()
        while IFS= read -r _entry; do
            [[ -z "$_entry" ]] && continue
            _keychain="$(echo "$_entry" | awk '{print $3}')"
            [[ -z "$_keychain" ]] && continue
            [[ -n "${_token_cache[$_keychain]+x}" ]] && continue
            _token="$(security find-generic-password -s "$_keychain" -w 2>/dev/null || true)"
            if [[ -z "$_token" ]]; then
                _env_name="MCP_TOKEN_$(echo "${_keychain#mcp:}" | tr '[:lower:]' '[:upper:]')"
                _token="${!_env_name:-}"
            fi
            if [[ -n "$_token" ]]; then
                _token_cache[$_keychain]="$_token"
            else
                echo "WARNING: No token found for '$_keychain' (Keychain or \$$_env_name)" >&2
                _token_cache[$_keychain]=""
            fi
        done <<< "$MCP_SERVERS_RAW"

        for _k in "${!_token_cache[@]}"; do
            [[ -z "${_token_cache[$_k]}" ]] && continue
            MCP_TOKENS+="${_k} ${_token_cache[$_k]}"$'\n'
        done
        unset _token_cache
    fi

    # [hooks]
    _hooks_enabled_raw="$(toml_get hooks enabled "$PROJECT_RUN_CONFIG" || true)"
    case "${_hooks_enabled_raw,,}" in
        true|1|yes|on) HOOKS_ENABLED=1 ;;
        *) HOOKS_ENABLED=0 ;;
    esac
    if [[ "$HOOKS_ENABLED" == "1" ]]; then
        WEBHOOK_HOST="$(toml_get hooks host "$PROJECT_RUN_CONFIG" || true)"
        WEBHOOK_HOST="${WEBHOOK_HOST:-192.168.64.1}"
        WEBHOOK_PORT="$(toml_get hooks port "$PROJECT_RUN_CONFIG" || true)"
        WEBHOOK_PORT="${WEBHOOK_PORT:-8765}"
        _register_talk_raw="$(toml_get hooks register_talk_mcp "$PROJECT_RUN_CONFIG" || true)"
        case "${_register_talk_raw,,}" in
            false|0|no|off) HOOKS_REGISTER_TALK=0 ;;
            *) HOOKS_REGISTER_TALK=1 ;;
        esac
    fi
fi

CONTAINER_TZ="${CONTAINER_TZ:-Europe/Warsaw}"
CODEX_SANDBOX="${CODEX_SANDBOX:-danger-full-access}"

# ── Git identity extraction (best-effort) ────────────────────────────────────
GIT_USER_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || true)"

if [[ -z "$GIT_USER_NAME" && -f "$PROJECT_RUN_CONFIG" ]]; then
    GIT_USER_NAME="$(toml_get machine git_user_name "$PROJECT_RUN_CONFIG" || true)"
fi
if [[ -z "$GIT_USER_EMAIL" && -f "$PROJECT_RUN_CONFIG" ]]; then
    GIT_USER_EMAIL="$(toml_get machine git_user_email "$PROJECT_RUN_CONFIG" || true)"
fi

if [[ -z "$GIT_USER_NAME" || -z "$GIT_USER_EMAIL" ]]; then
    echo "ERROR: Git user.name/email not found." >&2
    echo "  Set via: git config --global user.name '...' && git config --global user.email '...'" >&2
    echo "  Or add [machine] git_user_name/git_user_email to container-run.toml" >&2
    exit 1
fi

# ── Credential extraction ────────────────────────────────────────────────────
CLAUDE_CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [[ -z "$CLAUDE_CREDS" ]]; then
    echo "WARNING: No subscription credentials found in Keychain." >&2
fi

GH_TOKEN=""
GH_TOKEN_RAW="$(security find-generic-password -s "gh:github.com" -w 2>/dev/null || true)"
if [[ "$GH_TOKEN_RAW" == go-keyring-base64:* ]]; then
    GH_TOKEN="$(echo "${GH_TOKEN_RAW#go-keyring-base64:}" | base64 -d)"
elif [[ -n "$GH_TOKEN_RAW" ]]; then
    GH_TOKEN="$GH_TOKEN_RAW"
fi

CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

# ── Repo URL derivation ──────────────────────────────────────────────────────
REPO_URL="$(cd "$PROJECT" && git remote get-url origin 2>/dev/null || true)"
if [[ -z "$REPO_URL" ]]; then
    echo "ERROR: Project has no 'origin' remote. Machine mode needs a remote to clone." >&2
    exit 1
fi
# Convert SSH URL to HTTPS for GH_TOKEN auth
REPO_URL="${REPO_URL//git@github.com:/https:\/\/github.com\/}"
# Inject GH_TOKEN into HTTPS URL so git clone/fetch/push authenticate for private repos
if [[ -n "${GH_TOKEN:-}" ]]; then
    REPO_URL="${REPO_URL/https:\/\/github.com\//https:\/\/x-access-token:${GH_TOKEN}@github.com\/}"
fi

# ── Host Claude settings extraction (multiline — passed via -e flags) ────────
CLAUDE_SETTINGS_JSON=""
[[ -f "$HOME/.claude/settings.json" ]] && CLAUDE_SETTINGS_JSON="$(cat "$HOME/.claude/settings.json")"
CLAUDE_SETTINGS_LOCAL_JSON=""
[[ -f "$HOME/.claude/settings.local.json" ]] && CLAUDE_SETTINGS_LOCAL_JSON="$(cat "$HOME/.claude/settings.local.json")"
CLAUDE_JSON=""
[[ -f "$HOME/.claude.json" ]] && CLAUDE_JSON="$(cat "$HOME/.claude.json")"

# ── ENABLED_MCP_SERVERS from host settings ────────────────────────────────────
_settings="$HOME/.claude/settings.local.json"
if [[ -f "$_settings" ]]; then
    _all_enabled="$(jq -r '.enableAllProjectMcpServers // false' "$_settings")"
    if [[ "$_all_enabled" == "true" ]]; then
        ENABLED_MCP_SERVERS="*"
    else
        ENABLED_MCP_SERVERS="$(jq -r '(.enabledMcpjsonServers // []) | join(",")' "$_settings")"
    fi
fi

# ── Hooks tar (base64-encoded for transport) ─────────────────────────────────
HOOKS_TAR_B64=""
if [[ "${HOOKS_ENABLED:-0}" == "1" && -d "$HOME/.claude/hooks" ]]; then
    HOOKS_TAR_B64="$(tar -czf - -C "$HOME/.claude" hooks | base64)"
fi

# ── Simple mode notice ───────────────────────────────────────────────────────
if [[ "$CLAUDE_SIMPLE_MODE" == "1" ]]; then
    echo "==> Simple mode: hooks, agents, session memory, CLAUDE.md disabled" >&2
fi

# ── Status mode ──────────────────────────────────────────────────────────────
if [[ "$SHOW_STATUS" == "1" ]]; then
    if machine_exists; then
        echo "Machine: $MACHINE_NAME"
        echo "Status:  $(get_machine_status)"
        if is_provisioned; then
            echo "Provisioned: yes"
        else
            echo "Provisioned: no (incomplete or failed)"
        fi
    else
        echo "Machine '$MACHINE_NAME' does not exist."
    fi
    exit 0
fi

# ── CONTAINER.md template rendering (host-side) ─────────────────────────────
get_claude_version() {
    # We don't have claude installed on host — skip
    echo "unknown"
}

truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

evaluate_condition() {
    local cond="$1"
    local negate=0
    if [[ "$cond" == !* ]]; then
        negate=1
        cond="${cond#!}"
    fi
    local val="${!cond:-false}"
    if truthy "$val"; then
        [[ "$negate" -eq 1 ]] && return 1 || return 0
    fi
    [[ "$negate" -eq 1 ]] && return 0 || return 1
}

render_template() {
    local template_path="$1"
    local output=""
    local re_if='^[[:space:]]*<if[[:space:]]+([^[:space:]>]+)[[:space:]]*>[[:space:]]*$'
    local re_endif='^[[:space:]]*</if>[[:space:]]*$'
    local line emit=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re_if ]]; then
            local cond="${BASH_REMATCH[1]}"
            evaluate_condition "$cond" && emit=1 || emit=0
            continue
        fi
        if [[ "$line" =~ $re_endif ]]; then
            emit=1
            continue
        fi
        if [[ "$emit" -eq 1 ]]; then
            line="${line//\{\{PYTHON_VERSION\}\}/unknown}"
            line="${line//\{\{GO_VERSION\}\}/unknown}"
            line="${line//\{\{GOLANGCI_LINT_VERSION\}\}/unknown}"
            line="${line//\{\{CLAUDE_VERSION\}\}/unknown}"
            line="${line//\{\{MCP_SERVER_LIST\}\}/${MCP_SERVER_LIST:-}}"
            line="${line//\{\{WEBHOOK_HOST\}\}/${WEBHOOK_HOST:-}}"
            line="${line//\{\{WEBHOOK_PORT\}\}/${WEBHOOK_PORT:-}}"
            output+="$line"$'\n'
        fi
    done < "$template_path"
    echo "$output"
}

# Pick template (prefer python — machine mode is language-agnostic)
CONTAINER_MD_CONTENT=""
CONTAINER_TEMPLATE_PYTHON="$TEMPLATE_DIR/templates/CONTAINER.python.md.tmpl"
if [[ -f "$CONTAINER_TEMPLATE_PYTHON" ]]; then
    HAS_MCP="${HAS_MCP:-false}"
    HAS_CODEX=false
    HAS_TALK=false
    HAS_GOLANGCI_CONFIG=false
    [[ "${HOOKS_REGISTER_TALK:-0}" == "1" ]] && HAS_TALK=true
    MCP_SERVER_LIST=""
    CONTAINER_MD_CONTENT="$(render_template "$CONTAINER_TEMPLATE_PYTHON")"
fi

# ── Machine creation ─────────────────────────────────────────────────────────
create_machine() {
    ensure_system_running
    echo "==> Creating machine: $MACHINE_NAME (${machine_memory} RAM, ${machine_cpus} CPUs)"
    echo "==> Base image: $BASE_IMAGE (--home-mount none)"
    container machine create \
        --name "$MACHINE_NAME" \
        --home-mount none \
        --cpus "$machine_cpus" \
        --memory "$machine_memory" \
        --arch arm64 \
        "$BASE_IMAGE"
    echo "==> Machine created."
}

# ── Provisioning ─────────────────────────────────────────────────────────────
provision_machine() {
    echo "==> Provisioning machine: $MACHINE_NAME"

    local prov_env_file
    prov_env_file="$(mktemp)"
    trap 'rm -f "$prov_env_file"' EXIT
    chmod 600 "$prov_env_file"

    # Scalar vars in env-file
    cat > "$prov_env_file" <<EOF
GH_TOKEN=${GH_TOKEN}
CLAUDE_CREDS=${CLAUDE_CREDS}
CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
TZ=${CONTAINER_TZ}
GIT_USER_NAME=${GIT_USER_NAME}
GIT_USER_EMAIL=${GIT_USER_EMAIL}
REPO_URL=${REPO_URL}
PROJECT_SLUG=${SLUG}
WORK_ROOT=${WORK_ROOT}
PROVISION_SENTINEL=${PROVISION_SENTINEL}
CLAUDE_SIMPLE_MODE=${CLAUDE_SIMPLE_MODE}
CODEX_SANDBOX=${CODEX_SANDBOX}
EOF

    # MCP, postgres, hooks vars
    # Note: MCP_TOKENS and MCP_SERVERS_RAW are multiline — must use -e flags, not env-file
    if [[ "${PG_ENABLED:-0}" == "1" && -n "${PG_MCP_URL:-}" ]]; then
        echo "PG_MCP_URL=${PG_MCP_URL}" >> "$prov_env_file"
    fi
    local mcp_env_flags=()
    if [[ "${MCP_ENABLED:-0}" == "1" && -n "${MCP_TOKENS:-}" && -n "${MCP_BASE_URL:-}" && -n "${MCP_SERVERS_RAW:-}" ]]; then
        echo "MCP_BASE_URL=${MCP_BASE_URL}" >> "$prov_env_file"
        mcp_env_flags+=(-e "MCP_TOKENS=${MCP_TOKENS}")
        mcp_env_flags+=(-e "MCP_SERVERS=${MCP_SERVERS_RAW}")
    fi
    if [[ "${HOOKS_ENABLED:-0}" == "1" ]]; then
        echo "HOOKS_ENABLED=1" >> "$prov_env_file"
        echo "WEBHOOK_HOST=${WEBHOOK_HOST:-}" >> "$prov_env_file"
        echo "WEBHOOK_PORT=${WEBHOOK_PORT:-8765}" >> "$prov_env_file"
        echo "HOOKS_REGISTER_TALK=${HOOKS_REGISTER_TALK:-0}" >> "$prov_env_file"
    fi
    if [[ -n "${ENABLED_MCP_SERVERS+set}" ]]; then
        echo "ENABLED_MCP_SERVERS=${ENABLED_MCP_SERVERS}" >> "$prov_env_file"
    fi

    # Multi-line vars via -e flags (env-file is line-based)
    local extra_env_flags=("${mcp_env_flags[@]+"${mcp_env_flags[@]}"}")
    [[ -n "$CLAUDE_SETTINGS_JSON" ]] && extra_env_flags+=(-e "CLAUDE_SETTINGS_JSON=${CLAUDE_SETTINGS_JSON}")
    [[ -n "$CLAUDE_SETTINGS_LOCAL_JSON" ]] && extra_env_flags+=(-e "CLAUDE_SETTINGS_LOCAL_JSON=${CLAUDE_SETTINGS_LOCAL_JSON}")
    [[ -n "$CLAUDE_JSON" ]] && extra_env_flags+=(-e "CLAUDE_JSON=${CLAUDE_JSON}")
    [[ -n "$HOOKS_TAR_B64" ]] && extra_env_flags+=(-e "HOOKS_TAR_B64=${HOOKS_TAR_B64}")
    [[ -n "$CONTAINER_MD_CONTENT" ]] && extra_env_flags+=(-e "CONTAINER_MD_CONTENT=${CONTAINER_MD_CONTENT}")

    container machine run \
        --name "$MACHINE_NAME" \
        --root \
        --env-file "$prov_env_file" \
        "${extra_env_flags[@]+"${extra_env_flags[@]}"}" \
        -- /bin/sh -s <<'PROVISION_SCRIPT'
#!/bin/sh
set -e

echo "[provision] === Starting machine provisioning ==="

# 8a. System packages
echo "[provision] Installing system packages..."
apk update
apk add --no-cache \
    git curl jq ripgrep fzf tree patch file less procps sudo \
    bash ca-certificates openssh-client tzdata

# 8b. Timezone
if [ -n "${TZ:-}" ]; then
    echo "[provision] Setting timezone: $TZ"
    cp "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# 8c. Claude Code binary (direct download)
echo "[provision] Installing Claude Code..."
CLAUDE_CODE_GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
CLAUDE_VERSION=$(curl -fsSL --retry 3 "$CLAUDE_CODE_GCS/latest")
echo "[provision] Claude Code latest: v${CLAUDE_VERSION}"
curl -fsSL --retry 3 "$CLAUDE_CODE_GCS/$CLAUDE_VERSION/linux-arm64/claude" \
    -o /usr/local/bin/claude
chmod +x /usr/local/bin/claude
echo "$CLAUDE_VERSION" > /usr/local/share/claude-version 2>/dev/null || true

# 8d. Discover target user
TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)" || true
if [ -z "$TARGET_USER" ]; then
    echo "[provision] Creating sandbox user..."
    adduser -D -s /bin/bash sandbox
    TARGET_USER="sandbox"
fi
TARGET_HOME="$(eval echo ~$TARGET_USER)"
mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.local/share"

# 8e. Git configuration
echo "[provision] Configuring git..."
su - "$TARGET_USER" -c "
    git config --global user.name '${GIT_USER_NAME}'
    git config --global user.email '${GIT_USER_EMAIL}'
    git config --global init.defaultBranch main
    git config --global safe.directory '*'
"

if [ -n "${GH_TOKEN:-}" ]; then
    su - "$TARGET_USER" -c "
        git config --global url.'https://x-access-token:${GH_TOKEN}@github.com/'.insteadOf 'git@github.com:'
        git config --global url.'https://x-access-token:${GH_TOKEN}@github.com/'.insteadOf 'ssh://git@github.com/'
        git config --global url.'https://x-access-token:${GH_TOKEN}@github.com/'.insteadOf 'https://github.com/'
    "
fi

# 8f. Claude credentials
mkdir -p "$TARGET_HOME/.claude"
if [ -n "${CLAUDE_CREDS:-}" ]; then
    echo "[provision] Setting up subscription credentials..."
    echo "$CLAUDE_CREDS" > "$TARGET_HOME/.claude/.credentials.json"
    chmod 600 "$TARGET_HOME/.claude/.credentials.json"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "[provision] Setting up OAuth token..."
    echo "$CLAUDE_CODE_OAUTH_TOKEN" > "$TARGET_HOME/.claude/.credentials.json"
    chmod 600 "$TARGET_HOME/.claude/.credentials.json"
else
    echo "[provision] WARNING: No auth configured — /login required"
fi

# 8g. Claude settings transfer
if [ -n "${CLAUDE_SETTINGS_JSON:-}" ]; then
    echo "$CLAUDE_SETTINGS_JSON" > "$TARGET_HOME/.claude/settings.json"
fi
if [ -n "${CLAUDE_SETTINGS_LOCAL_JSON:-}" ]; then
    echo "$CLAUDE_SETTINGS_LOCAL_JSON" > "$TARGET_HOME/.claude/settings.local.json"
fi
if [ -n "${CLAUDE_JSON:-}" ]; then
    echo "$CLAUDE_JSON" > "$TARGET_HOME/.claude.json"
fi

# 8h. Webhook URL rewriting
if [ "${HOOKS_ENABLED:-0}" = "1" ]; then
    for sf in "$TARGET_HOME/.claude/settings.json" "$TARGET_HOME/.claude/settings.local.json"; do
        if [ -f "$sf" ]; then
            sed -i \
                -e "s|http://127\.0\.0\.1:${WEBHOOK_PORT:-8765}|http://${WEBHOOK_HOST:-192.168.64.1}:${WEBHOOK_PORT:-8765}|g" \
                -e "s|http://localhost:${WEBHOOK_PORT:-8765}|http://${WEBHOOK_HOST:-192.168.64.1}:${WEBHOOK_PORT:-8765}|g" \
                "$sf"
        fi
    done
fi

# 8i. Clone repository
WORK_DIR="${WORK_ROOT}/${PROJECT_SLUG}"
if [ ! -d "$WORK_DIR/.git" ]; then
    echo "[provision] Cloning repository..."
    mkdir -p "$WORK_ROOT"
    su - "$TARGET_USER" -c "git clone '${REPO_URL}' '${WORK_DIR}'"
    echo "[provision] Clone complete."
else
    echo "[provision] Repository already cloned — fetching updates..."
    cd "$WORK_DIR" && su - "$TARGET_USER" -c "git fetch --all"
fi

# 8j. MCP server registration
echo '{"mcpServers": {}}' > "$WORK_DIR/.mcp.json"
chown "$TARGET_USER:$TARGET_USER" "$WORK_DIR/.mcp.json"

# Helper: check if server is in the host whitelist
mcp_server_enabled() {
    _name="$1"
    [ -z "${ENABLED_MCP_SERVERS+set}" ] && return 0
    [ "$ENABLED_MCP_SERVERS" = "*" ] && return 0
    [ -z "$ENABLED_MCP_SERVERS" ] && return 1
    case ",${ENABLED_MCP_SERVERS}," in *",$_name,"*) return 0 ;; esac
    return 1
}

# Postgres MCP
if [ -n "${PG_MCP_URL:-}" ] && mcp_server_enabled postgres; then
    echo "[provision] Registering Postgres MCP..."
    su - "$TARGET_USER" -c "cd '${WORK_DIR}' && claude mcp add postgres --transport http '${PG_MCP_URL}' -s project" 2>/dev/null && \
        echo "[provision]   MCP OK: postgres" || echo "[provision]   MCP FAIL: postgres"
fi

# Remote HTTP MCP servers
if [ -n "${MCP_SERVERS:-}" ] && [ -n "${MCP_TOKENS:-}" ] && [ -n "${MCP_BASE_URL:-}" ]; then
    echo "[provision] Registering MCP servers..."
    echo "$MCP_SERVERS" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        name="$(echo "$entry" | awk '{print $1}')"
        path="$(echo "$entry" | awk '{print $2}')"
        keychain="$(echo "$entry" | awk '{print $3}')"
        if ! mcp_server_enabled "$name"; then
            echo "[provision]   SKIP: $name (not in enabledMcpjsonServers)"
            continue
        fi
        token="$(echo "$MCP_TOKENS" | awk -v svc="$keychain" '$1 == svc {print $2; exit}')"
        [ -z "$token" ] && { echo "[provision]   SKIP: $name (no token for $keychain)"; continue; }
        su - "$TARGET_USER" -c "cd '${WORK_DIR}' && claude mcp add --transport http '$name' '${MCP_BASE_URL}${path}' --header 'Authorization: Bearer ${token}' -s project" 2>/dev/null && \
            echo "[provision]   MCP OK: $name" || echo "[provision]   MCP FAIL: $name"
    done
fi

# Talk MCP
if [ "${HOOKS_REGISTER_TALK:-0}" = "1" ] && [ -n "${WEBHOOK_HOST:-}" ] && mcp_server_enabled talk; then
    _talk_url="http://${WEBHOOK_HOST}:${WEBHOOK_PORT:-8765}/mcp/"
    echo "[provision] Registering Talk MCP at ${_talk_url}..."
    su - "$TARGET_USER" -c "cd '${WORK_DIR}' && claude mcp add --transport http talk '${_talk_url}' -s project" 2>/dev/null && \
        echo "[provision]   MCP OK: talk" || echo "[provision]   MCP FAIL: talk"
fi

# 8k. CONTAINER.md
if [ -n "${CONTAINER_MD_CONTENT:-}" ]; then
    echo "$CONTAINER_MD_CONTENT" > "$WORK_DIR/CONTAINER.md"
    chown "$TARGET_USER:$TARGET_USER" "$WORK_DIR/CONTAINER.md"
    echo "[provision] CONTAINER.md written."
fi

# 8l. Hooks directory transfer
if [ -n "${HOOKS_TAR_B64:-}" ]; then
    echo "[provision] Extracting hooks directory..."
    echo "$HOOKS_TAR_B64" | base64 -d | tar -xzf - -C "$TARGET_HOME/.claude/"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.claude/hooks"
fi

# 8m. Persistent environment profile
cat > /etc/profile.d/claude-machine.sh <<ENVEOF
export GH_TOKEN="${GH_TOKEN}"
export TZ="${TZ}"
export PATH="\$HOME/.local/bin:\$PATH"
ENVEOF
if [ "${CLAUDE_SIMPLE_MODE}" = "1" ]; then
    echo 'export CLAUDE_CODE_SIMPLE=1' >> /etc/profile.d/claude-machine.sh
fi

# 8n. Sentinel and ownership
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME"
chown -R "$TARGET_USER:$TARGET_USER" "$WORK_DIR"
touch "${PROVISION_SENTINEL}"
echo "[provision] === Complete. Machine ready. ==="
PROVISION_SCRIPT
}

# ── Re-entry ─────────────────────────────────────────────────────────────────
reenter_machine() {
    echo "==> Re-entering machine: $MACHINE_NAME"

    echo "==> Fetching latest from remote..."
    container machine run --name "$MACHINE_NAME" --uid "$MACHINE_UID" -- \
        bash -c "cd ${WORK_ROOT}/${SLUG} && git fetch --all" 2>/dev/null || \
        echo "WARNING: git fetch failed (working offline?)"

    build_claude_args
    launch_claude
}

# ── Claude args builder ──────────────────────────────────────────────────────
build_claude_args() {
    EXTRA_CLAUDE_ARGS=()
    local _passthrough=("${PASSTHROUGH_CLAUDE_ARGS[@]+"${PASSTHROUGH_CLAUDE_ARGS[@]}"}")

    case "$SKIP_PERMISSIONS" in
        yolo)
            EXTRA_CLAUDE_ARGS=("--dangerously-skip-permissions")
            ;;
        plan)
            EXTRA_CLAUDE_ARGS=("--permission-mode" "plan" "--allow-dangerously-skip-permissions")
            ;;
    esac

    EXTRA_CLAUDE_ARGS=("--append-system-prompt" \
        "You MUST read CONTAINER.md in the workspace root before doing anything else." \
        "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")

    if [[ -n "$CLAUDE_ADDITIONAL_SYSTEM_PROMPT" ]]; then
        EXTRA_CLAUDE_ARGS=("--append-system-prompt" "$CLAUDE_ADDITIONAL_SYSTEM_PROMPT" \
            "${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")
    fi

    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        EXTRA_CLAUDE_ARGS+=("--model" "$CLAUDE_MODEL")
    fi

    # Append user pass-through args (e.g. --resume) last so they override defaults
    EXTRA_CLAUDE_ARGS+=("${_passthrough[@]+"${_passthrough[@]}"}")
}

# ── Launch ────────────────────────────────────────────────────────────────────
launch_claude() {
    if [[ "$SHELL_MODE" == "1" ]]; then
        exec container machine run \
            --name "$MACHINE_NAME" \
            --uid "$MACHINE_UID" \
            -it \
            -- bash
    fi

    local claude_args=("${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}")
    if [[ -n "${CLAUDE_QUERY:-}" ]]; then
        claude_args+=("$CLAUDE_QUERY")
    fi

    exec container machine run \
        --name "$MACHINE_NAME" \
        --uid "$MACHINE_UID" \
        -it \
        --workdir "${WORK_ROOT}/${SLUG}" \
        -- claude "${claude_args[@]+"${claude_args[@]}"}"
}

# ── Main flow ─────────────────────────────────────────────────────────────────
ensure_system_running

echo "==> Machine mode for: $PROJECT"
echo "==> Machine: $MACHINE_NAME"
echo "==> Resources: ${machine_memory} memory, ${machine_cpus} CPUs"

if [[ "$REPROVISION" == "1" ]]; then
    echo "==> Reprovisioning: deleting machine $MACHINE_NAME..."
    if machine_exists; then
        container machine delete "$MACHINE_NAME" 2>/dev/null || {
            echo "ERROR: Failed to delete machine '$MACHINE_NAME'. Try: container machine delete $MACHINE_NAME" >&2
            exit 1
        }
    fi
    create_machine
    provision_machine
    build_claude_args
    launch_claude
elif machine_exists; then
    if is_provisioned; then
        reenter_machine
    else
        echo "==> Machine exists but is not provisioned — re-provisioning..."
        provision_machine
        build_claude_args
        launch_claude
    fi
else
    create_machine
    provision_machine
    build_claude_args
    launch_claude
fi
