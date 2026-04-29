#!/usr/bin/env bash
# 切換誰來接 Lark：cc-connect 或 hermes。
#
# 用法：
#   bash scripts/switch-platform.sh cc-connect    # 預設模式（Claude Code 透過 cc-connect）
#   bash scripts/switch-platform.sh hermes        # hermes 直接接 Lark + MCP
#   bash scripts/switch-platform.sh status        # 查目前模式
#
# 限制：
#   - 同一個 Lark app 的 websocket 同時只能一個 client，兩模式不可並存
#   - hermes 模式不吃 Claude 訂閱憑證，必須有 ANTHROPIC_API_KEY
#   - LARK 國際版固定（FEISHU_DOMAIN=lark）；中國版需自行調整 override file

set -euo pipefail

# 顏色
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_RST=$(tput sgr0)
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

mode="${1:-}"
[ -f docker-compose.yml ] || die "請在 repo 根目錄執行（找不到 docker-compose.yml）"
[ -f .env ] || die "請先跑 bash scripts/setup.sh 產生 .env"

# 從 .env 抓某個 key 是否非空
env_has() {
    local key="$1"
    grep -E "^${key}=.+" .env 2>/dev/null | tail -1 \
        | grep -Evq "^${key}=$|^${key}=''$|^${key}=\"\"$"
}

# 顯示目前狀態
show_status() {
    docker compose ps --format '  {{.Service}}: {{.State}}/{{.Health}}' 2>/dev/null || true
    # 偵測模式：看 hermes 容器是否有 FEISHU_APP_ID
    if docker compose ps -q hermes 2>/dev/null | grep -q .; then
        local has_feishu
        has_feishu=$(docker compose exec -T hermes printenv FEISHU_APP_ID 2>/dev/null || echo "")
        if [ -n "$has_feishu" ]; then
            ok "目前模式：hermes（hermes 直接接 Lark）"
        else
            ok "目前模式：cc-connect（cc-connect 接 Lark）"
        fi
    else
        warn "hermes 容器未啟動"
    fi
}

case "$mode" in
    cc-connect)
        ok "切換到 cc-connect 模式..."
        # 用 base compose（不帶 override）重建：hermes 會少掉 FEISHU_* env，cc-connect 啟動
        docker compose -f docker-compose.yml up -d --remove-orphans hermes lark-mcp cc-connect
        ok "完成。cc-connect 已上線、hermes 退回 memory/cron 模式"
        ;;
    hermes)
        ok "切換到 hermes 模式..."
        env_has ANTHROPIC_API_KEY \
            || die "hermes 模式需要 ANTHROPIC_API_KEY（CLAUDE_CREDENTIALS_B64 不適用）。請編輯 .env 後重試"
        env_has FEISHU_APP_ID || die ".env 內 FEISHU_APP_ID 為空"
        env_has FEISHU_APP_SECRET || die ".env 內 FEISHU_APP_SECRET 為空"
        # 先停 cc-connect 釋放 Lark websocket
        docker compose stop cc-connect 2>/dev/null || true
        # 帶 override 重建 hermes（注入 FEISHU_*）
        docker compose -f docker-compose.yml -f docker-compose.hermes-platform.yml \
            up -d --remove-orphans hermes lark-mcp
        ok "完成。hermes 已上線並接 Lark；cc-connect 已停止"
        warn "注意：cc-connect 容器仍存在（stopped）；要刪除請執行 'docker compose rm -f cc-connect'"
        ;;
    status|"")
        show_status
        ;;
    *)
        die "未知模式：${mode}（用 cc-connect / hermes / status）"
        ;;
esac
