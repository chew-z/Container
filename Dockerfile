# syntax=docker/dockerfile:1
#
# Multi-target Dockerfile:
#   --target python  → claudecode-python (default)
#   --target golang  → claudecode-golang
#
# ═════════════════════════════════════════════════════════════════════════════
# BASE — shared tooling for all language targets
# ═════════════════════════════════════════════════════════════════════════════
FROM --platform=linux/arm64 debian:bookworm-slim AS base

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

ARG FD_VERSION=10.3.0
ARG GH_VERSION=2.87.3
# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    curl \
    jq \
    ripgrep \
    fzf \
    openssh-client \
    procps \
    less \
    sudo \
    tree \
    patch \
    file \
 && rm -rf /var/lib/apt/lists/*

# ── fd (upstream binary — Debian's fd-find installs as fdfind) ───────────
RUN curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /tmp && \
    mv /tmp/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu/fd /usr/local/bin/fd && \
    rm -rf /tmp/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu

# ── sandbox user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash sandbox && \
    echo 'sandbox ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/sandbox

# ── Git safe directory (bind-mounted repos) ──────────────────────────────────
RUN git config --system safe.directory '*'

# ── GitHub CLI ─────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz" \
    | tar -xz -C /tmp && \
    mv /tmp/gh_${GH_VERSION}_linux_arm64/bin/gh /usr/local/bin/gh && \
    rm -rf /tmp/gh_${GH_VERSION}_linux_arm64

# ── PATH + working directory ────────────────────────────────────────────────
USER sandbox
RUN mkdir -p /home/sandbox/.local/bin /home/sandbox/.local/share
ENV PATH=/home/sandbox/.local/bin:/home/sandbox/.cargo/bin:$PATH
ENV TERM=xterm-256color
WORKDIR /home/sandbox

# NOTE: Claude Code, entrypoint.sh and templates are installed in each final
# stage (python/golang), NOT here in base. This keeps base ultra-stable —
# only system package or tool version changes bust the cache. Layers ordered
# by change frequency: language tools (rare) → Claude Code (weekly) →
# entrypoint.sh (dev iterations).


# ═════════════════════════════════════════════════════════════════════════════
# PYTHON — Python 3.14 via uv
# ═════════════════════════════════════════════════════════════════════════════
FROM base AS python

# ── uv ────────────────────────────────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG PYTHON_VERSION=3.14
RUN uv python install ${PYTHON_VERSION} && \
    PYTHON_BIN=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "$PYTHON_BIN" /home/sandbox/.local/bin/python3 && \
    ln -sf "$PYTHON_BIN" /home/sandbox/.local/bin/python

# ── Claude Code (changes weekly — after stable language layers) ─────────────
ARG CLAUDE_CODE_GCS=https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases
ARG CLAUDE_CODE_VERSION=latest
ARG INSTALL_CLAUDE_AGENT_ACP=0
ARG CLAUDE_AGENT_ACP_VERSION=latest
RUN if [[ "${CLAUDE_CODE_VERSION}" == "latest" ]]; then \
            CLAUDE_VERSION=$(curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "${CLAUDE_CODE_GCS}/latest"); \
        else \
            CLAUDE_VERSION="${CLAUDE_CODE_VERSION}"; \
        fi && \
    echo "Downloading Claude Code v${CLAUDE_VERSION} for linux-arm64..." && \
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "${CLAUDE_CODE_GCS}/${CLAUDE_VERSION}/linux-arm64/claude" \
        -o /home/sandbox/.local/bin/claude && \
        chmod +x /home/sandbox/.local/bin/claude && \
        echo "${CLAUDE_VERSION}" > /home/sandbox/.local/share/claude-version
RUN if [[ "${INSTALL_CLAUDE_AGENT_ACP}" == "1" ]]; then \
            if [[ "${CLAUDE_AGENT_ACP_VERSION}" == "latest" ]]; then \
                CLAUDE_ACP_VERSION=$(curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "https://api.github.com/repos/zed-industries/claude-agent-acp/releases/latest" | jq -r '.tag_name'); \
            else \
                CLAUDE_ACP_VERSION="${CLAUDE_AGENT_ACP_VERSION}"; \
            fi; \
            echo "Downloading claude-agent-acp ${CLAUDE_ACP_VERSION} for linux-arm64..."; \
            curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "https://github.com/zed-industries/claude-agent-acp/releases/download/${CLAUDE_ACP_VERSION}/claude-agent-acp-linux-arm64.tar.gz" \
            | tar -xz -C /tmp; \
            mv /tmp/claude-agent-acp /home/sandbox/.local/bin/claude-agent-acp; \
            chmod +x /home/sandbox/.local/bin/claude-agent-acp; \
            echo "${CLAUDE_ACP_VERSION}" > /home/sandbox/.local/share/claude-agent-acp-version; \
        else \
            echo "Skipping claude-agent-acp installation (INSTALL_CLAUDE_AGENT_ACP=${INSTALL_CLAUDE_AGENT_ACP})."; \
        fi

# ── Entrypoint (last — most frequently changed) ─────────────────────────────
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY templates/ /opt/container-templates/
RUN chmod +x /usr/local/bin/entrypoint.sh
USER sandbox
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


# ═════════════════════════════════════════════════════════════════════════════
# GOLANG — Go 1.26
# ═════════════════════════════════════════════════════════════════════════════
FROM base AS golang

USER root
ARG GO_VERSION=1.26.0
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" \
    | tar -xz -C /usr/local
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
 && rm -rf /var/lib/apt/lists/*

ARG GOLANGCI_LINT_VERSION=v2.4.0
RUN curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-arm64.tar.gz" \
    | tar -xz -C /tmp && \
    mv "/tmp/golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-arm64/golangci-lint" /usr/local/bin/golangci-lint && \
    chmod +x /usr/local/bin/golangci-lint && \
    rm -rf "/tmp/golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-arm64"

ENV PATH=/usr/local/go/bin:/home/sandbox/go/bin:$PATH
ENV GOPATH=/home/sandbox/go
ENV GOBIN=/home/sandbox/.local/bin
ENV GOCACHE=/home/sandbox/.cache/go-build
ENV GOMODCACHE=/home/sandbox/go/pkg/mod
ENV GOLANGCI_LINT_CACHE=/home/sandbox/.cache/golangci-lint
RUN mkdir -p /home/sandbox/go \
    /home/sandbox/.cache/go-build \
    /home/sandbox/.cache/golangci-lint \
 && chown -R sandbox:sandbox /home/sandbox/go /home/sandbox/.cache
USER sandbox
RUN go install golang.org/x/tools/gopls@latest && \
    go install golang.org/x/tools/cmd/goimports@latest && \
    go install gotest.tools/gotestsum@latest && \
    go install golang.org/x/vuln/cmd/govulncheck@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest && \
    go clean -modcache -cache
RUN go version && \
    golangci-lint version && \
    gopls version >/dev/null && \
    command -v goimports && \
    gotestsum --version >/dev/null && \
    govulncheck -version >/dev/null && \
    dlv version >/dev/null

# ── Claude Code (changes weekly — after stable language layers) ─────────────
ARG CLAUDE_CODE_GCS=https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases
ARG CLAUDE_CODE_VERSION=latest
ARG INSTALL_CLAUDE_AGENT_ACP=0
ARG CLAUDE_AGENT_ACP_VERSION=latest
RUN if [[ "${CLAUDE_CODE_VERSION}" == "latest" ]]; then \
            CLAUDE_VERSION=$(curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "${CLAUDE_CODE_GCS}/latest"); \
        else \
            CLAUDE_VERSION="${CLAUDE_CODE_VERSION}"; \
        fi && \
    echo "Downloading Claude Code v${CLAUDE_VERSION} for linux-arm64..." && \
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "${CLAUDE_CODE_GCS}/${CLAUDE_VERSION}/linux-arm64/claude" \
        -o /home/sandbox/.local/bin/claude && \
        chmod +x /home/sandbox/.local/bin/claude && \
        echo "${CLAUDE_VERSION}" > /home/sandbox/.local/share/claude-version
RUN if [[ "${INSTALL_CLAUDE_AGENT_ACP}" == "1" ]]; then \
            if [[ "${CLAUDE_AGENT_ACP_VERSION}" == "latest" ]]; then \
                CLAUDE_ACP_VERSION=$(curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "https://api.github.com/repos/zed-industries/claude-agent-acp/releases/latest" | jq -r '.tag_name'); \
            else \
                CLAUDE_ACP_VERSION="${CLAUDE_AGENT_ACP_VERSION}"; \
            fi; \
            echo "Downloading claude-agent-acp ${CLAUDE_ACP_VERSION} for linux-arm64..."; \
            curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "https://github.com/zed-industries/claude-agent-acp/releases/download/${CLAUDE_ACP_VERSION}/claude-agent-acp-linux-arm64.tar.gz" \
            | tar -xz -C /tmp; \
            mv /tmp/claude-agent-acp /home/sandbox/.local/bin/claude-agent-acp; \
            chmod +x /home/sandbox/.local/bin/claude-agent-acp; \
            echo "${CLAUDE_ACP_VERSION}" > /home/sandbox/.local/share/claude-agent-acp-version; \
        else \
            echo "Skipping claude-agent-acp installation (INSTALL_CLAUDE_AGENT_ACP=${INSTALL_CLAUDE_AGENT_ACP})."; \
        fi

# ── Entrypoint (last — most frequently changed) ─────────────────────────────
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY templates/ /opt/container-templates/
RUN chmod +x /usr/local/bin/entrypoint.sh
USER sandbox
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
