# DevContainer Bootstrap 使い方ガイド

## 概要
`bootstrap.sh` は、新規または既存のワークスペースに DevContainer の基本構成を一括生成するコマンドです。
このガイドでは、次の内容を説明します。

- 何を生成するか（出力物）
- どの引数を指定すればよいか（入力仕様）
- 生成後に何を確認するか（Doctor 自己診断）

まずは最小コマンドで生成し、必要に応じて言語やテンプレートオプションを追加する使い方を推奨します。

本パッケージは、AIコーディング（Copilot / Claude / Gemini など）を前提とした開発運用を想定しています。
そのため、devcontainer 設定や補助スクリプトは「複数アカウント切替」「CLI 認証状態の確認」「再現可能な初期セットアップ」を重視した構成になっています。

## 公開リリースからの利用

公開リポジトリ:
- https://github.com/ojos/devcontainer-bootstrap

最新安定リリース:
- `v0.1.7`

```bash
TAG=v0.1.7
curl -sSL "https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}/bootstrap.sh" -o bootstrap.sh
curl -sSL "https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}/SHA256SUMS" -o SHA256SUMS
sha256sum -c SHA256SUMS
bash bootstrap.sh --project-name myapp --languages node,go --mode standard
```

## 入力仕様

### 必須入力
- `--project-name <name>`（文字列。必須）
- `--languages <csv>`（CSV 形式。`node`、`go`、`python` を任意に組み合わせ。必須）
- `--mode <minimal|standard|full>`（テンプレート選択。既定: `standard`）

### オプション入力
- `--output-dir <path>`（省略時: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（自動判定結果を上書きして明示指定）
- `--github-profiles <csv>`（GitHub マルチアカウント用 profile 名。既定: `primary,secondary`）

## 言語サポート
対応ランタイム（任意の組み合わせ）:
- `node`（Node.js / JavaScript / TypeScript）
- `go`（Go）
- `python`（Python 3）

### 使用例:
```bash
# 単一言語（カレントディレクトリ直下に myapp/ を作成して展開）
./bootstrap.sh --project-name myapp --languages node --mode minimal

# 複数言語
./bootstrap.sh --project-name myapp --languages node,go,python --mode standard

# バックエンドのみ（フロントエンドなし）
./bootstrap.sh --project-name backend-api --languages go,python --mode minimal

# 出力先を明示指定したい場合
./bootstrap.sh --project-name myapp --languages node --mode standard --output-dir /path/to/existing-workspace

# .gitignore の managed セクション更新を無効化したい場合
./bootstrap.sh --project-name myapp --languages node --mode minimal --no-gitignore

# 暗黙ターゲット（macOS + 言語対応テンプレート）のみ使う場合
./bootstrap.sh --project-name myapp --languages node,python --mode standard

# 追加テンプレートを明示指定したい場合（暗黙ターゲットに追加で合成）
./bootstrap.sh --project-name myapp --languages node --mode standard --gitignore-targets macOS,Node,VisualStudioCode

# GitHub マルチアカウント profile を指定する場合
./bootstrap.sh --project-name myapp --languages node --mode full --github-profiles work,personal
```

生成後の切替例:

```bash
bash scripts/github-account-switch.sh list
bash scripts/github-account-switch.sh use ojos
```

## Feature フラグ
- `features.docker`（既定値: true）
- `features.ripgrep`（既定値: true）
- `features.githubCli`（既定値: true）
- `features.node`（`languages` に `node` を含む場合）
- `features.go`（`languages` に `go` を含む場合）
- `features.python`（`languages` に `python` を含む場合）
- `features.awsCli`（`full` モードのみ）
- `features.devTools`（既定値: true）

## シークレット方針
この方針は、トークンや API キーの平文漏えいを防ぎつつ、AIコーディング時の認証切替を安全に行うためのルールです。

- 受け付けるのは環境変数名のみ（秘密値そのものは不可）
  - `GITHUB_TOKEN_<PROFILE>`（例: `GITHUB_TOKEN_WORK`, `GITHUB_TOKEN_PERSONAL`）
    - `<PROFILE>` 切替時に `gh` 認証へ使うトークン値です。
  - `GITHUB_OWNER_<PROFILE>`（任意。トークン発行者と操作対象 owner が異なる場合）
    - `<PROFILE>` 切替時に `github.owner` として扱う owner（個人名/組織名）です。
  - `GIT_AUTHOR_NAME_<PROFILE>`（任意）
    - `<PROFILE>` 切替時に `git config user.name`（コミット author/committer 名）へ設定する文字列です。
  - `GIT_AUTHOR_EMAIL_<PROFILE>`（任意）
    - `<PROFILE>` 切替時に `git config user.email`（コミット author/committer メール）へ設定する文字列です。
  - `CLAUDE_CODE_OAUTH_TOKEN`
    - Claude CLI の認証に使うトークンです。
  - `GEMINI_API_KEY`
    - Gemini CLI の API 認証に使うキーです。
- 生成される devcontainer 設定では `${localEnv:...}` 参照のみを使用する。
- `GH_TOKEN` の常時注入は、マルチアカウント切替を阻害するため推奨しない。

補足:
- `GITHUB_TOKEN_<PROFILE>` は `scripts/github-account-switch.sh` で profile ごとに切替利用する前提です。
- `GITHUB_OWNER_<PROFILE>` は、トークン発行者と操作対象 owner（個人/組織）が異なるときに使います。

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `--github-profiles` で指定した各 profile に対して `GITHUB_TOKEN_<PROFILE>` などの `remoteEnv` を生成すること
4. ベースイメージは Docker サーバーの `os/arch` から自動判定（既定: `mcr.microsoft.com/devcontainers/base:ubuntu`、必要に応じて `--base-image` で上書き可能）

## 期待される出力
- `.devcontainer/devcontainer.json`（言語別 feature を反映）
- `scripts/github-account-switch.sh`
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`
- `.gitignore` の managed セクション（言語構成に応じて自動更新）
- README のセットアップ節更新

### `.gitignore` と github/gitignore の連携
- managed セクション末尾には常に `github/gitignore` テンプレートを追加します。
- 暗黙ターゲットは `macOS` + `--languages` で指定した言語対応テンプレート（`node`→`Node` / `go`→`Go` / `python`→`Python`）です。
- `--gitignore-targets <csv>` を指定すると、暗黙ターゲットに追加で合成します（重複は除去）。
- テンプレート取得は `https://github.com/github/gitignore` から行います（`<name>.gitignore` と `Global/<name>.gitignore` を順に探索）。
- 取得できないテンプレート名は警告を出してスキップします（処理は継続）。

> **注意**: `--languages` の値は小文字（`node`, `go`, `python`）で指定します。一方 `--gitignore-targets` の値は [github/gitignore](https://github.com/github/gitignore) リポジトリのファイル名に合わせた大文字始まり（`Node`, `Go`, `macOS` など）で指定してください。これらは別々の用途を持つため、意図的に表記が異なります。

## Doctor 自己診断
生成後に次を実行して検証します:
```bash
./doctor.sh --target-dir result --strict
```
設定された各言語ランタイムの可用性を動的にチェックします。
