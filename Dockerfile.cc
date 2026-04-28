FROM node:20-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl git ca-certificates && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code cc-connect

# Wrap claude to always pass --dangerously-skip-permissions and --mcp-config
RUN CLAUDE_BIN=$(readlink -f /usr/local/bin/claude) && \
    mv "$CLAUDE_BIN" "${CLAUDE_BIN}.real" && \
    printf '#!/bin/sh\nexec "%s.real" --dangerously-skip-permissions --mcp-config /tmp/mcp-config.json "$@"\n' "$CLAUDE_BIN" > "$CLAUDE_BIN" && \
    chmod +x "$CLAUDE_BIN"

# node user (UID 1000) already exists in node:20-slim, use it as non-root runner

COPY scripts/cc-entrypoint.sh /scripts/cc-entrypoint.sh
RUN chmod +x /scripts/cc-entrypoint.sh

ENTRYPOINT ["/scripts/cc-entrypoint.sh"]
