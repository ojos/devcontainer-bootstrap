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
- `v0.6.0`

`SHA256SUMS` は `bootstrap.sh` と `doctor.sh` を対象とするため、検証するにはその 2 つを取得します。

```bash
TAG=v0.6.0
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"
curl -sSL "${BASE}/bootstrap.sh" -o bootstrap.sh
curl -sSL "${BASE}/doctor.sh" -o doctor.sh
curl -sSL "${BASE}/SHA256SUMS" -o SHA256SUMS
sha256sum -c SHA256SUMS
bash bootstrap.sh --project-name myapp --languages node,go --with-aws --with-claude
```

AI 共通ルールも配置する場合は、ルールの取得元を指定します。

```bash
bash bootstrap.sh --project-name myapp --languages node,go --with-claude \
  --playbook-version v0.1.3
```

`--playbook-version` は既定ソース `ojos/ai-playbook` のタグ tarball への糖衣で、長い archive URL を打たずに済みます。ソースを指定した時点で配置されるため `--with-playbook` は不要です。別 owner・任意の URL・ローカルディレクトリから取得する場合は、従来どおり `--playbook-from` を使います（`--playbook-version` とは排他）。

> **破壊的変更（`--mode` 廃止）**: 従来の `--mode <minimal|standard|full>` は廃止しました。装備は
> `--with-*` フラグで明示選択します。移行対応表は [mode オプションからの移行](#mode-オプションからの移行) を参照してください。

## 入力仕様

### 必須入力
- `--project-name <name>`（文字列。必須）
- `--languages <csv>`（CSV 形式。`node`、`go`、`python`、`php`、`rust` を任意に組み合わせ。必須）

### 装備オプション（`--with-*`）

装備は `--mode` ではなく `--with-*` フラグで明示選択します（オプトイン）。未指定なら素の環境（docker + 選択言語のみ）を生成します。docker のリッチさ（buildx / compose-switch）は全生成物で標準装備です。

| フラグ | 導入する装備 |
|---|---|
| `--with-aws` | AWS CLI feature + `amazonwebservices.aws-toolkit-vscode` 拡張 + Terraform（下記） |
| `--with-gcp` | Google Cloud CLI feature（外部 `dhoeric`）+ `GoogleCloudTools.cloudcode` 拡張 + Terraform（下記） |
| `--with-claude` | Claude Code CLI（`@anthropic-ai/claude-code`）+ `anthropic.claude-code` 拡張 + `~/.claude` 永続化 |
| `--with-gemini` | Gemini CLI（`@google/gemini-cli`）+ `Google.gemini-cli-vscode-ide-companion` 拡張 + `~/.gemini` 永続化 |
| `--with-copilot` | GitHub Copilot CLI（`@github/copilot`）+ `github.copilot` / `github.copilot-chat` 拡張 + `~/.copilot` 永続化 |

- **Terraform は cloud 随伴**: `--with-aws` または `--with-gcp` のいずれかを指定すると、Terraform feature + `hashicorp.terraform` 拡張が **1 回だけ** 同梱されます（両指定でも 1 回、cloud 無指定なら入りません）。
- **AI ツールは明示 opt-in のみ**: `--with-<ai>` を指定したときだけ、CLI 導入・VS Code 拡張・設定ディレクトリの永続化（compose named volume）を行います。トークン有無による自動導入は行いません。認証トークンは従来どおり `remoteEnv` で受け渡します。

### オプション入力
- `--output-dir <path>`（省略時: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（自動判定結果を上書きして明示指定）
- `--github-profiles <csv>`（GitHub マルチアカウント用 profile 名。既定: `primary,secondary`）
- `--with-playbook` / `--without-playbook`（AI 共通ルールの配置。既定: 配置しない）
- `--playbook-version <tag>`（既定ソース `ojos/ai-playbook` のタグ tarball への糖衣。`--playbook-from` とは排他。`<tag>` は GitHub の実タグ名をそのまま指定します。例: `v0.1.3`（先頭の `v` を含む）。存在しないタグを指定すると、**ファイルを 1 つも書かずに**明示エラーで終了します）
- `--playbook-from <path|url>`（ルールの取得元。ディレクトリまたはアーカイブ URL。別 owner・任意 URL・ローカル用）
- `--playbook-conflict-policy <skip|overwrite|prompt>`（既存ファイルがある場合の扱い。既定: `skip`）

### AI 共通ルールの配置

共通ルールと入口ファイルを生成先へ配置します。**既定では配置しません**（オプトイン）。次のいずれかで配置を有効化します。

- `--playbook-version <tag>` または `--playbook-from <path|url>` で**ソースを指定する**（指定した時点で配置意図が明確なため、`--with-playbook` は不要）
- `--with-playbook`（ソースを指定せず、**隣接する ai-playbook チェックアウト**から入れたい場合の明示スイッチ）

`--without-playbook` を指定すると、ソース指定があっても配置しません（明示オプトアウトが最優先）。

配置されるもの:

| 配置先 | 内容 |
|---|---|
| `.ai-playbook/**` | 共通規範、ロール契約、タスクプレイブック、レビュー運用、intake 規律 |
| `.github/project-ai-rules.md` | プロジェクト共通ルールの雛形 |
| `CLAUDE.md` / `.github/copilot-instructions.md` | 実行環境の入口ファイル（3 層の優先順位を配線） |
| `.claude/skills/intake/SKILL.md` | Claude Code 向け intake 起点スキル（`--with-claude` 指定時のみ）。規範を複製せず `.ai-playbook/intake/` を参照するだけの薄いスキル |

取得元は次の順で解決します。

1. `--playbook-version <tag>`（既定ソース `ojos/ai-playbook` のタグ tarball へ展開）
2. `--playbook-from` に指定したディレクトリまたはアーカイブ URL
3. 隣接する ai-playbook チェックアウト（`bootstrap.sh` から見て `../../.ai-playbook` または `../../../.ai-playbook`）

`curl` で `bootstrap.sh` を単体取得して実行する場合は隣接チェックアウトが存在しないため、`--playbook-version` または `--playbook-from` の指定が必要です。
取得元が解決できない場合は、**ファイルを 1 つも書き込まずに終了します**。

### AI CLI 導入挙動

`scripts/install-ai-tools.sh` は常に生成され、`postCreateCommand`（`bash scripts/install-ai-tools.sh`）で実行されます。

導入するのは `--with-claude` / `--with-gemini` / `--with-copilot` で**明示選択した AI CLI のみ**です。トークン有無での自動導入は行いません（明示 opt-in）。何も選択しなければ AI CLI は導入されません。

## ループコーディング支援

AI エージェントの反復（実装 → 検証 → 修正 → …）を、**機械が緑判定できる決定的な信号**の上で収束させるための実行体を生成します。装備の選択によらず常に生成し、**外部パッケージの導入を前提にせず単体で動作**します。

> この節は DCB 環境での**操作手順**（各スクリプトをどう回すか）を扱います。ループコーディングという**ワークフロー自体の考え方**（従来との違い・収束規律・受け入れ検証の機械ゲート化）は、規範パッケージ ai-playbook の解説ガイド `loop-coding-guide.md`（規範の正本は `loop-workflow.md`）を参照してください。規範を配置する（`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれか）と、これらの規範も生成先へ配置されます。

| スクリプト | 役割 |
|---|---|
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（プロジェクトが所有・編集）。選択言語のうち、ルート直下にマニフェストが存在する対象だけを慣習的テストで検証する |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS` / 終了コード 0）を返す接地信号 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。`verify.sh` と、任意の第二意見レビューを直列で通す単一入口（`GATE_PASS` / 終了コード 0） |

- `acceptance.sh` は生成時、選択言語ごとに**ルート直下のマニフェストの実在を確認してから**慣習的コマンド（`node`/`package.json`→`npm test`、`go`/`go.mod`→`go test ./...`、`python`/`pyproject.toml`・`requirements.txt`→`python -m pytest`、`php`/`composer.json`→`composer test`、`rust`/`Cargo.toml`→`cargo test`）を実行します。マニフェストが無い言語は理由を出して**スキップ**し（失敗させない）、マニフェストはあるがツールが無い場合は導入手順を添えて**失敗**させます（スキップと混同しない）。1 つも検証を実行できなければ「受け入れ条件が未定義」として**非 0 で終了**します（全スキップで誤って緑になる事故を防ぐ）。スクリプト位置からルートを解決するため、起動時の作業ディレクトリに依存しません。プロジェクトの実態に合わせて編集してください。受け入れ条件が検証可能であるほど、反復が収束しやすくなります。
  - monorepo など、各言語がルート直下ではなくサブディレクトリ（例 `apps/*`）に配置される構成では、生成直後は対象が見つからず「未定義」で失敗します。これは**意図した既定**であり、実配置のマニフェストを見るよう `acceptance.sh` を編集して受け入れ条件を確定させてください。
- `verify.sh` の受け入れ定義は `VERIFY_ACCEPTANCE` 環境変数で差し替えできます。
- `loop-gate.sh` の第二意見は、`scripts/gemini-review.sh` が存在すれば直列化し、無ければ優雅にスキップします。`LOOP_GATE_REVIEW_CMD` で任意のレビューコマンドへ差し替え、空文字で無効化できます。
- これらは純粋な機構であり、規範（受け入れ検証の機械ゲート化・収束規則・verify ランナー契約）は ai-playbook の `loop-workflow.md` が正本です。規範を配置した場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、第二意見の `gemini-review.sh` も配置され、`loop-gate.sh` が自動で直列化します。

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
# 素の環境（cloud も AI ツールも無し。docker + node のみ）
./bootstrap.sh --project-name myapp --languages node

# 複数言語
./bootstrap.sh --project-name myapp --languages node,go,python,php,rust

# GCP だけ（Terraform 同梱）＋ Claude
./bootstrap.sh --project-name myapp --languages go --with-gcp --with-claude

# AWS + GCP（Terraform は 1 回）＋ Copilot
./bootstrap.sh --project-name myapp --languages node,go --with-aws --with-gcp --with-copilot

# バックエンドのみ（フロントエンドなし）
./bootstrap.sh --project-name backend-api --languages go,python,php

# 出力先を明示指定したい場合
./bootstrap.sh --project-name myapp --languages node --output-dir /path/to/existing-workspace

# .gitignore の managed セクション更新を無効化したい場合
./bootstrap.sh --project-name myapp --languages node --no-gitignore

# 追加テンプレートを明示指定したい場合（暗黙ターゲットに追加で合成）
./bootstrap.sh --project-name myapp --languages node --gitignore-targets macOS,Node,VisualStudioCode

# GitHub マルチアカウント profile を指定する場合
./bootstrap.sh --project-name myapp --languages node --github-profiles work,personal

# AI 共通ルールも一緒に配置する場合（隣接する ai-playbook チェックアウトから取得）
./bootstrap.sh --project-name myapp --languages node --with-playbook

# ルールの版を指定する場合（単体取得して実行する場合はこちらが必要。既定ソース ojos/ai-playbook）
# ソース指定があれば --with-playbook は不要
./bootstrap.sh --project-name myapp --languages node --playbook-version <tag>

# 別 owner・任意 URL・ローカルから取得する場合（--playbook-version とは排他）
./bootstrap.sh --project-name myapp --languages node \
  --playbook-from https://github.com/<owner>/ai-playbook/archive/refs/tags/<tag>.tar.gz

# 既存プロジェクトへルールを追加し、既存ファイルは上書きしたい場合
./bootstrap.sh --project-name myapp --languages node \
  --output-dir /path/to/existing-workspace --with-playbook --playbook-conflict-policy overwrite
```

生成後の切替例:

```bash
bash scripts/github-account-switch.sh list
bash scripts/github-account-switch.sh use <profile>
```

## Feature フラグ

常に導入する feature（既定）:
- `common-utils` / `docker-outside-of-docker`（buildx + compose-switch を標準装備）/ `ripgrep` / `tmux` / `github-cli`

条件付き feature:
- `node` / `go` / `python` / `php` / `rust`（`--languages` に含む場合）
- `aws-cli`（`--with-aws` の場合）
- `google-cloud-cli`（`--with-gcp` の場合、外部 `dhoeric` feature を利用）
- `terraform`（`--with-aws` または `--with-gcp` の場合、1 回）

## VS Code 拡張（Remote）
- `ms-azuretools.vscode-containers` は常に配線します。
- 言語 language server 拡張は選択言語に応じて配線します（上記「言語サポート」参照）。
- `--with-aws`: `amazonwebservices.aws-toolkit-vscode`。`--with-gcp`: `GoogleCloudTools.cloudcode`。いずれかの cloud 指定で `hashicorp.terraform`。
- `--with-claude`: `anthropic.claude-code`。`--with-gemini`: `Google.gemini-cli-vscode-ide-companion`。`--with-copilot`: `github.copilot` / `github.copilot-chat`。

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
  - `CLAUDE_CODE_OAUTH_TOKEN`（任意・既定では注入しません）
    - Claude Code は既定では `/login` で認証します（OAuth トークンは権限スコープが限定されるため）。CI 等でトークン注入が必要な場合のみ、下記「Claude の認証」の手順で手動配線します。
  - `GEMINI_API_KEY`
    - Gemini CLI の API 認証に使うキーです。
- 生成される devcontainer 設定では `${localEnv:...}` 参照のみを使用する。
- `GH_TOKEN` の常時注入は、マルチアカウント切替を阻害するため推奨しない。

補足:
- `GITHUB_TOKEN_<PROFILE>` は `scripts/github-account-switch.sh` で profile ごとに切替利用する前提です。
- `GITHUB_OWNER_<PROFILE>` は、トークン発行者と操作対象 owner（個人/組織）が異なるときに使います。

### プロジェクト `.env` の優先読み込み

`remoteEnv` はホスト OS の環境変数（`GEMINI_API_KEY` / `GITHUB_TOKEN_<PROFILE>` 等）をコンテナへ注入します。プロジェクトごとに別のキーを使いたい場合に備え、`scripts/load-project-env.sh` がプロジェクトルートの `.env` を**ホスト由来の値より後勝ちで上書き**します。

- **`source` しません。** `KEY=VALUE` のみを安全にパースして `export` するため、`.env` の内容は任意コードとして実行されません（`FOO=$(...)` や単独の `echo` 行があっても実行されない）。壊れた `.env` がシェルの初期化ごと落とす事故を防ぎます。
- **CWD 非依存。** スクリプト自身の位置（`scripts/` の 1 階層上）から `.env` を解決するため、サブディレクトリから呼んでも正しく読み込みます。`PROJECT_ENV_FILE` で対象ファイルを明示指定できます。
- **bash / zsh 双方**で動作し、CRLF・`export KEY=VALUE`・`KEY = VALUE`・クォート囲みの各形式を吸収します。複数回読み込んでも安全（冪等）。`.env` が無ければ何もしません。
- 対話シェルへは `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へマーカー付きで**冪等に**注入するため、ターミナルから起動する CLI（`gemini` 等）にも `.env` の値が効きます。非対話実行（`scripts/gemini-review.sh` 等）は各スクリプトが冒頭で明示的に読み込みます。

## Git identity ガード

`github-account-switch.sh` で identity を切り替えても、**local 設定を持たないリポジトリは git が黙って global へフォールバックしてコミットを通す**ため、切替前や新規リポジトリで別アカウント名義のコミットが `main` に混入する事故が起き得ます。この穴を、適用・検証・CI の 3 層で塞ぎます。

- `scripts/setup-git-identity.sh`（適用。`scripts/on-attach.sh` が毎接続で再適用）
  - global の `user.name` / `user.email` を削除し、`user.useConfigOnly=true` を立てます。これにより **local 設定を持たないリポジトリでは `git commit` が exit 128 で停止**します（黙って別名義になるより止まって気づく）。
  - 当リポジトリの local へ、先頭 profile（`--github-profiles` の 1 つ目。既定 `primary`）の `GIT_AUTHOR_NAME_<PROFILE>` / `GIT_AUTHOR_EMAIL_<PROFILE>` を適用します。未設定なら local 適用はスキップし WARN に留めます。
  - 冪等です（2 回実行しても git config は不変）。`bash scripts/setup-git-identity.sh --check` で状態を検証できます。`github-account-switch.sh` が設定する `credential.helper` は壊しません。認証切替は引き続き `github-account-switch.sh` の役割で、このスクリプトは identity の git config 設定だけに閉じます（`gh` を呼ばずオフラインでも動く）。
  - `on-attach.sh` からの呼び出しは、失敗しても **on-attach 全体を落としません**（WARN と `--check` の案内に留める）。
- `scripts/verify-commit-identity.sh`（検証。CI と手元で共用）
  - コミット履歴の author / committer / Co-Authored-By を **email のみ**で判定します（name は表記揺れで判定に使わない）。許可外の author email を含む範囲で exit 1。
  - 許可する author email は、環境変数 `ALLOWED_AUTHOR_EMAILS`（カンマ/空白区切り）を最優先し、無ければ先頭 profile の `GIT_AUTHOR_EMAIL_<PROFILE>` にフォールバックします。どちらでも解決できなければ fail-closed（exit 1）で止まります。
  - committer には `noreply@github.com`（GitHub の squash merge / web UI）、Co-Authored-By には加えて `noreply@anthropic.com`（AI コーディング規約の trailer）を許可します。
  - 使い方: 既定は `origin/main..HEAD`、範囲指定可、`--full` で HEAD の全履歴（`git rev-list --all` にはしない）。
- `.github/workflows/identity-guard.yml`（CI）
  - `pull_request`（PR の全コミット）と `push`（`main` の全履歴）の 2 系統で `verify-commit-identity.sh` を呼びます。直接 push こそが混入の原因なので `push(main)` を省略しません。判定はスクリプト側にあり、ワークフローは呼ぶだけです。

### 利用側の設定手順（許可 author email）

CI に固有の email を焼き込まないため、**利用側リポジトリでリポジトリ変数を設定します**。

1. GitHub リポジトリの **Settings → Secrets and variables → Actions → Variables** を開く。
2. `ALLOWED_AUTHOR_EMAILS` という **Repository variable** を作成し、許可する author email を設定する（複数はカンマまたは空白区切り。例: `you@example.com`）。

未設定のまま CI が走ると、`verify-commit-identity.sh` は許可 email を解決できず fail-closed で失敗します（検査を素通りさせないため）。コンテナ内・手元では `GIT_AUTHOR_EMAIL_<先頭 profile>`（`remoteEnv` 経由）が自動でフォールバックとして使われるため、通常は追加設定なしで `bash scripts/verify-commit-identity.sh` を実行できます。

## AI エンジン導入マトリックス

このパッケージが生成する環境における、AI CLI の導入・認証要件のマトリックスです。

| エンジン | コマンド | 認証環境変数 | 導入経路 | 未導入・未認証時の挙動 |
|----------|----------|--------------|-------------------|------------------------|
| Claude | `claude` | `/login`（既定。トークン注入は任意） | `--with-claude` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時は `/login` プロンプト表示（トークン運用は下記「Claude の認証」参照） |
| Gemini | `gemini` | `GEMINI_API_KEY` | `--with-gemini` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | API キー不足または API/認証エラーで失敗 |
| Copilot | `copilot` | GitHub 認証（`gh` / OAuth） | `--with-copilot` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時はログインプロンプト表示またはエラー終了 |
| Codex  | `codex` | `OPENAI_API_KEY` | 未対応（`--with-codex` は将来対応予定。現状は手動導入のみ） | バイナリ未導入または API キー未設定で失敗 |

各 AI ツールを `--with-<ai>` で選ぶと、CLI に加えて対応 VS Code 拡張が入り、設定ディレクトリ（`~/.claude` / `~/.gemini` / `~/.copilot`）が compose の named volume でリビルド間に保持されます。

### Claude の認証（`/login` 既定・トークン注入は任意）

`--with-claude` では **`CLAUDE_CODE_OAUTH_TOKEN` を `remoteEnv` に注入しません**。OAuth トークンは権限スコープが限定され、フルスペックの操作が許可されないためです。代わりにコンテナ内で作業前に `/login` して認証します。`~/.claude` は named volume で永続するため、一度 `/login` すればリビルドをまたいで有効です。

CI など非対話環境でトークン運用が必要な場合のみ、生成された `.devcontainer/devcontainer.json` の `remoteEnv` に次の行を手動で追加してください（ローカル環境変数 `CLAUDE_CODE_OAUTH_TOKEN` を参照します。別名を使う場合は右辺を差し替え）。

```jsonc
"remoteEnv": {
  // ...既存のエントリ...
  "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
}
```

トークンが `remoteEnv` に存在すると Claude Code はそれを優先して使うため、`/login` のフルスペック認証へ戻す場合はこの行を削除します。

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python|php）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `--github-profiles` で指定した各 profile に対して `GITHUB_TOKEN_<PROFILE>` などの `remoteEnv` を生成すること
4. ベースイメージは Docker サーバーの `os/arch` から自動判定（既定: `mcr.microsoft.com/devcontainers/base:ubuntu`、必要に応じて `--base-image` で上書き可能）

## 期待される出力
- `.devcontainer/devcontainer.json`（言語別 feature を反映。docker-compose ベースで `compose.yaml` の `app` サービスを参照）
- `.devcontainer/compose.yaml`（単一サービス `app` の compose 定義。compose 利用時は feature や devcontainer.json の mounts が適用されないため、docker socket を常に明示。AI CLI 用の永続 volume は `--with-<ai>` 選択時に随伴して compose 側へ配置）
- `scripts/github-account-switch.sh`
- `scripts/load-project-env.sh`（プロジェクト `.env` の優先読み込み。下記参照）
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`
- `scripts/setup-git-identity.sh` / `scripts/verify-commit-identity.sh`（git identity ガード。下記参照）
- `.github/workflows/identity-guard.yml`（コミット identity の検証 CI。下記参照）
- `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh`（ループコーディング支援。下記参照）
- `.gitignore` の managed セクション（言語構成に応じて自動更新）
- README のセットアップ節更新

規範を配置する場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、加えて次を出力します。

- `.ai-playbook/**`（AI 共通ルール一式）
- `.github/project-ai-rules.md`
- `CLAUDE.md` / `.github/copilot-instructions.md`
- `.github/workflows/copilot-review.yml`（`--with-copilot` も併せて選択した場合のみ。下記参照）
- `.claude/skills/intake/SKILL.md`（`--with-claude` を併せて指定した場合のみ。intake 起点スキル）

#### リモート最終ゲート（Copilot）ワークフロー
規範を配置し、かつ `--with-copilot` を選択した場合のみ `.github/workflows/copilot-review.yml` を配置します。これは PR 作成時（`pull_request: types: [opened]`）に一度だけ Copilot へコードレビューを要求するワークフローで、`synchronize`（push 更新）では再要求しないため「1 回だけ」を機構で保証します（規範 `.ai-playbook/review-workflow.md`「リモート最終ゲート」に対応）。フォークからの PR はスキップします。既定の `GITHUB_TOKEN` で要求できない構成では、リポジトリ Secrets に `COPILOT_REVIEW_TOKEN`（`pull-requests` 書き込み権限を持つ PAT）を設定すると自動で切り替わります。

> **前提**: リポジトリ所有者の Copilot サブスクリプションで「Copilot code review」が有効でないと、reviewers 要求が 422 で失敗します。`--with-copilot` を指定しなければ、このワークフローは配置されません（他ベンダーのリモートレビューを使う場合は強制されません）。

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
設定された各言語ランタイムの可用性を動的にチェックします。`--with-aws` / `--with-gcp` で cloud CLI（`aws` / `gcloud` / `terraform`）を配線した場合は、それらの可用性も検査します。

## mode オプションからの移行

`--mode <minimal|standard|full>` は廃止しました（破壊的変更）。mode が束ねていた装備を、常時標準化（docker のリッチさ・AI 認証の永続化）と `--with-*` フラグ（cloud・AI ツール）へ分解しています。

旧 mode を再現するおおよその対応:

| 旧指定 | 新指定（おおよその等価） |
|---|---|
| `--mode minimal` | フラグなし（`--with-*` を付けない） |
| `--mode standard` | `--with-aws`（AWS CLI + Terraform + copilot 相当が必要なら `--with-copilot` も付ける） |
| `--mode full` | `--with-aws --with-gcp --with-claude --with-gemini --with-copilot` |

注意点:

- **docker のリッチさ**（buildx / compose-switch）は旧 `standard` / `full` のみでしたが、**全生成物で標準装備**になりました。旧 `minimal` 利用者にも付きます。
- **AI CLI の自動導入は廃止**しました。旧構成ではトークン（`CLAUDE_CODE_OAUTH_TOKEN` 等）があれば `claude` / `gemini` が自動導入されましたが、今後は `--with-claude` / `--with-gemini` の明示指定が必要です。
- **AI 認証の永続化は mode 非依存**になりました。旧 `full` のみだった `~/.claude` 等の永続化は、`--with-<ai>` を選べばどの構成でも有効です。
- **Copilot 拡張**（`github.copilot` / `github.copilot-chat`）は旧 `standard` / `full` の既定でしたが、`--with-copilot` の明示指定へ変わりました。
- `--with-codex`（OpenAI Codex）/ `--with-sakura`（さくらのクラウド）/ `--with-cloudflare`（Cloudflare）は将来対応予定で、現時点では未対応です。

