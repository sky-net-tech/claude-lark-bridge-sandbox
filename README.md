# claude-lark-bridge-sandbox

把 Claude Code 跑在 Docker 容器裡，透過 cc-connect 接 Lark Bot，讓使用者用 Lark 訊息驅動 AI 在隔離環境裡讀寫 Git repo。

## 快速上手

```bash
git clone https://github.com/sky-net-tech/claude-lark-bridge-sandbox.git
cd claude-lark-bridge-sandbox
bash scripts/setup.sh
```

腳本會互動式收集必要設定（Claude 憑證、Git token、Lark app id/secret、目標 repo URL），
跑完 live API 驗證、build、up 與 healthcheck。完整步驟、credentials 取得方式、
troubleshooting 見 **[DEPLOY.md](./DEPLOY.md)**。

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

三個容器走 internal bridge network，host 端只透過 docker-compose 啟停，預設無對外 port mapping。

## 平台模式

兩種互斥模式（同一個 Lark app 的 websocket 同時只能一個 client）：

| 模式 | 誰接 Lark | 執行模型 | 訂閱憑證 | 預設 |
|------|----------|---------|---------|------|
| **cc-connect** | cc-connect 容器 | spawn `claude` CLI（Claude Code） | ✅ | ✓ |
| **hermes** | hermes 容器 | hermes 內建 agent → Anthropic API | ❌（必須 API key） |  |

```bash
bash scripts/switch-platform.sh status         # 查目前模式
bash scripts/switch-platform.sh cc-connect     # 切回 cc-connect
bash scripts/switch-platform.sh hermes         # 切到 hermes（需 ANTHROPIC_API_KEY）
```

詳細差異與限制見 **[DEPLOY.md](./DEPLOY.md#平台模式切換)**。

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

`scripts/cc-entrypoint.sh` 啟動時會把 `/home/node/.claude/CLAUDE.md` 寫成全域規則，
禁止 Claude 探測宿主機、容器逃脫、橫向掃描、憑證竊取。詳見 entrypoint 內的 REDLINE heredoc。

## 稽核

每個 Claude session 的完整對話與工具呼叫保存在 named volume `claude-data` 的
`/home/node/.claude/projects/<workspace-hash>/<session-id>.jsonl`，每個 session 一個檔。

附 `cc-audit` CLI（未包含在此 repo，host 端工具）可查歷史命令、搜尋關鍵字、dump 證據。

## 目錄結構

```
.
├── docker-compose.yml          # 三個 service 定義 + capability/logging 設定
├── Dockerfile.cc               # cc-connect + Claude Code wrapper
├── Dockerfile.hermes           # hermes（multi-stage：clone hermes-agent → build）
├── Dockerfile.lark-mcp         # @larksuiteoapi/lark-mcp HTTP server
├── docker-compose.hermes-platform.yml  # hermes 模式 override（switch-platform.sh 用）
├── scripts/
│   ├── setup.sh                # 一鍵互動安裝（七 phase）
│   ├── switch-platform.sh      # cc-connect ↔ hermes 平台切換
│   ├── cc-entrypoint.sh        # 寫 settings.json / CLAUDE.md / runtime toml
│   ├── hermes-entrypoint.sh    # hermes init + git clone TARGET_REPO
│   └── lark-mcp-entrypoint.sh  # 由 env 注入 lark-mcp CLI 旗標
├── config/
│   └── hermes-config.yaml      # hermes 設定（cwd 由 entrypoint 替換）
├── .env.example                # 設定範本（setup.sh 會以此為起點）
├── CLAUDE.md                   # 專案紅線（跨平台、設定單一來源、安全）
├── DEPLOY.md                   # 完整部署文件
└── README.md                   # 本檔
```
