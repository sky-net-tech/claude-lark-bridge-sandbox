#!/usr/bin/env bash
# cc-watchdog.sh — detect stuck cc-connect session and auto-restart.
#
# Stuck definition: a "processing message" event newer than the last
# "turn complete" event AND older than $STUCK_THRESHOLD seconds.
#
# Cooldown: skip if last restart happened within $RESTART_COOLDOWN seconds,
# to avoid restart storms.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CONTAINER="company-doc-cc-connect-1"
COMPOSE_FILE="/Users/skynet-admin/docker/company-doc-bot/docker-compose.yml"
SERVICE="cc-connect"
DOCKER_SOCK="unix:///var/run/docker.sock"

STUCK_THRESHOLD=${STUCK_THRESHOLD:-900}        # 15 min: processing without turn complete
RESTART_COOLDOWN=${RESTART_COOLDOWN:-600}       # 10 min between restarts
LOG_WINDOW=${LOG_WINDOW:-2h}                    # how far back to scan logs

LOG_FILE="${HOME}/Library/Logs/cc-watchdog.log"
STATE_FILE="${HOME}/Library/Caches/cc-watchdog.last_restart"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

iso_to_epoch() {
    # Input: 2026-04-30T05:13:06  (no milliseconds, no Z) — interpreted as UTC.
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$1" "+%s" 2>/dev/null || echo 0
}

extract_last_ts() {
    # $1 = pattern; reads stdin (logs); prints ISO-8601 trimmed timestamp
    grep -E "$1" | tail -1 | grep -oE 'time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | sed 's/time=//'
}

# Check container is running first
if ! DOCKER_HOST="$DOCKER_SOCK" docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    log "container $CONTAINER not running, skip"
    exit 0
fi

LOGS=$(DOCKER_HOST="$DOCKER_SOCK" docker logs "$CONTAINER" --since "$LOG_WINDOW" 2>&1 || true)

last_proc=$(printf '%s\n' "$LOGS" | extract_last_ts 'msg="processing message"')
last_done=$(printf '%s\n' "$LOGS" | extract_last_ts 'msg="turn complete"')

# No "processing message" in window → nothing to judge
if [ -z "$last_proc" ]; then
    exit 0
fi

now=$(date -u +%s)
proc_epoch=$(iso_to_epoch "$last_proc")
done_epoch=$([ -n "$last_done" ] && iso_to_epoch "$last_done" || echo 0)
proc_age=$(( now - proc_epoch ))

# Healthy if: turn complete is newer than processing, OR processing is recent
if [ "$done_epoch" -ge "$proc_epoch" ]; then
    exit 0
fi
if [ "$proc_age" -lt "$STUCK_THRESHOLD" ]; then
    exit 0
fi

# Stuck. Check cooldown.
last_restart_epoch=0
if [ -f "$STATE_FILE" ]; then
    last_restart_epoch=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
if [ "$(( now - last_restart_epoch ))" -lt "$RESTART_COOLDOWN" ]; then
    log "stuck detected (proc=$last_proc age=${proc_age}s done=$last_done) but in cooldown, skip"
    exit 0
fi

log "STUCK detected: last processing=$last_proc (${proc_age}s ago), last turn complete=${last_done:-none}. Restarting $SERVICE."
if DOCKER_HOST="$DOCKER_SOCK" docker-compose -f "$COMPOSE_FILE" restart "$SERVICE" >> "$LOG_FILE" 2>&1; then
    echo "$now" > "$STATE_FILE"
    log "restart OK"
else
    log "restart FAILED"
    exit 1
fi
