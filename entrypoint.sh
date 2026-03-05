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

# ── 1. Copy ~/.claude config from host mount (essentials only) ────────────────
if [[ -d /mnt/in/claude_dir ]]; then
    echo "[entrypoint] Copying ~/.claude config (essentials only)..." >&2
    mkdir -p /home/sandbox/.claude

    # Config files
    for f in settings.json CLAUDE.md; do
        [[ -f /mnt/in/claude_dir/$f ]] && cp -p "/mnt/in/claude_dir/$f" "/home/sandbox/.claude/$f"
    done

    # Directories — always needed
    for d in commands skills plugins statsig; do
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
    cp /mnt/in/home/.ssh/config /home/sandbox/.ssh/ 2>/dev/null || true
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
            printf '%s\n' "$line"
        fi
    done < "$template_path" > "$output_path"
}

HAS_ACP=false
HAS_GOLANGCI_CONFIG=false
PYTHON_VERSION="$(get_python_version)"
GO_VERSION="$(get_go_version)"
GOLANGCI_LINT_VERSION="$(get_golangci_lint_version)"
CLAUDE_VERSION="$(get_claude_version)"

if command -v claude-agent-acp &>/dev/null; then
    HAS_ACP=true
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
