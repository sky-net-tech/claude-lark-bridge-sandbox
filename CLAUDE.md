# 專案紅線（強制執行）

## 跨平台語法相容性

本專案的維運者橫跨 macOS（host 開發機）與 Linux（容器內 / 部署機）。
**所有 shell script、`.env.example` 範例指令、README 內的範例片段**都必須在
兩邊都能直接跑，不得只能在某一邊運作。

### 已知雷區

| 行為 | macOS (BSD) | Linux (GNU) | 共用寫法 |
|------|-------------|-------------|---------|
| `sed -i` | 必須帶副檔名：`sed -i '' …` | 不可帶空字串 | `sed -i.bak …` 後 `rm *.bak`，或 `sed … > tmp && mv tmp file` |
| `base64` 編碼檔案 | `base64 -i file` | `-i` 變成 ignore-garbage | `base64 < file` 或 `base64 file`（兩邊都吃 positional） |
| `base64` 解碼 | `base64 -D` 或 `-d` | 只認 `-d` | 一律用 `-d` |
| `readlink -f` | macOS < 12.3 沒有 | 有 | 容器內 OK；host 端避免，改 `python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' …` |
| `date -d "yesterday"` | BSD 不支援 `-d`，要 `date -v-1d` | GNU 才支援 `-d` | 容器內固定走 GNU；host 範例需註明 |
| `xargs -d '\n'` / `-r` | BSD 沒有 | GNU 才有 | 改 `xargs -I{}` 或 `tr '\n' '\0' \| xargs -0` |
| `grep -P`（PCRE） | BSD 沒有 | GNU 才有 | 改 `grep -E`（POSIX ERE） |
| `find -regextype` | BSD 沒有 | GNU 才有 | 改 `find … -name` 或 `find … \| grep -E` |
| `mktemp` | BSD 要 template 結尾 `XXXXXX` | GNU 不需要也 OK | 永遠加 `XXXXXX`：`mktemp /tmp/foo.XXXXXX` |
| `stat -c '%U'` / `-f '%Su'` | BSD 用 `-f` | GNU 用 `-c` | 用 `ls -ld file \| awk '{print $3}'` 取代 |

### 撰寫原則

1. **能用 POSIX 就用 POSIX**：`#!/bin/sh`（或 `#!/usr/bin/env bash` 若真要 bashism），
   只用 POSIX 規定的旗標，不依賴 GNU 擴充。
2. **容器內 script** 雖然執行環境只有 Linux，仍盡量保持可攜，方便 host 上 dry-run / debug。
3. **README 與 `.env.example` 的範例指令**永遠示範共用寫法，不要只給 BSD 或只給 GNU。
4. 必須使用 GNU-only 工具時，在 script 開頭明確註明（例：`# 本檔僅在 Linux 容器內執行`），
   避免被誤搬到 macOS host 端。

## 設定單一來源

- 工作目錄前綴（`PROJECT_SLUG`）**一律**由 `TARGET_REPO` 取最後一段（去 `.git`）推導，
  不要在 `.env`、`docker-compose.yml`、script 預設值等任何地方獨立宣告 PROJECT_SLUG，
  否則會出現「同一個變數兩個真相來源」。推導寫法（POSIX，含 trailing slash 處理）：
  ```sh
  _target_trim="${TARGET_REPO%/}"
  _repo_basename="${_target_trim##*/}"
  PROJECT_SLUG="${_repo_basename%.git}"
  ```
  上式對 `https://host/path/repo[.git]`、`git@host:path/repo.git`、`ssh://git@host/path/repo.git`
  三種 URL 形式都會推出相同 `repo`。
- 容器之間用 compose service 名稱做 DNS（例：`http://lark-mcp:${LARK_MCP_PORT}/mcp`），
  不要寫死「project_slug-service」這種前綴（container_name 已不再客製），也不要寫死埠（用 env）。

## 安裝腳本相容性

`scripts/setup.sh` 必須在 macOS 與 Linux 兩邊都能跑，遵循「跨平台語法相容性」一節
所有規則。新增驗證或互動步驟時：

- 不引入新依賴（`jq`、`yq` 等）；JSON 解析改用 `python3` 或 `grep`/`sed`
- 互動 prompt 必須在無 TTY（pipe / CI）情況下不卡住，遇到無 stdin 應以非零碼退出並印明確訊息
- bash 寫法限定 bash 3.2 相容（macOS 內建版本），不用 associative array、`mapfile`、`${var,,}`、`readarray`
- 任何祕密欄位的輸入用 `read -s`，輸出時不可回顯

## 安全紅線

- 機密欄位（`*_API_KEY`、`*_SECRET`、`CLAUDE_CREDENTIALS_B64`、`GIT_TOKEN`）一律走 `.env`，
  不可寫入 image、不可入 named volume、不可在 log 印出。
- `scripts/cc-entrypoint.sh` 內的 REDLINE heredoc 是 Claude session 的全域規則，**不得放寬**。
  若要新增規則，加進去；要刪除既有規則，需在 PR 說明風險評估。
