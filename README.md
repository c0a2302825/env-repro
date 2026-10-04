# env-repro

このマシン（2026-10-05 時点）のAI開発環境を、**貼り付け1回**で再現するためのリポジトリです。
macOS と Windows の両方に同じ「再現された環境」を作れます。

この環境は「説明されている」のではなく「捕捉されている」— バージョンもコミットも全部 pin してあります。`latest` ではありません。

---

## 貼り付け1回で再現

### macOS (Apple Silicon / Intel 均可)

```bash
curl -fsSL https://raw.githubusercontent.com/c0a2302825/env-repro/main/setup-macos.sh | bash
```

### Windows (PowerShell 5.1+)

```powershell
irm https://raw.githubusercontent.com/c0a2302825/env-repro/main/setup-windows.ps1 | iex
```

スクリプトは**冪等**です。何度実行しても既存ファイルを壊しません。
`~/.zshrc` / PATH を書き換えるため、実行後は**新しいシェルを開き直してください**。

---

## 検証

```bash
# macOS
bash <(curl -fsSL https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.sh)

# Windows
irm https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.ps1 | iex
```

5段階（ツールチェーン → 設定ファイル → Skills → symlink → 実行時状態）を確認します。
終了コード `0` なら完全一致。`WARN` は「意図的に再現していないもの」（ollama 停止中など）。

---

## 再現されるもの

| 層 | 内容 |
|---|---|
| OS | macOS 26.6.2 / Darwin 25.6.0 / Apple M3 arm64 / zsh / ja_JP.UTF-8 |
| ツール | opencode 1.18.29, Claude Code 2.1.233, Node 26.7.0, Miniconda Python 3.13.13, ripgrep 15.2.0, jq 1.7.1, gh 2.100.0, git-lfs 3.7.1, LibreOffice 26.8.0.3, ollama 0.32.13 |
| 設定 | `opencode.jsonc`（temperature: 0 / top_p: 0.2）, `.opencode.json`（Ollama provider）, `package.json`（@opencode-ai/plugin）, `~/.claude/settings.json`, `.skill-lock.json` |
| Skills | 10件（`pdf` `pptx` `find-skills` `pdf-extraction` `smart-ocr` `summarize` `academic-paper` `skill-creator` `awesome-claude-skills` `progress-report`）+ symlink 6本 |
| スライド | `slides/env-repro.pptx` — 環境の説明（この deck の原稿） |

## 再現されないもの（意図的）

- **`~/.local/share/opencode/`** — `opencode.db`（443MB）、`tool-output/`、`snapshot/`。
  ディレクトリだけ作ります。コピーすると履歴が混ざるためです。
- **ollama サーバ** — 導入のみ。captured host でも停止状態（`brew service = none`）だったので、
  起動は user's 判断に委ねています。`brew services start ollama` で起動します。
- **認証情報** — `auth.json` は元から存在しません（環境変数 / CLI 認証で運用）。再現しません。
- **`__pycache__`** — Python が再生成します。

---

## pin の設定について

`manifests/env-manifest.json` が唯一の真実です。

**Skills は upstream の commit SHA で固定**しました。ただし 1 つ例外:

- **`academic-paper`** は `6837b4df` に固定しています。upstream の HEAD (`48deedfe`, 2026-10-03) では
  このファイルが変更されており、ローカルの実物と**一致しません**。63ファイルfolderを
  この commit と突き合わせて完全一致を確認済みです。

**upstream がない Skill は同梱**しました（`manifests/*.SKILL.md`）:

- `awesome-claude-skills` — 由来不明。ローカル配置のみ。
- `progress-report` — ローカル専用 Skill。upstream なし。

`skill-creator` は `SKILL.md` のみを同梱（ローカル実体が1ファイルのため）。
upstream には18ファイルありますが、それらFollow: 依存ファイルは含まれていません。

**検証は `SKILL.md` の SHA-256 先頭16文字**で行います。
`.skill-lock.json` の `skillFolderHash` は逆算できなかったため使わない。

---

## Windows での差分

| | macOS | Windows |
|---|---|---|
| Claude Code | `npm i -g @anthropic-ai/claude-code` | `winget install Anthropic.ClaudeCode`（upstream が npm を deprecated 扱い） |
| opencode | `brew install opencode` | `npm i -g opencode-ai@1.18.29`（`opencode.exe` 同梱） |
| Python PATH | `/opt/miniconda3/bin` | `%USERPROFILE%\miniconda3` |
| symlink | `ln -s` | 開発者モード無効なら `New-Item -Junction` へ自動フォールバック |

`PATH` の順序が重要です: `python3` が miniconda3 を指さないと `pip` も別のツリーを見ます。
スクリプトは先頭に挿入しますが、**反映にはシェルの再起動が必要**です。

---

## ファイル構成

```
manifests/env-manifest.json      pin された真実（バージョン・commit SHA・ハッシュ）
manifests/opencode.jsonc         そのまま使う設定ファイル
manifests/opencode.provider.json
manifests/package.json
manifests/claude-settings.json
manifests/skill-lock.json
manifests/awesome-claude-skills.SKILL.md   upstream なし → 同梱
manifests/progress-report.SKILL.md         upstream なし → 同梱
setup-macos.sh                   macOS 用セットアップ
setup-windows.ps1                Windows 用セットアップ
scripts/verify.sh                macOS 検証
scripts/verify.ps1               Windows 検証
slides/env-repro.pptx            環境説明スライド
```

## 免責

このリポジトリは**読み取り専用の再現スクリプト**です。既存の設定ファイルを上書きすることはありません
（`already exists (not overwritten)` と表示してスキップします）。削除するコマンドはありません。
