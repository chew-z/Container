#!/usr/bin/env bash
# entrypoint.sh — runs inside the container at startup
set -euo pipefail

# ── Passthrough: if invoked as a non-claude command, exec it directly ─────────
# This handles persistent containers (sleep infinity) created by zed-claude-acp.sh
case "${1:-}" in
    sleep|/bin/sleep|bash|/bin/bash|sh|/bin/sh)
        exec "$@"
        ;;
esac

# ── 0. Set timezone from TZ env var ──────────────────────────────────────────
if [[ -n "${TZ:-}" ]]; then
    echo "$TZ" | sudo tee /etc/timezone > /dev/null
    sudo ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

# ── 1. Copy ~/.claude config from host mount (essentials only) ────────────────
if [[ -d /mnt/in/claude_dir ]]; then
    echo "[entrypoint] Copying ~/.claude config (essentials only)..." >&2
    mkdir -p /home/sandbox/.claude

    # Config files
    for f in settings.json settings.local.json CLAUDE.md; do
        [[ -f /mnt/in/claude_dir/$f ]] && cp -p "/mnt/in/claude_dir/$f" "/home/sandbox/.claude/$f"
    done

    # Directories — always needed
    for d in commands skills statsig; do
        [[ -d /mnt/in/claude_dir/$d ]] && cp -rp "/mnt/in/claude_dir/$d" "/home/sandbox/.claude/$d"
    done

    # Hooks and agents — skipped in simple mode (hooks require Python/uv)
    if [[ "${CLAUDE_CODE_SIMPLE:-0}" != "1" ]]; then
        for d in hooks agents; do
            [[ -d /mnt/in/claude_dir/$d ]] && cp -rp "/mnt/in/claude_dir/$d" "/home/sandbox/.claude/$d"
        done
    else
        echo "[entrypoint] Simple mode: skipping hooks, agents" >&2
    fi
fi

# ── 1b. Copy ~/.codex config from host (selective) ───────────────────────
if [[ -d /mnt/in/codex_dir ]] && command -v codex &>/dev/null; then
    echo "[entrypoint] Copying ~/.codex config (selective)..." >&2
    mkdir -p /home/sandbox/.codex

    # Auth tokens (ChatGPT OAuth)
    [[ -f /mnt/in/codex_dir/auth.json ]] && cp -p /mnt/in/codex_dir/auth.json /home/sandbox/.codex/auth.json

    # Personality/instructions
    [[ -f /mnt/in/codex_dir/AGENTS.md ]] && cp -p /mnt/in/codex_dir/AGENTS.md /home/sandbox/.codex/AGENTS.md

    # Generate minimal config.toml (no host-specific paths)
    cat > /home/sandbox/.codex/config.toml << 'CODEX_CONF'
preferred_auth_method = "chatgpt"
approval_policy = "never"
sandbox_mode = "workspace-write"
network_access = true
model = "gpt-5.3-codex-spark"
model_reasoning_effort = "high"
search_tool = true
CODEX_CONF
fi

# ── 2. Copy .claude.json from host home ───────────────────────────────────────
if [[ -f /mnt/in/home/.claude.json ]]; then
    echo "[entrypoint] Copying .claude.json..." >&2
    cp /mnt/in/home/.claude.json /home/sandbox/.claude.json
fi

# ── 2.5 Write credentials file (Linux plaintext fallback for Keychain) ───────
if [[ -n "${CLAUDE_CREDS:-}" ]]; then
    echo "[entrypoint] Writing credentials file..." >&2
    echo "$CLAUDE_CREDS" > /home/sandbox/.claude/.credentials.json
    chmod 600 /home/sandbox/.claude/.credentials.json
fi

# ── 2.6 Copy SSH keys and git config from host ──────────────────────────────
if [[ -d /mnt/in/home/.ssh ]]; then
    echo "[entrypoint] Copying SSH keys..." >&2
    mkdir -p /home/sandbox/.ssh
    cp /mnt/in/home/.ssh/id_* /home/sandbox/.ssh/ 2>/dev/null || true
    # SSH config not copied — host uses macOS Secure Enclave (Secretive) which
    # doesn't work in Linux. Git access is via HTTPS+GH_TOKEN (see section 2.7).
    chmod 700 /home/sandbox/.ssh
    chmod 600 /home/sandbox/.ssh/* 2>/dev/null || true
    # Keyscan hosts: SSH_KNOWN_HOSTS env (newline-separated) or default to github.com
    _hosts="${SSH_KNOWN_HOSTS:-github.com}"
    while IFS= read -r _host; do
        [[ -z "$_host" ]] && continue
        ssh-keyscan -T 5 -t ed25519 "$_host" >> /home/sandbox/.ssh/known_hosts 2>/dev/null || true
    done <<< "$_hosts"
fi
if [[ -f /mnt/in/home/.gitconfig ]]; then
    echo "[entrypoint] Copying .gitconfig..." >&2
    cp /mnt/in/home/.gitconfig /home/sandbox/.gitconfig
    # Remove host's SSH-to-HTTPS rewrites — they break token-based auth in the container
    git config --global --unset-all 'url.git@github.com:.insteadOf' 2>/dev/null || true
    git config --global --unset-all 'url.ssh://git@github.com/.insteadOf' 2>/dev/null || true
fi

# ── 2.7 Configure git to use GH_TOKEN for GitHub over HTTPS ─────────────────
# Host SSH keys (macOS Secure Enclave, Secretive) don't work in Linux containers.
# When GH_TOKEN is available, rewrite SSH remote URLs to HTTPS with token auth.
if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:"
    git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
fi

if command -v go &>/dev/null; then
    for ext in yml yaml; do
        if [[ -f /mnt/in/home/.golangci.$ext ]]; then
            echo "[entrypoint] Copying .golangci.$ext..." >&2
            cp /mnt/in/home/.golangci.$ext /home/sandbox/.golangci.$ext
        fi
    done
fi

# ── 3. Copy workspace if in copy mode ────────────────────────────────────────
if [[ "${SANDBOX_COPY_MODE:-0}" == "1" ]]; then
    echo "[entrypoint] Copy mode: copying workspace (filtering build artifacts)..." >&2
    mkdir -p /workspace
    EXCLUDE_ARGS=(
        --exclude='.venv'
        --exclude='.venv-*'
        --exclude='venv'
        --exclude='node_modules'
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.DS_Store'
        --exclude='.ruff_cache'
        --exclude='.mypy_cache'
        --exclude='.pytest_cache'
        --exclude='.fastembed_cache'
        --exclude='.vscode'
        --exclude='.github'
        --exclude='.codex'
        --exclude='.codanna'
        --exclude='.uv'
        --exclude='*.egg-info'
        --exclude='dist'
        --exclude='build'
        --exclude='container-run.toml'
        --exclude='.mcp.json'
    )
    # Append project-specific excludes from EXTRA_EXCLUDES env (newline-separated)
    if [[ -n "${EXTRA_EXCLUDES:-}" ]]; then
        while IFS= read -r _pattern; do
            [[ -z "$_pattern" ]] && continue
            # Special-case plain "bin": exclude only workspace-root ./bin/.
            # This avoids matching nested paths such as src/bin or tools/bin.
            if [[ "$_pattern" == "bin" ]]; then
                EXCLUDE_ARGS+=("--exclude=./bin" "--exclude=./bin/*")
                continue
            fi
            EXCLUDE_ARGS+=("--exclude=$_pattern")
        done <<< "$EXTRA_EXCLUDES"
    fi
    tar -C /mnt/in/workspace "${EXCLUDE_ARGS[@]}" -cf - . | tar -C /workspace -xf -
fi

# ── 3.5 Register MCP servers ─────────────────────────────────────────────────
# Always start with empty .mcp.json — host configs have broken stdio paths
echo '{"mcpServers": {}}' > /workspace/.mcp.json

_mcp_names=()

# ── 3.5a Register Postgres MCP (HTTP, host-side) ────────────────────────────
if [[ -n "${PG_MCP_URL:-}" ]]; then
    echo "[entrypoint] Registering Postgres MCP..." >&2
    if (cd /workspace && claude mcp add postgres --transport http "$PG_MCP_URL" \
        -s project) > /dev/null 2>&1; then
        echo "[entrypoint]   OK: postgres" >&2
        _mcp_names+=("postgres")
    else
        echo "[entrypoint]   FAILED: postgres" >&2
    fi
fi

if [[ -n "${MCP_SERVERS:-}" && -n "${MCP_TOKENS:-}" && -n "${MCP_BASE_URL:-}" ]]; then
    echo "[entrypoint] Registering MCP servers..." >&2
    while IFS= read -r _entry; do
        [[ -z "$_entry" ]] && continue
        _name="$(echo "$_entry" | awk '{print $1}')"
        _path="$(echo "$_entry" | awk '{print $2}')"
        _keychain="$(echo "$_entry" | awk '{print $3}')"
        # Look up token from MCP_TOKENS by keychain service name
        _token=""
        if [[ -n "$_keychain" ]]; then
            _token="$(echo "$MCP_TOKENS" | awk -v svc="$_keychain" '$1 == svc {print $2; exit}')"
        fi
        if [[ -z "$_token" ]]; then
            echo "[entrypoint]   SKIP: $_name (no token for $_keychain)" >&2
            continue
        fi
        if (cd /workspace && claude mcp add --transport http "$_name" "${MCP_BASE_URL}${_path}" \
            --header "Authorization: Bearer ${_token}" \
            -s project) > /dev/null 2>&1; then
            echo "[entrypoint]   OK: $_name" >&2
        else
            echo "[entrypoint]   FAILED: $_name" >&2
        fi
        _mcp_names+=("$_name")
    done <<< "$MCP_SERVERS"
fi

# ── 3.5b Register godoc-mcp (Go containers only, stdio) ──────────────────
if command -v godoc-mcp &>/dev/null; then
    echo "[entrypoint] Registering godoc-mcp MCP server..." >&2
    if (cd /workspace && claude mcp add godoc \
        -e GOPATH="$GOPATH" -e GOMODCACHE="$GOMODCACHE" \
        -s project \
        -- godoc-mcp) > /dev/null 2>&1; then
        echo "[entrypoint]   OK: godoc" >&2
        _mcp_names+=("godoc")
    else
        echo "[entrypoint]   FAILED: godoc (non-fatal)" >&2
    fi
fi

# ── 3.5c Register codex MCP server (stdio) ───────────────────────────────
if command -v codex &>/dev/null; then
    echo "[entrypoint] Registering codex MCP server..." >&2
    if (cd /workspace && claude mcp add codex \
        -s project \
        -- codex mcp-server) > /dev/null 2>&1; then
        echo "[entrypoint]   OK: codex" >&2
        _mcp_names+=("codex")
    else
        echo "[entrypoint]   FAILED: codex (non-fatal)" >&2
    fi
fi

# Build MCP server list for CONTAINER.md (from both postgres and HTTP servers)
if [[ ${#_mcp_names[@]} -gt 0 ]]; then
    HAS_MCP=true
    MCP_SERVER_LIST=""
    for _n in "${_mcp_names[@]}"; do
        MCP_SERVER_LIST+="- \`$_n\`"$'\n'
    done
fi

# ── 3.6 Install LSP plugins (fresh — host cache has broken paths) ───────────
if command -v go &>/dev/null; then
    _lsp_plugin="gopls-lsp@claude-plugins-official"
elif command -v python3 &>/dev/null; then
    _lsp_plugin="pyright-lsp@claude-plugins-official"
else
    _lsp_plugin=""
fi

if [[ -n "$_lsp_plugin" ]]; then
    # Register the official marketplace first (plugins dir was not copied from host)
    echo "[entrypoint] Adding claude-plugins-official marketplace..." >&2
    if claude plugin marketplace add anthropics/claude-plugins-official \
        --scope user > /dev/null 2>&1; then
        echo "[entrypoint]   OK: marketplace added" >&2
    else
        echo "[entrypoint]   FAILED: marketplace add (non-fatal)" >&2
    fi

    echo "[entrypoint] Installing LSP plugin: $_lsp_plugin..." >&2
    if claude plugin install "$_lsp_plugin" > /dev/null 2>&1; then
        echo "[entrypoint]   OK: $_lsp_plugin" >&2
    else
        echo "[entrypoint]   FAILED: $_lsp_plugin (non-fatal)" >&2
    fi
fi

# ── 4. Generate CONTAINER.md ──────────────────────────────────────────────────
# Dynamic context file rendered from templates.
echo "[entrypoint] Generating CONTAINER.md from template..." >&2

CONTAINER_TEMPLATE_DIR="${CONTAINER_TEMPLATE_DIR:-/opt/container-templates}"
CONTAINER_TEMPLATE_PYTHON="${CONTAINER_TEMPLATE_PYTHON:-$CONTAINER_TEMPLATE_DIR/CONTAINER.python.md.tmpl}"
CONTAINER_TEMPLATE_GOLANG="${CONTAINER_TEMPLATE_GOLANG:-$CONTAINER_TEMPLATE_DIR/CONTAINER.golang.md.tmpl}"

get_python_version() {
    if command -v python3 &>/dev/null; then
        python3 --version 2>/dev/null | awk '{print $2}'
    fi
}

get_go_version() {
    if command -v go &>/dev/null; then
        go version | awk '{print $3}' | sed 's/^go//'
    fi
}

get_golangci_lint_version() {
    if command -v golangci-lint &>/dev/null; then
        golangci-lint version 2>/dev/null | sed -n 's/.*version \([^ ,]*\).*/\1/p' | head -n1
    fi
}

get_claude_version() {
    if [[ -f /home/sandbox/.local/share/claude-version ]]; then
        cat /home/sandbox/.local/share/claude-version
    elif command -v claude &>/dev/null; then
        claude --version 2>/dev/null | awk '{print $NF}'
    fi
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
    local output_path="$2"

    local re_if='^[[:space:]]*<if[[:space:]]+([^[:space:]>]+)[[:space:]]*>[[:space:]]*$'
    local re_endif='^[[:space:]]*</if>[[:space:]]*$'
    local line emit=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re_if ]]; then
            local cond="${BASH_REMATCH[1]}"
            if evaluate_condition "$cond"; then
                emit=1
            else
                emit=0
            fi
            continue
        fi
        if [[ "$line" =~ $re_endif ]]; then
            emit=1
            continue
        fi

        if [[ "$emit" -eq 1 ]]; then
            line="${line//\{\{PYTHON_VERSION\}\}/${PYTHON_VERSION:-unknown}}"
            line="${line//\{\{GO_VERSION\}\}/${GO_VERSION:-unknown}}"
            line="${line//\{\{GOLANGCI_LINT_VERSION\}\}/${GOLANGCI_LINT_VERSION:-unknown}}"
            line="${line//\{\{CLAUDE_VERSION\}\}/${CLAUDE_VERSION:-unknown}}"
            line="${line//\{\{MCP_SERVER_LIST\}\}/${MCP_SERVER_LIST:-}}"
            printf '%s\n' "$line"
        fi
    done < "$template_path" > "$output_path"
}

HAS_ACP=false
HAS_CODEX=false
HAS_GOLANGCI_CONFIG=false
HAS_MCP="${HAS_MCP:-false}"
PYTHON_VERSION="$(get_python_version)"
GO_VERSION="$(get_go_version)"
GOLANGCI_LINT_VERSION="$(get_golangci_lint_version)"
CLAUDE_VERSION="$(get_claude_version)"

if command -v claude-agent-acp &>/dev/null; then
    HAS_ACP=true
fi

if command -v codex &>/dev/null; then
    HAS_CODEX=true
fi

if [[ -f /home/sandbox/.golangci.yml || -f /home/sandbox/.golangci.yaml ]]; then
    HAS_GOLANGCI_CONFIG=true
fi

if command -v go &>/dev/null && [[ -f "$CONTAINER_TEMPLATE_GOLANG" ]]; then
    render_template "$CONTAINER_TEMPLATE_GOLANG" /workspace/CONTAINER.md
elif [[ -f "$CONTAINER_TEMPLATE_PYTHON" ]]; then
    render_template "$CONTAINER_TEMPLATE_PYTHON" /workspace/CONTAINER.md
else
    cat > /workspace/CONTAINER.md << 'FALLBACK'
# Container Environment (auto-generated)

Template files not found. Ensure templates are available in /opt/container-templates.
FALLBACK
fi

# ── 5. Change to workspace ──────────────────────────────────────────────────
echo "[entrypoint] Starting Claude Code in /workspace..." >&2
cd /workspace

# ── 6. Verify claude exists ───────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "[entrypoint] ERROR: claude not found in PATH" >&2
    exit 1
fi

# ── 7. Exec claude with any passed arguments ─────────────────────────────────
exec claude "$@"
