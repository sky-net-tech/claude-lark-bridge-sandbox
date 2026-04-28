#!/bin/bash
set -e

HERMES_HOME="${HERMES_HOME:-/data/hermes}"

if [ "$(id -u)" = "0" ]; then
    # Clone company-doc if not already present
    if [ ! -d /workspace/company-doc/.git ]; then
        echo "[setup] Cloning sky-net-tech/company-doc..."
        mkdir -p /workspace
        GH_TOKEN="${GH_TOKEN}" gh repo clone sky-net-tech/company-doc /workspace/company-doc
        chown -R hermes:hermes /workspace 2>/dev/null || true
    fi

    # Bootstrap hermes config on first run
    mkdir -p "${HERMES_HOME}"
    if [ ! -f "${HERMES_HOME}/config.yaml" ]; then
        cp /config/hermes-config.yaml "${HERMES_HOME}/config.yaml"
    fi
    if [ ! -f "${HERMES_HOME}/.env" ]; then
        printf 'ANTHROPIC_TOKEN=%s\nANTHROPIC_API_KEY=%s\n' \
            "${ANTHROPIC_API_KEY}" "${ANTHROPIC_API_KEY}" > "${HERMES_HOME}/.env"
    fi
fi

# Hand off to the official hermes entrypoint (handles gosu drop, venv, skills sync)
exec /opt/hermes/docker/entrypoint.sh "$@"
