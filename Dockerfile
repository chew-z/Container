# syntax=docker/dockerfile:1
FROM --platform=linux/arm64 debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# ── 1. System packages ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    curl \
    jq \
    ripgrep \
    fd-find \
    fzf \
    python3 \
    python-is-python3 \
    python3-venv \
    openssh-client \
    procps \
    less \
 && rm -rf /var/lib/apt/lists/*

# ── 2. sandbox user ───────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash sandbox

# ── 3. uv (as sandbox user) ───────────────────────────────────────────────────
USER sandbox
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ── 4. Claude Code (as sandbox user) ─────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash

# ── 5. claude-agent-acp binary ───────────────────────────────────────────────
ARG CLAUDE_ACP_VERSION=v0.19.2
RUN curl -fsSL "https://github.com/zed-industries/claude-agent-acp/releases/download/${CLAUDE_ACP_VERSION}/claude-agent-acp-linux-arm64.tar.gz" \
    | tar -xz -C /tmp && \
    mkdir -p /home/sandbox/.local/bin && \
    mv /tmp/claude-agent-acp /home/sandbox/.local/bin/claude-agent-acp && \
    chmod +x /home/sandbox/.local/bin/claude-agent-acp

# ── 6. PATH ───────────────────────────────────────────────────────────────────
ENV PATH=/home/sandbox/.local/bin:/home/sandbox/.cargo/bin:$PATH

# ── 7. Working directory ──────────────────────────────────────────────────────
WORKDIR /home/sandbox

# ── 8. Entrypoint ─────────────────────────────────────────────────────────────
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER sandbox
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
