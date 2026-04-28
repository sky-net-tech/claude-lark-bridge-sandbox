# claude-lark-bridge-sandbox

把 Claude Code 跑在 Docker 容器裡，透過 cc-connect 接 Lark Bot，讓使用者用 Lark 訊息驅動 AI 在隔離環境裡讀寫 GitHub repo。

## 架構

```
Lark 使用者
    ↓ 訊息 / 卡片
[cc-connect 容器] ── Feishu WebSocket
    ↓ spawn per session
[Claude Code]
    ↓ MCP HTTP
[lark-mcp 容器]  ──→ Lark Open API（doc / minutes / im / chat）
[hermes 容器]    ──→ memory / cron（目前未啟用 platform）
```

三個容器走 internal bridge network，host 端只透過 docker-compose 啟停，無對外 port mapping。

## 隔離原則

| 項目 | 處理方式 |
|------|---------|
| Host 個人路徑 | 完全不掛載 |
| 容器使用者 | `node` (uid 1000)，非 root |
| Capabilities | `cap_drop: ALL`，只加回 CHOWN/SETUID/SETGID/DAC_OVERRIDE/FOWNER |
| `no-new-privileges` | 啟用 |
| 機密 | 全部走 `.env`，不入 image 也不入 volume |
| 工作目錄 | clone 在 named volume `workspace` 內 |

## 安全紅線

`scripts/cc-entrypoint.sh` 啟動時會把 `/home/node/.claude/CLAUDE.md` 寫成全域規則，禁止 Claude 探測宿主機、容器逃脫、橫向掃描、憑證竊取。詳見 entrypoint 內的 REDLINE heredoc。

## 使用

```bash
# 1. 複製設定範本
cp .env.example .env
# 填入：CLAUDE_CREDENTIALS_B64 / GH_TOKEN / FEISHU_APP_ID / FEISHU_APP_SECRET

# 2. 啟動
docker compose build
docker compose up -d

# 3. 確認三個服務都健康
docker compose ps
```

## 稽核

每個 Claude session 的完整對話與工具呼叫保存在 named volume `claude-data` 的
`/home/node/.claude/projects/<workspace-hash>/<session-id>.jsonl`，每個 session 一個檔。

附 `cc-audit` CLI（未包含在此 repo，host 端工具）可查歷史命令、搜尋關鍵字、dump 證據。

## 目錄結構

```
.
├── docker-compose.yml          # 三個 service 定義 + capability/logging 設定
├── Dockerfile.cc               # cc-connect + Claude Code wrapper
├── Dockerfile.hermes           # hermes（目前未啟用 platform）
├── Dockerfile.lark-mcp         # @larksuiteoapi/lark-mcp HTTP server
├── scripts/
│   ├── cc-entrypoint.sh        # 寫 settings.json / CLAUDE.md / runtime toml
│   └── hermes-entrypoint.sh    # hermes init + clone repo
├── config/
│   └── hermes-config.yaml      # hermes 設定（memory / logging）
└── .env.example                # 機密欄位範本
```

## 注意

- `Dockerfile.hermes` 的 build context 寫死了某台機器上的 hermes-agent 路徑，若要在別處 build 需自行調整 `docker-compose.yml` 的 `build.context`。
- `cc-connect` 用 npm 套件版本（在 `Dockerfile.cc` 內），不需另外複製 binary。
