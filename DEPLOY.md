# 部署指南

把 Claude Code + Lark Bot 跑在 Docker 容器內的完整部署流程。
若你已熟悉本專案，跳到「[一鍵安裝](#一鍵安裝)」即可。

---

## 系統需求

| 項目 | 版本 |
|------|------|
| OS | macOS 12+ 或 Linux（Windows 走 WSL2） |
| Docker | 20.10+ |
| Docker Compose | v2（`docker compose` 子命令；不支援舊版 `docker-compose`） |
| 系統內建工具 | `curl`、`base64`、`python3`、`git` |

`scripts/setup.sh` 在 Phase 1 會逐項檢查；缺什麼會直接報錯。

---

## 取得 credentials

部署前先把以下五項準備好。

### 1. Claude（擇一）

**A. Claude 訂閱帳號（推薦）**

Host 上先 `claude login` 完成登入。`scripts/setup.sh` 會依序偵測：

1. `~/.claude/.credentials.json`（Linux / 舊版 Claude Desktop）
2. macOS Keychain 內 `Claude Code-credentials`（macOS Claude Desktop 預設儲存位置）

偵測到後自動 base64 並填入 `CLAUDE_CREDENTIALS_B64`。兩處都沒有則退回 API Key 或手動貼上。

**B. Anthropic API Key**

到 <https://console.anthropic.com/settings/keys> 建立 API key，setup.sh 會問你是否使用此模式。

### 2. Git Personal Access Token（依託管平台）

| 平台 | 取得位置 | scope |
|------|---------|------|
| GitHub | <https://github.com/settings/tokens> | `repo`（私 repo）/ `public_repo`（公 repo） |
| GitLab | Profile → Access Tokens | `read_repository`、需要可寫再加 `write_repository` |
| Gitea / 自架 | 對應後台 Personal Tokens | 讀取 repo 權限 |
| Bitbucket | Personal settings → App passwords | Repository read |

公開 repo 不一定要 token；setup.sh 允許留空。

`GIT_USERNAME` 多數情況使用 `oauth2`（GitHub / GitLab 都吃）。Bitbucket 改用 `x-token-auth`。

### 3. Lark / Feishu 應用

1. 至 Lark 開發者後台
   - 國際版 <https://open.larksuite.com>
   - 中國版 <https://open.feishu.cn>
2. 建立「企業自建應用」
3. 在「應用憑證」取得 `app_id`（形如 `cli_xxxxxxxx`）與 `app_secret`
4. 開啟需要的權限 scope：`im:message`、`im:chat`、`docx:document`、`minutes:minute` 等（依 `LARK_MCP_TOOLS` 中啟用的工具決定）
5. 開啟「事件訂閱」並設定為「長連線（websocket）」模式（cc-connect 即以此模式連入）

---

## 一鍵安裝

```bash
git clone https://github.com/sky-net-tech/claude-lark-bridge-sandbox.git
cd claude-lark-bridge-sandbox
bash scripts/setup.sh
```

腳本會走完七個 phase 直到容器全部 healthy。

### 七個 phase

| # | 階段 | 內容 |
|---|------|------|
| 1 | Pre-flight | 檢查 docker / curl / base64 / python3 / git / daemon |
| 2 | `.env` 處理 | 偵測既有檔，覆蓋／沿用／中止三選一 |
| 3 | 互動填值 | 必填、有預設、opt-in 三類；Claude 憑證自動偵測 |
| 4 | 寫入 `.env` | chmod 600，每個值單引號包覆 |
| 5 | Live API 驗證 | `git ls-remote` + Lark `tenant_access_token` + Anthropic `/v1/models`（API key 模式）或 base64+JSON 解析（訂閱憑證模式） |
| 6 | `docker compose build` | 三個 image（hermes、lark-mcp、cc-connect） |
| 7 | `up -d` + healthcheck 等待 | 5 分鐘 timeout |

任一 phase 失敗會 abort，已寫入的 `.env` 仍保留。

### 變數一覽

| 變數 | 預設 | 必填 | 說明 |
|------|------|------|------|
| `CLAUDE_CREDENTIALS_B64` | — | 與下擇一 | 訂閱憑證 base64 |
| `ANTHROPIC_API_KEY` | — | 與上擇一 | API Key（`sk-ant-...`） |
| `GIT_TOKEN` | — | 私 repo 必填 | Git PAT；公 repo 可留空 |
| `GIT_USERNAME` | `oauth2` |  | HTTPS basic-auth username；只有 `GIT_TOKEN` 非空時才生效 |
| `FEISHU_APP_ID` | — | ✓ | Lark 應用 ID |
| `FEISHU_APP_SECRET` | — | ✓ | Lark 應用 secret |
| `TARGET_REPO` | — | ✓ | 完整 git URL（HTTPS 推薦） |
| `LARK_DOMAIN` | `https://open.larksuite.com` |  | 國際 / 中國域名 |
| `LARK_MCP_PORT` | `3000` |  | 容器內監聽埠 |
| `LARK_MCP_HOST_PORT` | （空） |  | 對外暴露埠（除錯用） |
| `LARK_MCP_TOOLS` | 預設清單 |  | MCP 啟用的工具 |
| `CC_LANGUAGE` | `zh-TW` |  | cc-connect 語系 |
| `CC_PROGRESS_STYLE` | `compact` |  | 進度卡片樣式 |
| `COMPOSE_PROJECT_NAME` | （cwd 名） |  | 容器命名前綴 |

---

## 驗證健康狀態

```bash
docker compose ps
# 應看到 hermes / lark-mcp 為 healthy；cc-connect 為 running

docker compose logs -f cc-connect
# 看 bot 是否成功連到 Feishu websocket
```

進到 Lark 群組 @ 你的 bot 測試訊息。

---

## Troubleshooting

### Phase 1：Pre-flight

| 訊息 | 處理 |
|------|------|
| `找不到 docker` | 安裝 Docker Desktop（macOS）或 Docker Engine（Linux） |
| `docker compose v2 未安裝` | 升級 Docker Desktop；Linux 用 docker-compose-plugin |
| `Docker daemon 未啟動` | 開啟 Docker Desktop，或 `sudo systemctl start docker` |
| `找不到 python3` | macOS 內建（`xcode-select --install`）；Linux `apt install python3` |

### Phase 5：Git 驗證

| 症狀 | 處理 |
|------|------|
| `Git ls-remote 失敗` + `Authentication failed` | `GIT_TOKEN` 過期或無權；至發行平台確認 token / scope |
| `Repository not found` | URL 拼錯；私 repo 沒 `repo` scope；`GIT_USERNAME` 與 token 平台不符 |
| SSH URL 卡住 | 容器預設不掛 `~/.ssh`，請改用 HTTPS URL，或自行 `volumes:` 掛入 SSH key |

### Phase 5：Lark 驗證

Lark 回傳 `code != 0` 時：

| code | 意義 |
|------|------|
| `99991663` | app secret 錯 |
| `99991671` | app id 錯 |
| `1061002` | app 未啟用 |
| 其他 | 對照 <https://open.larksuite.com/document/server-docs/getting-started/api-call-guide/api-error-code> |

確認 `LARK_DOMAIN` 是國際版（`larksuite.com`）還是中國版（`feishu.cn`），與 app 所在地對應。

### Phase 5：Anthropic 驗證（API Key 模式）

| HTTP code | 意義 |
|-----------|------|
| 401 | API key 錯 |
| 403 | account 無此模型權限 |
| 429 | 限流 |

### Phase 7：Healthcheck timeout

```bash
docker compose ps              # 看哪個 service 沒 healthy
docker compose logs --tail 100 hermes
docker compose logs --tail 100 lark-mcp
```

常見原因：
- hermes 第一次啟動會跑 `git clone` + `npm/uv install`，可能超過 60s start_period。等 5 分鐘仍 timeout 就看 log
- lark-mcp 在 Cold Start 會抓 npm 套件，網路慢會延遲

### Claude 憑證過期

訂閱憑證會過期（含 refresh token 失效）。Host 上重跑 `claude login`，再重跑 `bash scripts/setup.sh`，選「覆蓋」更新 `CLAUDE_CREDENTIALS_B64`。

---

## 平台模式切換

「誰來接 Lark websocket」可以是 **cc-connect**（預設）或 **hermes**，**兩者不可並存**
（同一 Lark app 的長連線同時只能一個 client）。

### 兩種模式對照

| 維度 | cc-connect | hermes |
|------|-----------|--------|
| 預設 | ✓ 一鍵安裝後即此模式 | 需手動切 |
| 接 Lark websocket | cc-connect | hermes |
| 每則訊息對應的 agent | spawn `claude` CLI（Claude Code） | hermes 內建 agent |
| Claude 認證 | 訂閱憑證 ✅ 或 API Key ✅ | **僅 API Key** |
| MCP 工具 | Claude Code 從 `/tmp/mcp-config.json` 讀 lark | hermes 從 `~/.hermes/config.yaml` 的 `mcp_servers.lark` 讀 |
| 紅線規則 | `cc-entrypoint.sh` 注入 CLAUDE.md heredoc | hermes 用自家 system prompt 機制（須另行設定） |
| 文件 @ bot 留言回覆 | ❌ | ✅（hermes 訂閱 `drive.notice.comment_add_v1`） |
| 群組 allowlist | 無 | `FEISHU_ALLOWED_USERS` |
| Cron 結果送 Lark | ❌ | ✅（透過 `/set-home` 設定 home channel） |
| Lark domain | 由 `LARK_DOMAIN`（URL）控 | hardcode `FEISHU_DOMAIN=lark`（國際版） |

### 切換指令

```bash
bash scripts/switch-platform.sh status         # 顯示目前狀態
bash scripts/switch-platform.sh cc-connect     # 切到 cc-connect 模式
bash scripts/switch-platform.sh hermes         # 切到 hermes 模式
```

切到 hermes 模式時，腳本會：
1. 檢查 `.env` 有 `ANTHROPIC_API_KEY` 跟 `FEISHU_APP_ID/SECRET`
2. 停掉 `cc-connect` 容器釋放 Lark websocket
3. 用 `docker compose -f docker-compose.yml -f docker-compose.hermes-platform.yml up -d`
   重建 hermes，注入 `FEISHU_*` env 觸發 hermes 內建 Feishu platform

切回 cc-connect 模式時，腳本只用 base compose `up -d` 重建，hermes 會少掉 `FEISHU_*` env，
回到 memory/cron 後援角色。

### hermes 模式限制

- **不支援 Claude 訂閱憑證**：hermes 透過 Anthropic API 直連，無 OAuth flow。`.env` 必須有 `ANTHROPIC_API_KEY`
- **CLAUDE.md 紅線不會生效**：那是 Claude Code-specific 的 heredoc 注入機制；hermes 要靠自己的 prompt 設定加入等價規則
- **首次切過去 hermes 會重建容器**：原本 hermes 的 `~/.hermes/config.yaml` 跟 `.env` 已寫入 named volume `hermes-data`，不會丟。但 hermes-config.yaml 的更新（如新增 `mcp_servers`）只在**首次啟動時**從 `/config/hermes-config.yaml` 複製，已存在則保留。要強制更新請手動清除 volume：`docker compose down && docker volume rm <project>_hermes-data`（注意這也會清掉 hermes 的 memory 紀錄）

### 中國版 Lark（feishu.cn）部署

`docker-compose.hermes-platform.yml` 內 `FEISHU_DOMAIN: lark` 寫死國際版。
中國版部署改成 `FEISHU_DOMAIN: feishu`，並把 `.env` 的 `LARK_DOMAIN` 改成
`https://open.feishu.cn`（cc-connect 路徑也會跟著走中國版）。

---

## 升級

```bash
git pull
bash scripts/setup.sh    # 第二次跑會問「覆蓋 / 沿用 / 中止」，選沿用
```

選「沿用」會跳過 Phase 3，直接重新跑 Phase 5（驗證）+ Phase 6（build）+ Phase 7（up）。
這樣鏡像會 rebuild、容器會重啟，但 `.env` 維持不變。

---

## 解除安裝

```bash
docker compose down -v       # 停止容器並刪除 volumes（會清掉 workspace、claude session 紀錄）
rm -f .env .env.backup.*
```

若只想停止而保留資料：`docker compose down`（不加 `-v`）。

---

## 安全注意

- `.env` 包含全部機密欄位，`scripts/setup.sh` 會自動 chmod 600；不要 commit
- `GIT_TOKEN` 會以 system-wide credential helper 寫入容器內 `/etc/git-credentials`（644），僅供容器內 root + node user 使用；容器外不可見
- `claude-data` named volume 保存所有 Claude session 的 `.jsonl`（含對話與工具呼叫），是稽核來源
- 容器以 `cap_drop: ALL` + `no-new-privileges:true` 跑；Claude 看不到 host

詳細隔離原則見 README「隔離原則」段，以及 `scripts/cc-entrypoint.sh` 內的 REDLINE 安全規則。
