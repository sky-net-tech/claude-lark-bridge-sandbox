#!/usr/bin/env bash
# claude-lark-bridge-sandbox 一鍵安裝腳本
#
# 七個 phase：
#   1. Pre-flight     — docker / docker compose / curl / base64 / python3 / git / daemon
#   2. .env 處理      — 偵測既有檔，覆蓋 / 沿用 / 中止
#   3. 互動填值       — 必填、有預設、opt-in 三類
#   4. 寫入 .env      — heredoc 重建，chmod 600
#   5. Live API 驗證  — git ls-remote / Lark tenant_access_token / Anthropic /v1/models
#   6. docker compose build
#   7. docker compose up -d + 等 healthcheck
#
# 跨 macOS / Linux 相容（bash 3.2+，不依賴 jq / yq）。

set -euo pipefail

# ---------- 共用工具 ----------

# 顏色（只在 TTY 時使用）
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
    C_BLU=$(tput setaf 4); C_DIM=$(tput dim);     C_BLD=$(tput bold)
    C_RST=$(tput sgr0)
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_RST=""
fi

info()   { printf '%s[info]%s %s\n'   "$C_BLU" "$C_RST" "$*"; }
ok()     { printf '%s[ ok ]%s %s\n'   "$C_GRN" "$C_RST" "$*"; }
warn()   { printf '%s[warn]%s %s\n'   "$C_YEL" "$C_RST" "$*" >&2; }
err()    { printf '%s[fail]%s %s\n'   "$C_RED" "$C_RST" "$*" >&2; }
header() { printf '\n%s%s── %s ──%s\n' "$C_BLD" "$C_BLU" "$*" "$C_RST"; }

die() { err "$*"; exit 1; }

# 檢查互動 TTY；無 TTY 直接退出，避免 read 卡住
require_tty() {
    if [ ! -t 0 ]; then
        die "需要互動 TTY（請在終端機直接執行，不要從 pipe 或 < /dev/null 輸入）"
    fi
}

# 跨平台 prompt：read -r [-s]，提示加上 [預設] 字樣
# 用法：prompt_value "問題" "預設值" [hidden=1] -> echo 結果到 stdout
prompt_value() {
    local question="$1"
    local default="${2:-}"
    local hidden="${3:-0}"
    local hint=""
    [ -n "$default" ] && hint=" [${default}]"
    local reply=""
    if [ "$hidden" = "1" ]; then
        # 隱藏輸入；BSD/GNU 都支援 read -s -p（bash）
        printf '%s%s%s ' "$question" "$hint" ":" >&2
        IFS= read -rs reply || true
        printf '\n' >&2
    else
        printf '%s%s%s ' "$question" "$hint" ":" >&2
        IFS= read -r reply || true
    fi
    if [ -z "$reply" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$reply"
    fi
}

# Y/n 預設 yes，y/N 預設 no
confirm() {
    local question="$1"
    local default="${2:-Y}"   # Y or N
    local hint
    if [ "$default" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    local reply=""
    printf '%s %s ' "$question" "$hint" >&2
    IFS= read -r reply || true
    if [ -z "$reply" ]; then reply="$default"; fi
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# 用 python3 做最小可信賴的 JSON 取值；不依賴 jq
# 用法：echo "$json" | json_get '.code'
json_get() {
    local path="$1"
    python3 -c '
import json, sys
data = json.load(sys.stdin)
parts = sys.argv[1].lstrip(".").split(".") if sys.argv[1] != "" else []
cur = data
for p in parts:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        cur = None
        break
if cur is None:
    sys.exit(2)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
' "$path"
}

# 跨平台時間戳
now_stamp() { date '+%Y%m%d-%H%M%S'; }

# 跨平台 base64 encode（讀檔 → single-line）
base64_encode_file() {
    base64 < "$1" | tr -d '\n'
}

# 跨平台 base64 decode 到 stdout
base64_decode() {
    base64 -d 2>/dev/null
}

# Shell-escape 單一值，包成 'value'，內含單引號做轉義
sh_quote() {
    local v="$1"
    # 把 ' 換成 '\''
    local escaped
    escaped=$(printf '%s' "$v" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$escaped"
}

# 從 .env 檔抓某個 key 的 value（保留空值）
get_env_value() {
    local file="$1" key="$2"
    [ -f "$file" ] || { printf ''; return; }
    # 抓最後一次出現（後者覆蓋前者，符合 docker compose 行為）
    local line
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)
    [ -z "$line" ] && { printf ''; return; }
    local v="${line#${key}=}"
    # 去掉首尾單/雙引號（若有）
    case "$v" in
        \"*\") v="${v%\"}"; v="${v#\"}" ;;
        \'*\') v="${v%\'}"; v="${v#\'}" ;;
    esac
    printf '%s' "$v"
}

# ---------- Phase 1: Pre-flight ----------

phase1_preflight() {
    header "Phase 1：Pre-flight 檢查"

    # 必須在 repo 根目錄執行
    [ -f .env.example ] || die "找不到 .env.example，請在 docker-compose.yml 所在目錄執行"
    [ -f docker-compose.yml ] || die "找不到 docker-compose.yml，請在 repo 根目錄執行"

    # 工具
    command -v docker >/dev/null 2>&1 || die "找不到 docker，請先安裝 Docker Desktop / Engine"
    docker compose version >/dev/null 2>&1 || die "docker compose v2 未安裝（不支援舊版 docker-compose）"
    command -v curl >/dev/null 2>&1 || die "找不到 curl"
    command -v base64 >/dev/null 2>&1 || die "找不到 base64"
    command -v python3 >/dev/null 2>&1 || die "找不到 python3（用於 JSON 解析）"

    # daemon
    docker info >/dev/null 2>&1 || die "Docker daemon 未啟動，請先啟動 Docker"

    ok "工具與 daemon 都正常"
}

# ---------- Phase 2: .env 處理 ----------

# 設定全域：ENV_MODE = overwrite | reuse
# DEFAULTS 來源檔：reuse → 既有 .env；overwrite → .env.example
ENV_MODE=""
DEFAULTS_FILE=""

phase2_env_file() {
    header "Phase 2：.env 檔處理"
    if [ -f .env ]; then
        info ".env 已存在"
        printf '  1) 覆蓋（先備份既有檔）\n'
        printf '  2) 沿用（跳過互動填值，重新驗證 + build + up）\n'
        printf '  3) 中止\n'
        local choice
        choice=$(prompt_value "請選擇" "2")
        case "$choice" in
            1)
                local backup=".env.backup.$(now_stamp)"
                cp .env "$backup"
                ok "已備份 .env → $backup"
                ENV_MODE="overwrite"
                DEFAULTS_FILE=".env"   # 用既有 .env 當每個欄位的預設值
                ;;
            2)
                ENV_MODE="reuse"
                DEFAULTS_FILE=".env"
                ok "沿用既有 .env"
                ;;
            *)
                die "中止"
                ;;
        esac
    else
        ENV_MODE="overwrite"
        DEFAULTS_FILE=".env.example"
        ok "新建 .env（預設值取自 .env.example）"
    fi
}

# ---------- Phase 3: 互動填值 ----------

# 全域變數：phase3 結果
V_CLAUDE_CREDENTIALS_B64=""
V_ANTHROPIC_API_KEY=""
V_GIT_TOKEN=""
V_GIT_USERNAME=""
V_FEISHU_APP_ID=""
V_FEISHU_APP_SECRET=""
V_TARGET_REPO=""
V_LARK_DOMAIN=""
V_LARK_MCP_PORT=""
V_LARK_MCP_HOST_PORT=""
V_LARK_MCP_TOOLS=""
V_CC_LANGUAGE=""
V_CC_PROGRESS_STYLE=""
V_COMPOSE_PROJECT_NAME=""

# 用哪種 Claude 認證：subscription / api_key
CLAUDE_AUTH_MODE=""

phase3_prompts() {
    header "Phase 3：互動填值"

    # ---- 3.1 必填 ----

    # Claude 認證子流程
    prompt_claude_auth

    # GIT_TOKEN（公開 repo 可留空）
    local gt_default
    gt_default=$(get_env_value "$DEFAULTS_FILE" "GIT_TOKEN")
    info "GIT_TOKEN：私 repo 必填；公開 repo 留空即可"
    info "  GitHub: scope repo/public_repo｜GitLab: scope read_repository"
    V_GIT_TOKEN=$(prompt_value "GIT_TOKEN" "$gt_default" 1)

    # GIT_USERNAME（HTTPS 基本認證 username，預設 oauth2）
    local gu_default
    gu_default=$(get_env_value "$DEFAULTS_FILE" "GIT_USERNAME")
    [ -z "$gu_default" ] && gu_default="oauth2"
    if [ -n "$V_GIT_TOKEN" ]; then
        info "GIT_USERNAME 目前：${gu_default}（GitHub/GitLab 都吃 oauth2；Bitbucket 用 x-token-auth）"
        if confirm "使用此值？" "Y"; then
            V_GIT_USERNAME="$gu_default"
        else
            V_GIT_USERNAME=$(prompt_value "GIT_USERNAME" "$gu_default")
        fi
    else
        V_GIT_USERNAME="$gu_default"
    fi

    # FEISHU_APP_ID
    local fid_default
    fid_default=$(get_env_value "$DEFAULTS_FILE" "FEISHU_APP_ID")
    while :; do
        local v
        v=$(prompt_value "FEISHU_APP_ID（形如 cli_xxxxxxxx）" "$fid_default")
        if [ -n "$v" ]; then V_FEISHU_APP_ID="$v"; break; fi
        warn "FEISHU_APP_ID 不可為空"
    done

    # FEISHU_APP_SECRET
    local fsec_default
    fsec_default=$(get_env_value "$DEFAULTS_FILE" "FEISHU_APP_SECRET")
    while :; do
        local v
        v=$(prompt_value "FEISHU_APP_SECRET" "$fsec_default" 1)
        if [ -n "$v" ]; then V_FEISHU_APP_SECRET="$v"; break; fi
        warn "FEISHU_APP_SECRET 不可為空"
    done

    # TARGET_REPO（必填無預設，完整 git URL）
    local tr_default
    tr_default=$(get_env_value "$DEFAULTS_FILE" "TARGET_REPO")
    info "TARGET_REPO 範例："
    info "  https://github.com/owner/repo.git"
    info "  https://gitlab.com/group/project.git"
    info "  git@github.com:owner/repo.git    （SSH，需自備 key）"
    while :; do
        local v
        v=$(prompt_value "TARGET_REPO（完整 git URL）" "$tr_default")
        if [ -z "$v" ]; then warn "TARGET_REPO 不可為空"; continue; fi
        # 接受 https://、http://、ssh://、git://、user@host:path 五種形式
        if printf '%s' "$v" | grep -Eq '^(https?://|ssh://|git://|[A-Za-z0-9._-]+@[^:[:space:]]+:)'; then
            V_TARGET_REPO="$v"
            case "$v" in
                git@*|ssh://*) warn "SSH URL：容器預設不掛載 ~/.ssh，clone 會失敗。除非你另外掛 SSH key 進容器，否則建議改用 HTTPS。" ;;
            esac
            break
        fi
        warn "看起來不像 git URL，請重填"
    done

    # ---- 3.2 有預設值 ----

    # LARK_DOMAIN
    local ld_default
    ld_default=$(get_env_value "$DEFAULTS_FILE" "LARK_DOMAIN")
    [ -z "$ld_default" ] && ld_default="https://open.larksuite.com"
    info "LARK_DOMAIN 目前：$ld_default"
    if confirm "使用此值？" "Y"; then
        V_LARK_DOMAIN="$ld_default"
    else
        printf '  1) 國際版 https://open.larksuite.com\n'
        printf '  2) 中國版 https://open.feishu.cn\n'
        printf '  3) 自訂\n'
        local choice
        choice=$(prompt_value "請選擇" "1")
        case "$choice" in
            1) V_LARK_DOMAIN="https://open.larksuite.com" ;;
            2) V_LARK_DOMAIN="https://open.feishu.cn" ;;
            3) V_LARK_DOMAIN=$(prompt_value "輸入自訂 LARK_DOMAIN（含 https://）" "") ;;
            *) V_LARK_DOMAIN="$ld_default" ;;
        esac
    fi

    # LARK_MCP_PORT
    local lmp_default
    lmp_default=$(get_env_value "$DEFAULTS_FILE" "LARK_MCP_PORT")
    [ -z "$lmp_default" ] && lmp_default="3000"
    info "LARK_MCP_PORT 目前：${lmp_default}（容器內部監聽埠）"
    if confirm "使用此值？" "Y"; then
        V_LARK_MCP_PORT="$lmp_default"
    else
        while :; do
            local v
            v=$(prompt_value "LARK_MCP_PORT（1024-65535）" "$lmp_default")
            if printf '%s' "$v" | grep -Eq '^[0-9]+$' && [ "$v" -ge 1024 ] && [ "$v" -le 65535 ]; then
                V_LARK_MCP_PORT="$v"; break
            fi
            warn "需為 1024-65535 的數字"
        done
    fi

    # LARK_MCP_TOOLS
    local lmt_default
    lmt_default=$(get_env_value "$DEFAULTS_FILE" "LARK_MCP_TOOLS")
    [ -z "$lmt_default" ] && lmt_default="preset.doc.default,minutes.v1.minute.get,im.v1.message.create,im.v1.chat.list,im.v1.chat.get,im.v1.chatMembers.get"
    info "LARK_MCP_TOOLS 目前："
    printf '  %s\n' "$lmt_default"
    if confirm "使用此值？" "Y"; then
        V_LARK_MCP_TOOLS="$lmt_default"
    else
        V_LARK_MCP_TOOLS=$(prompt_value "輸入新 LARK_MCP_TOOLS（逗號分隔）" "$lmt_default")
    fi

    # CC_LANGUAGE
    local cl_default
    cl_default=$(get_env_value "$DEFAULTS_FILE" "CC_LANGUAGE")
    [ -z "$cl_default" ] && cl_default="zh-TW"
    info "CC_LANGUAGE 目前：$cl_default"
    if confirm "使用此值？" "Y"; then
        V_CC_LANGUAGE="$cl_default"
    else
        V_CC_LANGUAGE=$(prompt_value "輸入新 CC_LANGUAGE" "$cl_default")
    fi

    # CC_PROGRESS_STYLE
    local cps_default
    cps_default=$(get_env_value "$DEFAULTS_FILE" "CC_PROGRESS_STYLE")
    [ -z "$cps_default" ] && cps_default="compact"
    info "CC_PROGRESS_STYLE 目前：$cps_default"
    if confirm "使用此值？" "Y"; then
        V_CC_PROGRESS_STYLE="$cps_default"
    else
        V_CC_PROGRESS_STYLE=$(prompt_value "輸入新 CC_PROGRESS_STYLE" "$cps_default")
    fi

    # ---- 3.3 opt-in ----

    local lhp_default
    lhp_default=$(get_env_value "$DEFAULTS_FILE" "LARK_MCP_HOST_PORT")
    if [ -n "$lhp_default" ] || confirm "對外暴露 lark-mcp 給 host（除錯用）？" "N"; then
        local v
        v=$(prompt_value "LARK_MCP_HOST_PORT（host 上未被佔用的埠）" "${lhp_default:-3000}")
        V_LARK_MCP_HOST_PORT="$v"
        warn "別忘了解除 docker-compose.yml 內 lark-mcp.ports: 區段註解才會真的暴露"
    else
        V_LARK_MCP_HOST_PORT=""
    fi

    local cpn_default
    cpn_default=$(get_env_value "$DEFAULTS_FILE" "COMPOSE_PROJECT_NAME")
    if [ -n "$cpn_default" ] || confirm "自訂 docker compose project name（影響容器命名前綴）？" "N"; then
        local v
        v=$(prompt_value "COMPOSE_PROJECT_NAME" "${cpn_default:-$(basename "$PWD")}")
        V_COMPOSE_PROJECT_NAME="$v"
    else
        V_COMPOSE_PROJECT_NAME=""
    fi

    ok "所有欄位已收集"
}

# Claude 認證子流程
#
# 設計：claude-data volume 才是憑證唯一真相，這裡的 b64 只在「volume 為空」時被
# entrypoint 一次性 seed 進去，refresh 後的新 token 不會回灌到 .env。
#
# 三條路：
#   1) 自動偵測 host 既有訂閱憑證並 seed（推薦給有跑過 claude login 的工作站）
#   2) 暫不填，部署完用 docker compose exec /login（headless / 想直接在 container 內登入）
#   3) ANTHROPIC_API_KEY（不走訂閱）
prompt_claude_auth() {
    local existing_b64 existing_apikey
    existing_b64=$(get_env_value "$DEFAULTS_FILE" "CLAUDE_CREDENTIALS_B64")
    existing_apikey=$(get_env_value "$DEFAULTS_FILE" "ANTHROPIC_API_KEY")

    # 既有 .env 沿用
    if [ -n "$existing_apikey" ] && confirm "偵測到既有 ANTHROPIC_API_KEY，沿用？" "Y"; then
        V_ANTHROPIC_API_KEY="$existing_apikey"
        CLAUDE_AUTH_MODE="api_key"
        return
    fi
    if [ -n "$existing_b64" ]; then
        info "偵測到既有 CLAUDE_CREDENTIALS_B64（會在 volume 為空時做一次性 seed）"
        if confirm "沿用？" "Y"; then
            V_CLAUDE_CREDENTIALS_B64="$existing_b64"
            CLAUDE_AUTH_MODE="subscription"
            return
        fi
    fi

    info "Claude 認證選項："
    info "  1) 訂閱版：自動偵測 host 既有憑證並 seed（一次性，之後 refresh 由 volume 自管）"
    info "  2) 訂閱版：什麼都不填，部署完跑 docker compose exec ... claude → /login"
    info "  3) API Key（sk-ant-...）"
    local choice
    choice=$(prompt_value "請選擇 [1/2/3]" "2")

    case "$choice" in
        1)
            local cred_file="$HOME/.claude/.credentials.json"
            local found_b64="" found_source=""
            if [ -f "$cred_file" ]; then
                found_b64=$(base64_encode_file "$cred_file")
                found_source="$cred_file"
            elif [ "$(uname)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
                local kc_json
                kc_json=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)
                if [ -n "$kc_json" ] && printf '%s' "$kc_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,dict)' >/dev/null 2>&1; then
                    found_b64=$(printf '%s' "$kc_json" | base64 | tr -d '\n')
                    found_source="macOS Keychain（Claude Code-credentials）"
                fi
            fi
            if [ -n "$found_b64" ]; then
                local preview
                preview=$(printf '%s' "$found_b64" | cut -c1-12)
                info "  偵測來源：${found_source}"
                info "  base64 預覽：${preview}..."
                V_CLAUDE_CREDENTIALS_B64="$found_b64"
                CLAUDE_AUTH_MODE="subscription"
            else
                warn "未偵測到 host 訂閱憑證（${cred_file} 與 macOS Keychain 都沒有）"
                warn "→ 退回選項 2：部署完進 container 跑 /login"
                CLAUDE_AUTH_MODE="deferred"
            fi
            ;;
        3)
            while :; do
                local v
                v=$(prompt_value "ANTHROPIC_API_KEY（sk-ant-...）" "" 1)
                if printf '%s' "$v" | grep -Eq '^sk-ant-'; then
                    V_ANTHROPIC_API_KEY="$v"
                    CLAUDE_AUTH_MODE="api_key"
                    return
                fi
                warn "格式錯誤，需以 sk-ant- 開頭"
            done
            ;;
        *)
            CLAUDE_AUTH_MODE="deferred"
            ;;
    esac
}

# ---------- Phase 4: 寫入 .env ----------

phase4_write_env() {
    header "Phase 4：寫入 .env"

    local tmp
    tmp=$(mktemp /tmp/setup.XXXXXX)

    {
        cat <<'HEADER'
# 由 scripts/setup.sh 產生；可手動編輯後重跑 setup.sh 沿用
HEADER
        printf '\n# ── Claude 認證 ──\n'
        printf 'CLAUDE_CREDENTIALS_B64=%s\n' "$(sh_quote "$V_CLAUDE_CREDENTIALS_B64")"
        printf 'ANTHROPIC_API_KEY=%s\n' "$(sh_quote "$V_ANTHROPIC_API_KEY")"

        printf '\n# ── Git ──\n'
        printf 'GIT_TOKEN=%s\n' "$(sh_quote "$V_GIT_TOKEN")"
        printf 'GIT_USERNAME=%s\n' "$(sh_quote "$V_GIT_USERNAME")"

        printf '\n# ── Lark / Feishu ──\n'
        printf 'FEISHU_APP_ID=%s\n' "$(sh_quote "$V_FEISHU_APP_ID")"
        printf 'FEISHU_APP_SECRET=%s\n' "$(sh_quote "$V_FEISHU_APP_SECRET")"
        printf 'LARK_DOMAIN=%s\n' "$(sh_quote "$V_LARK_DOMAIN")"
        printf 'LARK_MCP_PORT=%s\n' "$(sh_quote "$V_LARK_MCP_PORT")"
        printf 'LARK_MCP_HOST_PORT=%s\n' "$(sh_quote "$V_LARK_MCP_HOST_PORT")"
        printf 'LARK_MCP_TOOLS=%s\n' "$(sh_quote "$V_LARK_MCP_TOOLS")"

        printf '\n# ── 部署 / 命名 ──\n'
        printf 'TARGET_REPO=%s\n' "$(sh_quote "$V_TARGET_REPO")"
        if [ -n "$V_COMPOSE_PROJECT_NAME" ]; then
            printf 'COMPOSE_PROJECT_NAME=%s\n' "$(sh_quote "$V_COMPOSE_PROJECT_NAME")"
        fi

        printf '\n# ── cc-connect ──\n'
        printf 'CC_LANGUAGE=%s\n' "$(sh_quote "$V_CC_LANGUAGE")"
        printf 'CC_PROGRESS_STYLE=%s\n' "$(sh_quote "$V_CC_PROGRESS_STYLE")"
    } > "$tmp"

    mv "$tmp" .env
    chmod 600 .env
    ok "已寫入 .env（chmod 600）"
}

# ---------- Phase 5: Live API 驗證 ----------

phase5_verify_apis() {
    header "Phase 5：Live API 驗證"
    local fail=0

    # 5a. Git repo 可讀（用 git ls-remote，跨 GitHub / GitLab / 自架）
    info "驗證 ${V_TARGET_REPO} 可讀 ..."
    command -v git >/dev/null 2>&1 || die "找不到 git（git ls-remote 驗證需要）"
    local askpass="" git_env=""
    case "$V_TARGET_REPO" in
        https://*|http://*)
            if [ -n "$V_GIT_TOKEN" ]; then
                askpass=$(mktemp /tmp/setup-askpass.XXXXXX)
                cat > "$askpass" <<EOF
#!/bin/sh
case "\$1" in
    *[Uu]sername*) echo "${V_GIT_USERNAME}" ;;
    *[Pp]assword*) echo "${V_GIT_TOKEN}" ;;
esac
EOF
                chmod +x "$askpass"
                git_env="GIT_ASKPASS=$askpass"
            fi
            ;;
        git@*|ssh://*)
            warn "SSH URL：使用 host 上的 ~/.ssh 設定（容器內預設不會有，clone 階段可能失敗）"
            ;;
    esac

    if env GIT_TERMINAL_PROMPT=0 ${git_env:+$git_env} git ls-remote "$V_TARGET_REPO" HEAD >/dev/null 2>/tmp/setup-gitls.err; then
        ok "Git: 可讀取 HEAD"
    else
        err "Git ls-remote 失敗"
        sed -n '1,5p' /tmp/setup-gitls.err 2>/dev/null || true
        case "$V_TARGET_REPO" in
            https://*|http://*)
                if [ -z "$V_GIT_TOKEN" ]; then
                    err "  → 私 repo 必須提供 GIT_TOKEN"
                else
                    err "  → 確認 GIT_TOKEN 有讀此 repo 的權限，並檢查 GIT_USERNAME 是否與 token 平台相符"
                fi
                ;;
            *) err "  → SSH/git:// 路徑請確認 host 端 SSH key 設定，或改用 HTTPS URL" ;;
        esac
        fail=1
    fi
    [ -n "$askpass" ] && rm -f "$askpass"
    rm -f /tmp/setup-gitls.err

    # 5b. Lark tenant_access_token
    info "驗證 FEISHU_APP_ID/SECRET 可換 tenant_access_token ..."
    local lark_body lark_code
    lark_body=$(curl -sS -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"app_id\":\"${V_FEISHU_APP_ID}\",\"app_secret\":\"${V_FEISHU_APP_SECRET}\"}" \
        "${V_LARK_DOMAIN}/open-apis/auth/v3/tenant_access_token/internal" 2>/dev/null || echo '{"code":-1,"msg":"curl failed"}')
    lark_code=$(printf '%s' "$lark_body" | json_get '.code' 2>/dev/null || echo "?")
    if [ "$lark_code" = "0" ]; then
        ok "Lark: tenant_access_token 取得成功"
    else
        local lark_msg
        lark_msg=$(printf '%s' "$lark_body" | json_get '.msg' 2>/dev/null || echo "(無 msg)")
        err "Lark 失敗（code=${lark_code}, msg=${lark_msg}）"
        err "  → 確認 app_id / app_secret，並檢查 LARK_DOMAIN 是否正確（國際 vs 中國）"
        fail=1
    fi

    # 5c. Anthropic / Claude credentials
    if [ "$CLAUDE_AUTH_MODE" = "api_key" ]; then
        info "驗證 ANTHROPIC_API_KEY ..."
        local ak_status
        ak_status=$(curl -sS -o /dev/null -w '%{http_code}' \
            -H "x-api-key: ${V_ANTHROPIC_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            "https://api.anthropic.com/v1/models" || echo "000")
        if [ "$ak_status" = "200" ]; then
            ok "Anthropic API key 有效"
        else
            err "Anthropic API key 失敗（HTTP ${ak_status}）"
            fail=1
        fi
    elif [ "$CLAUDE_AUTH_MODE" = "deferred" ]; then
        info "Claude 訂閱憑證將在容器啟動後手動 /login 寫入 volume，跳過憑證驗證"
    else
        info "驗證 CLAUDE_CREDENTIALS_B64 解碼後是合法 JSON ..."
        local decoded
        if decoded=$(printf '%s' "$V_CLAUDE_CREDENTIALS_B64" | base64_decode); then
            if printf '%s' "$decoded" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict); print("ok")' >/dev/null 2>&1; then
                ok "Claude credentials JSON 解析成功"
            else
                err "Claude credentials 解碼後不是合法 JSON 物件"
                fail=1
            fi
        else
            err "Claude credentials 不是合法 base64"
            fail=1
        fi
    fi

    if [ "$fail" -ne 0 ]; then
        die "驗證失敗，請修正後重跑 setup.sh"
    fi
    ok "所有 API 驗證通過"
}

# ---------- Phase 6: docker compose build ----------

phase6_build() {
    header "Phase 6：docker compose build"
    docker compose build
    ok "build 完成"
}

# ---------- Phase 7: up + healthcheck ----------

phase7_up_and_wait() {
    header "Phase 7：docker compose up + healthcheck"
    docker compose up -d

    local timeout=300   # 5 分鐘
    local elapsed=0
    local interval=5
    local services="hermes lark-mcp"   # 有 healthcheck 的
    info "等待 hermes 與 lark-mcp 變 healthy（最多 ${timeout}s）..."
    while :; do
        local all_healthy=1
        local s
        for s in $services; do
            local h
            h=$(docker compose ps --format '{{.Service}}={{.Health}}' 2>/dev/null \
                | grep "^${s}=" | head -1 | cut -d'=' -f2)
            if [ "$h" != "healthy" ]; then
                all_healthy=0
                break
            fi
        done
        # cc-connect 沒有 healthcheck，只檢查 running
        local cc_state
        cc_state=$(docker compose ps --format '{{.Service}}={{.State}}' 2>/dev/null \
            | grep '^cc-connect=' | head -1 | cut -d'=' -f2)
        if [ "$all_healthy" = "1" ] && [ "$cc_state" = "running" ]; then
            ok "全部就緒"
            break
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            err "等待逾時（${timeout}s）"
            docker compose ps
            warn "印各 service 最後 30 行 log："
            docker compose logs --tail 30 || true
            die "服務未在時限內全部 healthy"
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        printf '%s' "."
    done
    printf '\n'

    docker compose ps
    info "提示：用 'docker compose logs -f cc-connect' 看互動 log"
}

# ---------- main ----------

main() {
    require_tty
    phase1_preflight
    phase2_env_file
    if [ "$ENV_MODE" = "overwrite" ]; then
        phase3_prompts
        phase4_write_env
    else
        info "（沿用既有 .env，跳過互動填值）"
        # 從既有 .env 讀回變數供 Phase 5 驗證使用
        V_GIT_TOKEN=$(get_env_value .env "GIT_TOKEN")
        V_GIT_USERNAME=$(get_env_value .env "GIT_USERNAME")
        [ -z "$V_GIT_USERNAME" ] && V_GIT_USERNAME="oauth2"
        V_FEISHU_APP_ID=$(get_env_value .env "FEISHU_APP_ID")
        V_FEISHU_APP_SECRET=$(get_env_value .env "FEISHU_APP_SECRET")
        V_TARGET_REPO=$(get_env_value .env "TARGET_REPO")
        V_LARK_DOMAIN=$(get_env_value .env "LARK_DOMAIN")
        V_CLAUDE_CREDENTIALS_B64=$(get_env_value .env "CLAUDE_CREDENTIALS_B64")
        V_ANTHROPIC_API_KEY=$(get_env_value .env "ANTHROPIC_API_KEY")
        if [ -n "$V_ANTHROPIC_API_KEY" ]; then
            CLAUDE_AUTH_MODE="api_key"
        elif [ -n "$V_CLAUDE_CREDENTIALS_B64" ]; then
            CLAUDE_AUTH_MODE="subscription"
        else
            # .env 兩個欄位都空：靠 claude-data volume 內已 /login 過的憑證
            CLAUDE_AUTH_MODE="deferred"
        fi
    fi
    phase5_verify_apis
    phase6_build
    phase7_up_and_wait

    header "完成"
    ok "服務已啟動。下一步："

    # deferred 模式：檢查 volume 是否已有憑證（之前可能 /login 過）
    if [ "$CLAUDE_AUTH_MODE" = "deferred" ]; then
        if docker compose exec -T -u node cc-connect test -f /home/node/.claude/.credentials.json 2>/dev/null; then
            printf '  • claude-data volume 已有 /login 憑證，bot 可直接使用\n'
        else
            printf '  • Claude 訂閱憑證尚未登入，先做這步：\n'
            printf '      docker compose exec -it -u node cc-connect claude\n'
            printf '      進 Claude 後輸入 /login，完成後：\n'
            printf '      docker compose restart cc-connect\n'
        fi
    fi

    printf '  • 在 Lark 後台「事件訂閱」設定回呼 / 開啟長連線\n'
    printf '  • docker compose logs -f cc-connect   # 看 bot 上線\n'
    printf '  • 在 Lark 群組 @ bot 測試\n'
}

main "$@"
