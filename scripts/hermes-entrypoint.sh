#!/bin/bash
set -e

HERMES_HOME="${HERMES_HOME:-/data/hermes}"

if [ -z "${TARGET_REPO:-}" ]; then
    echo "[hermes-entrypoint] FATAL: TARGET_REPO is empty. Set it in .env (full git URL)." >&2
    exit 1
fi

# Derive workspace dir name from TARGET_REPO (last path segment, strip optional .git suffix).
# Works for https://host/path/repo[.git], git@host:path/repo.git, ssh://git@host/path/repo.git
_target_trim="${TARGET_REPO%/}"
_repo_basename="${_target_trim##*/}"
PROJECT_SLUG="${_repo_basename%.git}"
WORKSPACE_DIR="/workspace/${PROJECT_SLUG}"

# Set up git credential helper for HTTPS URLs (no-op for SSH)
setup_git_credentials() {
    case "$TARGET_REPO" in
        https://*|http://*)
            [ -z "${GIT_TOKEN:-}" ] && return 0
            local proto host user
            proto="${TARGET_REPO%%://*}"
            # strip protocol, then any embedded user@, then everything after first /
            local rest="${TARGET_REPO#*://}"
            rest="${rest##*@}"
            host="${rest%%/*}"
            user="${GIT_USERNAME:-oauth2}"
            mkdir -p "$HOME"
            printf '%s://%s:%s@%s\n' "$proto" "$user" "$GIT_TOKEN" "$host" > "$HOME/.git-credentials"
            chmod 600 "$HOME/.git-credentials"
            git config --global credential.helper store
            ;;
        *)
            # SSH or git:// — assume external SSH key / no auth needed
            ;;
    esac
}

if [ "$(id -u)" = "0" ]; then
    setup_git_credentials

    # Clone target repo if not already present
    if [ ! -d "${WORKSPACE_DIR}/.git" ]; then
        echo "[setup] Cloning ${TARGET_REPO} -> ${WORKSPACE_DIR}..."
        mkdir -p /workspace
        GIT_TERMINAL_PROMPT=0 git clone "${TARGET_REPO}" "${WORKSPACE_DIR}"
        chown -R hermes:hermes /workspace 2>/dev/null || true
    fi

    # workspace 之後會被 cc-connect chown 到 node:node（uid 1000），
    # 跟 hermes 的 uid 10000 不同；事先設 system-wide safe.directory 避免 git 拒讀。
    git config --system --add safe.directory "${WORKSPACE_DIR}" || true

    # Bootstrap hermes config on first run
    mkdir -p "${HERMES_HOME}"
    if [ ! -f "${HERMES_HOME}/config.yaml" ]; then
        sed -e "s|__WORKSPACE_DIR__|${WORKSPACE_DIR}|g" \
            -e "s|__LARK_MCP_PORT__|${LARK_MCP_PORT:-3000}|g" \
            /config/hermes-config.yaml > "${HERMES_HOME}/config.yaml"
    fi
    if [ ! -f "${HERMES_HOME}/.env" ]; then
        printf 'ANTHROPIC_TOKEN=%s\nANTHROPIC_API_KEY=%s\n' \
            "${ANTHROPIC_API_KEY}" "${ANTHROPIC_API_KEY}" > "${HERMES_HOME}/.env"
    fi
fi

# Hand off to the official hermes entrypoint (handles gosu drop, venv, skills sync)
exec /opt/hermes/docker/entrypoint.sh "$@"
