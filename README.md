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

## 役割

このパッケージは、次の 2 つを担います。

1. **DevContainer 環境の生成** — devcontainer 設定、補助スクリプト、`.gitignore` の管理セクション
2. **AI 共通ルールの配布**（`--with-playbook`）— 別リポジトリで管理される共通ルールを、生成先へ配置する

2 について、このパッケージは**配布機構であって正本ではありません**。ルールの正本は ai-playbook リポジトリ側にあります。
このパッケージはルールの内容も、入口ファイルの雛形も持ちません。ai-playbook の `templates/` をそのままコピーするだけです。

そのため、AI ルールだけが必要な場合は、このパッケージを介さず ai-playbook を直接導入できます。
このパッケージは devcontainer と対応言語（node / go / python / php / rust）を前提とするため、それ以外の環境では ai-playbook 側の導入手順を使ってください。

## 公開リリースからの利用

公開リポジトリ:
- https://github.com/ojos/devcontainer-bootstrap

最新安定リリース:
- `v0.3.1`

`SHA256SUMS` は `bootstrap.sh` と `doctor.sh` を対象とするため、検証するにはその 2 つを取得します。

```bash
TAG=v0.3.1
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"
curl -sSL "${BASE}/bootstrap.sh" -o bootstrap.sh
curl -sSL "${BASE}/doctor.sh" -o doctor.sh
curl -sSL "${BASE}/SHA256SUMS" -o SHA256SUMS
sha256sum -c SHA256SUMS
bash bootstrap.sh --project-name myapp --languages node,go --mode standard
```

AI 共通ルールも配置する場合は、ルールの取得元を指定します。

```bash
bash bootstrap.sh --project-name myapp --languages node,go --mode standard \
  --with-playbook --playbook-from https://github.com/ojos/ai-playbook/archive/refs/tags/v0.1.1.tar.gz
```

## 入力仕様

### 必須入力
- `--project-name <name>`（文字列。必須）
- `--languages <csv>`（CSV 形式。`node`、`go`、`python`、`php`、`rust` を任意に組み合わせ。必須）
- `--mode <minimal|standard|full>`（テンプレート選択。既定: `standard`）

### オプション入力
- `--output-dir <path>`（省略時: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（自動判定結果を上書きして明示指定）
- `--github-profiles <csv>`（GitHub マルチアカウント用 profile 名。既定: `primary,secondary`）
- `--with-playbook` / `--without-playbook`（AI 共通ルールの配置。既定: 配置しない）
- `--playbook-from <path|url>`（ルールの取得元。ディレクトリまたはアーカイブ URL）
- `--playbook-conflict-policy <skip|overwrite|prompt>`（既存ファイルがある場合の扱い。既定: `skip`）

### AI 共通ルールの配置

`--with-playbook` を指定すると、共通ルールと入口ファイルを生成先へ配置します。**既定では配置しません**（オプトイン）。

配置されるもの:

| 配置先 | 内容 |
|---|---|
| `.ai-playbook/**` | 共通規範、ロール契約、タスクプレイブック、レビュー運用、intake 規律 |
| `.github/project-ai-rules.md` | プロジェクト共通ルールの雛形 |
| `CLAUDE.md` / `.github/copilot-instructions.md` | 実行環境の入口ファイル（3 層の優先順位を配線） |

取得元は次の順で解決します。

1. `--playbook-from` に指定したディレクトリまたはアーカイブ URL
2. 隣接する ai-playbook チェックアウト（`bootstrap.sh` から見て `../../.ai-playbook` または `../../../.ai-playbook`）

`curl` で `bootstrap.sh` を単体取得して実行する場合は隣接チェックアウトが存在しないため、`--playbook-from` の指定が必要です。
取得元が解決できない場合は、**ファイルを 1 つも書き込まずに終了します**。

### モード別 AI CLI 導入挙動

| モード | `scripts/install-ai-tools.sh` 生成 | `postCreateCommand` の挙動 |
|---|---|---|
| `minimal` | あり | `bash scripts/install-ai-tools.sh` を実行 |
| `standard` | あり | `bash scripts/install-ai-tools.sh` を実行 |
| `full` | あり | `bash scripts/install-ai-tools.sh && bash scripts/post-rebuild-check.sh` を実行 |

`install-ai-tools.sh` は対応する認証情報が設定されている場合のみ `claude` / `gemini` を導入します（`CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`）。

## ループコーディング支援

AI エージェントの反復（実装 → 検証 → 修正 → …）を、**機械が緑判定できる決定的な信号**の上で収束させるための実行体を生成します。全モードで生成し、**外部パッケージの導入を前提にせず単体で動作**します。

> この節は DCB 環境での**操作手順**（各スクリプトをどう回すか）を扱います。ループコーディングという**ワークフロー自体の考え方**（従来との違い・収束規律・受け入れ検証の機械ゲート化）は、規範パッケージ ai-playbook の解説ガイド `loop-coding-guide.md`（規範の正本は `loop-workflow.md`）を参照してください。`--with-playbook` を指定すると、これらの規範も生成先へ配置されます。

| スクリプト | 役割 |
|---|---|
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（プロジェクトが所有・編集）。選択言語の慣習的テストコマンドを既定として配置する |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS` / 終了コード 0）を返す接地信号 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。`verify.sh` と、任意の第二意見レビューを直列で通す単一入口（`GATE_PASS` / 終了コード 0） |

- `acceptance.sh` は生成時に選択言語の既定コマンド（`node`→`npm test`、`go`→`go test ./...`、`python`→`python -m pytest`、`php`→`composer test`、`rust`→`cargo test`）を置きます。プロジェクトの実態に合わせて編集してください。受け入れ条件が検証可能であるほど、反復が収束しやすくなります。
- `verify.sh` の受け入れ定義は `VERIFY_ACCEPTANCE` 環境変数で差し替えできます。
- `loop-gate.sh` の第二意見は、`scripts/gemini-review.sh` が存在すれば直列化し、無ければ優雅にスキップします。`LOOP_GATE_REVIEW_CMD` で任意のレビューコマンドへ差し替え、空文字で無効化できます。
- これらは純粋な機構であり、規範（受け入れ検証の機械ゲート化・収束規則・verify ランナー契約）は ai-playbook の `loop-workflow.md` が正本です。`--with-playbook` 併用時は、第二意見の `gemini-review.sh` も配置され、`loop-gate.sh` が自動で直列化します。

```bash
# 反復のたびに接地信号を確認する
bash scripts/verify.sh

# push / PR 前のローカル事前ゲート（受け入れ検証 + 任意の第二意見）
bash scripts/loop-gate.sh
```

## 言語サポート
対応ランタイム（任意の組み合わせ）:
- `node`（Node.js / JavaScript / TypeScript）
- `go`（Go）
- `python`（Python 3）
- `php`（PHP）
- `rust`（Rust）

選択した言語は devcontainer feature（`ghcr.io/devcontainers/features/<lang>:1`）として導入され、`scripts/post-rebuild-check.sh` の検査対象にもなります。`rust` は feature 名（`rust`）と実行コマンド（`cargo`）が異なるため、検査・診断は `cargo` の有無で判定します。

### VS Code language server 拡張

選択言語に応じて language server 拡張を条件付きで配線します（インフラ系拡張とは別に、選択時のみ追加）。

| 言語 | 配線する拡張 |
|---|---|
| `rust` | `rust-lang.rust-analyzer` |
| `go` | `golang.go` |
| `python` | `ms-python.python` |
| `node` | （なし。JS/TS は VS Code 組み込み） |
| `php` | （サードパーティは配線しない。有料ティアのある拡張を既定に含めないため） |

### 使用例:
```bash
# 単一言語（カレントディレクトリ直下に myapp/ を作成して展開）
./bootstrap.sh --project-name myapp --languages node --mode minimal

# 複数言語
./bootstrap.sh --project-name myapp --languages node,go,python,php,rust --mode standard

# Rust 単体
./bootstrap.sh --project-name myapp --languages rust --mode standard

# バックエンドのみ（フロントエンドなし）
./bootstrap.sh --project-name backend-api --languages go,python,php --mode minimal

# 出力先を明示指定したい場合
./bootstrap.sh --project-name myapp --languages node --mode standard --output-dir /path/to/existing-workspace

# .gitignore の managed セクション更新を無効化したい場合
./bootstrap.sh --project-name myapp --languages node --mode minimal --no-gitignore

# 暗黙ターゲット（macOS + 言語対応テンプレート）のみ使う場合
./bootstrap.sh --project-name myapp --languages node,python,php --mode standard

# 追加テンプレートを明示指定したい場合（暗黙ターゲットに追加で合成）
./bootstrap.sh --project-name myapp --languages node --mode standard --gitignore-targets macOS,Node,VisualStudioCode

# GitHub マルチアカウント profile を指定する場合
./bootstrap.sh --project-name myapp --languages node --mode full --github-profiles work,personal

# AI 共通ルールも一緒に配置する場合（隣接する ai-playbook チェックアウトから取得）
./bootstrap.sh --project-name myapp --languages node --mode standard --with-playbook

# ルールの取得元を明示する場合（単体取得して実行する場合はこちらが必要）
./bootstrap.sh --project-name myapp --languages node --mode standard \
  --with-playbook --playbook-from https://github.com/<owner>/ai-playbook/archive/refs/tags/<tag>.tar.gz

# 既存プロジェクトへルールを追加し、既存ファイルは上書きしたい場合
./bootstrap.sh --project-name myapp --languages node --mode standard \
  --output-dir /path/to/existing-workspace --with-playbook --playbook-conflict-policy overwrite
```

生成後の切替例:

```bash
bash scripts/github-account-switch.sh list
bash scripts/github-account-switch.sh use <profile>
```

## Feature フラグ
- `features.docker`（既定値: true）
- `features.ripgrep`（既定値: true）
- `features.githubCli`（既定値: true）
- `features.node`（`languages` に `node` を含む場合）
- `features.go`（`languages` に `go` を含む場合）
- `features.python`（`languages` に `python` を含む場合）
- `features.php`（`languages` に `php` を含む場合）
- `features.awsCli`（`standard` または `full` モードの場合）
- `features.terraform`（`standard` または `full` モードの場合）
- `features.googleCloudSdk`（`full` モードのみ、外部 feature を利用）
- `features.devTools`（既定値: true）

## VS Code 拡張（Remote）
- 生成される `standard` / `full` モードでは、リビルド後の再現性確保のため `github.copilot` と `github.copilot-chat` をインストールします。
- Terraform feature が有効な場合（`standard` / `full`）は `hashicorp.terraform` をインストールします。
- Google Cloud CLI feature が有効な場合（`full`）は `GoogleCloudTools.cloudcode` をインストールします。
- `ms-azuretools.vscode-containers` と `amazonwebservices.aws-toolkit-vscode` は `standard` / `full` の既定拡張として維持されます。

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

## AI エンジン導入マトリックス

このパッケージが生成する環境における、AI CLI の導入・認証要件のマトリックスです。

| エンジン | コマンド | 認証環境変数 | 導入経路 (モード) | 未導入・未認証時の挙動 |
|----------|----------|--------------|-------------------|------------------------|
| Claude | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` | `minimal` / `standard` / `full` で生成される `scripts/install-ai-tools.sh` を `postCreateCommand` で実行 | トークン/認証不足時はログインプロンプト表示またはエラー終了 |
| Gemini | `gemini` | `GEMINI_API_KEY` | `minimal` / `standard` / `full` で生成される `scripts/install-ai-tools.sh` を `postCreateCommand` で実行 | API キー不足または API/認証エラーで失敗 |
| Codex  | `codex` | `OPENAI_API_KEY` | すべてのモードで手動導入のみ（DCB による自動導入なし） | バイナリ未導入または API キー未設定で失敗 |

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python|php）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `--github-profiles` で指定した各 profile に対して `GITHUB_TOKEN_<PROFILE>` などの `remoteEnv` を生成すること
4. ベースイメージは Docker サーバーの `os/arch` から自動判定（既定: `mcr.microsoft.com/devcontainers/base:ubuntu`、必要に応じて `--base-image` で上書き可能）

## 期待される出力
- `.devcontainer/devcontainer.json`（言語別 feature を反映。docker-compose ベースで `compose.yaml` の `app` サービスを参照）
- `.devcontainer/compose.yaml`（単一サービス `app` の compose 定義。compose 利用時は feature や devcontainer.json の mounts が適用されないため、docker socket や AI CLI 用ボリューム（full のみ）を compose 側で明示）
- `scripts/github-account-switch.sh`
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`
- `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh`（ループコーディング支援。下記参照）
- `.gitignore` の managed セクション（言語構成に応じて自動更新）
- README のセットアップ節更新

`--with-playbook` 指定時は、加えて次を出力します。

- `.ai-playbook/**`（AI 共通ルール一式）
- `.github/project-ai-rules.md`
- `CLAUDE.md` / `.github/copilot-instructions.md`

### `.gitignore` と github/gitignore の連携
- managed セクション末尾には常に `github/gitignore` テンプレートを追加します。
- 暗黙ターゲットは `macOS` + `--languages` で指定した言語対応テンプレート（`node`→`Node` / `go`→`Go` / `python`→`Python` / `php`→`PHP`）です。
- `--gitignore-targets <csv>` を指定すると、暗黙ターゲットに追加で合成します（重複は除去）。
- テンプレート取得は `https://github.com/github/gitignore` から行います（`<name>.gitignore` と `Global/<name>.gitignore` を順に探索）。
- 取得できないテンプレート名は警告を出してスキップします（処理は継続）。

> **注意**: `--languages` の値は小文字（`node`, `go`, `python`, `php`）で指定します。一方 `--gitignore-targets` の値は [github/gitignore](https://github.com/github/gitignore) リポジトリのファイル名に合わせた大文字始まり（`Node`, `Go`, `PHP`, `macOS` など）で指定してください。これらは別々の用途を持つため、意図的に表記が異なります。

## Doctor 自己診断
生成後に次を実行して検証します:
```bash
./doctor.sh --target-dir result --strict
```
設定された各言語ランタイムの可用性を動的にチェックします。

