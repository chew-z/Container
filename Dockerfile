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
 && rm -rf /var/lib/apt/lists/*

# ── fd (upstream binary — Debian's fd-find installs as fdfind) ───────────
ARG FD_VERSION=10.3.0
RUN curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /tmp && \
    mv /tmp/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu/fd /usr/local/bin/fd && \
    rm -rf /tmp/fd-v${FD_VERSION}-aarch64-unknown-linux-gnu

# ── sandbox user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash sandbox

# ── Git safe directory (bind-mounted repos) ──────────────────────────────────
RUN git config --system safe.directory '*'

# ── GitHub CLI ─────────────────────────────────────────────────────────────
ARG GH_VERSION=2.87.3
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz" \
    | tar -xz -C /tmp && \
    mv /tmp/gh_${GH_VERSION}_linux_arm64/bin/gh /usr/local/bin/gh && \
    rm -rf /tmp/gh_${GH_VERSION}_linux_arm64

# ── uv (as sandbox user) ────────────────────────────────────────────────────
USER sandbox
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ── Claude Code (direct binary — no Bun/npm, no OOM) ──────────────────────
ARG CLAUDE_CODE_GCS=https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases
RUN mkdir -p /home/sandbox/.local/bin && \
    CLAUDE_VERSION=$(curl -fsSL "${CLAUDE_CODE_GCS}/latest") && \
    echo "Downloading Claude Code v${CLAUDE_VERSION} for linux-arm64..." && \
    curl -fsSL "${CLAUDE_CODE_GCS}/${CLAUDE_VERSION}/linux-arm64/claude" \
        -o /home/sandbox/.local/bin/claude && \
    chmod +x /home/sandbox/.local/bin/claude

# ── claude-agent-acp binary (resolves latest from GitHub at build time) ────
RUN CLAUDE_ACP_VERSION=$(curl -fsSL "https://api.github.com/repos/zed-industries/claude-agent-acp/releases/latest" | jq -r '.tag_name') && \
    echo "Downloading claude-agent-acp ${CLAUDE_ACP_VERSION} for linux-arm64..." && \
    curl -fsSL "https://github.com/zed-industries/claude-agent-acp/releases/download/${CLAUDE_ACP_VERSION}/claude-agent-acp-linux-arm64.tar.gz" \
    | tar -xz -C /tmp && \
    mv /tmp/claude-agent-acp /home/sandbox/.local/bin/claude-agent-acp && \
    chmod +x /home/sandbox/.local/bin/claude-agent-acp

# ── PATH + working directory ────────────────────────────────────────────────
ENV PATH=/home/sandbox/.local/bin:/home/sandbox/.cargo/bin:$PATH
WORKDIR /home/sandbox

# ── Entrypoint ──────────────────────────────────────────────────────────────
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
USER sandbox

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


# ═════════════════════════════════════════════════════════════════════════════
# PYTHON — Python 3.14 via uv
# ═════════════════════════════════════════════════════════════════════════════
FROM base AS python

ARG PYTHON_VERSION=3.14
RUN uv python install ${PYTHON_VERSION} && \
    PYTHON_BIN=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "$PYTHON_BIN" /home/sandbox/.local/bin/python3 && \
    ln -sf "$PYTHON_BIN" /home/sandbox/.local/bin/python


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
    go install golang.org/x/vuln/cmd/govulncheck@latest
RUN go version && \
    golangci-lint version && \
    gopls version >/dev/null && \
    goimports -help >/dev/null && \
    gotestsum --version >/dev/null && \
    govulncheck -version >/dev/null
