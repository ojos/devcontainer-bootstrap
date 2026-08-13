#!/usr/bin/env bash
# bootstrap.sh — devcontainer 雛形のワンショット生成スクリプト（単体動作）
# 目的: 新規作業ディレクトリに1コマンドで devcontainer 雛形を生成する
# 使用方法:
#   curl -sSL https://github.com/ojos/devcontainer-bootstrap/releases/latest/download/bootstrap.sh \
#     -o bootstrap.sh && bash bootstrap.sh --project-name myapp --languages node,go --with-aws
set -euo pipefail

# 同階層の ai-playbook チェックアウトを探すために解決する。curl で単体取得された
# 場合は同階層が存在しないため、--playbook-from の指定が必須になる。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_NAME=""
OUTPUT_DIR=""
LANGUAGES=()
# --with-* で選択された装備（cloud / AI ツール / リモート機構）の集合。空既定。
# 例: aws gcp claude gemini copilot copilot-review。has_with で参照する。
# 判定は完全一致なので、copilot-review を足しても copilot の判定には影響しない。
WITH_SET=()
FORCE="false"
DRY_RUN="false"
MANAGE_GITIGNORE="true"
GITIGNORE_TARGETS=""

BASE_IMAGE_OVERRIDE=""
BASE_IMAGE=""
GITIGNORE_BEGIN="# >>> devcontainer-bootstrap managed section >>>"
GITIGNORE_END="# <<< devcontainer-bootstrap managed section <<<"
GITIGNORE_REPO_RAW_BASE="https://raw.githubusercontent.com/github/gitignore/main"

WITH_PLAYBOOK=""
PLAYBOOK_FROM=""
PLAYBOOK_VERSION=""
PLAYBOOK_CONFLICT_POLICY="skip"
PLAYBOOK_REL_ROOT=".ai-playbook"
PLAYBOOK_DIR=""
PLAYBOOK_TMP_ROOT=""

usage() {
  # 1 行目は呼び出しに使われたパスをそのまま示す。開発リポジトリでは
  # packages/devcontainer-bootstrap/bootstrap.sh、公開配布物ではリポジトリ直下と
  # 配置が異なるため、固定パスではどちらか一方でしか解決しない。
  # 以降の本文は $PWD をリテラルで含むため、ヒアドキュメントは引用符付きのまま保つ。
  printf 'usage: bash %s [options]\n\n' "$0"
  cat <<'EOF'
options:
  --project-name <name>       Project name for devcontainer display name (required)
  --languages <csv>           Language runtimes (CSV: node,go,python,php,rust,ruby) (required)
  --with-aws                  Install AWS CLI + Terraform (feature/extension)
  --with-gcp                  Install Google Cloud CLI + Terraform (feature/extension)
  --with-claude               Install Claude Code CLI + extension (persisted)
  --with-gemini               Install Gemini CLI + extension (persisted)
  --with-antigravity          Install Antigravity CLI (agy; OAuth only, persisted)
  --with-copilot              Install GitHub Copilot CLI + extensions (persisted)
  --with-copilot-review       Place the remote review-gate workflows only
                              (requires rules placement; no local tooling)
  --output-dir <path>         Output directory (default: $PWD/<project-name>)
  --base-image <image>        Override auto-selected devcontainer base image
  --dry-run                   Show planned outputs without writing files
  --force                     Overwrite existing files
  --no-gitignore              管理対象の .gitignore セクションを更新しない
  --gitignore-targets <csv>   Additional template names to use (e.g. VisualStudioCode,JetBrains)
  --with-playbook             Install shared AI rules (ai-playbook) and entry files
  --without-playbook          Do not install shared AI rules
  --playbook-from <path|url>  Playbook source (directory path or archive URL)
  --playbook-version <tag>    Shorthand for the ojos/ai-playbook tag tarball
                              (mutually exclusive with --playbook-from)
  --playbook-conflict-policy <skip|overwrite|prompt>
                              Policy when a rules file already exists (default: skip)
  -h, --help                  Show help

notes:
  Cloud/AI tooling is opt-in via --with-* flags (no --mode). Terraform is
  bundled automatically when --with-aws or --with-gcp is given (once).
  AI CLIs are installed only when their --with flag is present (no token-based
  auto-install); each --with AI tool also adds its VS Code extension and
  persists its config across rebuilds.

  Local tooling and the remote review mechanism are separate flags.
  --with-copilot wires only the local side (CLI, extensions, persisted config);
  --with-copilot-review places only the remote workflows. The latter requires a
  rules placement (--with-playbook / --playbook-version / --playbook-from),
  because those workflow templates are owned by the rules package; without one
  the run stops before writing any file.

  Credentials are never injected from the host. remoteEnv carries only
  LOCAL_WORKSPACE_FOLDER; authenticate inside the container (gh auth login,
  claude /login, ...). Those logins survive a rebuild: gh is always persisted
  (gh-storage), and aws / gcloud and the config dirs of the AI CLIs are
  persisted in named volumes when their --with-* flag is given.
  Project-scoped values such as GEMINI_API_KEY belong in the project .env,
  which scripts/load-project-env.sh reads.

  Shared AI rules are maintained in a separate repository. This script places
  them into the generated project; it is a distribution mechanism, not the
  source of truth.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)     PROJECT_NAME="$2"; shift 2 ;;
    --languages)        IFS=',' read -ra LANGUAGES <<< "$2"; shift 2 ;;
    --with-aws)         WITH_SET+=("aws"); shift ;;
    --with-gcp)         WITH_SET+=("gcp"); shift ;;
    --with-claude)      WITH_SET+=("claude"); shift ;;
    --with-gemini)      WITH_SET+=("gemini"); shift ;;
    # --with-gemini には束ねない。認証手段が違い（API キー / OAuth）、片方だけ
    # 使いたい構成が実在する。束ねると使わない CLI が必ず入る。永続 volume だけは
    # 共有する（agy は資格情報を ~/.gemini/antigravity-cli/ へ置くため）。
    --with-antigravity) WITH_SET+=("antigravity"); shift ;;
    --with-copilot)     WITH_SET+=("copilot"); shift ;;
    # ローカル装備（--with-copilot）とは別のフラグにする。両者は性質が違い
    # （手元の開発ツール / リモートのレビュー機構）、片方だけ欲しい構成が実在する。
    # 1 つのフラグで束ねると「リモートのゲートだけ欲しい」を機構で表現できない。
    --with-copilot-review) WITH_SET+=("copilot-review"); shift ;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
    # 廃止フラグは黙殺せず、移行先を示して停止する。黙って無視すると
    # 「指定したのに注入されない」状態を作り、資格情報の所在をふたたび曖昧にする。
    --github-profiles|--gemini-key-env)
      echo "error: $1 は廃止されました（資格情報のホスト注入を撤去したため）。" >&2
      echo "       GitHub の認証はコンテナ内で 'gh auth login' を実行してください。" >&2
      echo "       GEMINI_API_KEY などのプロジェクト固有値は生成先の .env に置いてください" >&2
      echo "       （scripts/load-project-env.sh が読み込みます）。" >&2
      exit 1
      ;;
    --base-image)       BASE_IMAGE_OVERRIDE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --force)            FORCE="true"; shift ;;
    --no-gitignore)     MANAGE_GITIGNORE="false"; shift ;;
    --gitignore-targets)   GITIGNORE_TARGETS="$2"; shift 2 ;;
    --with-playbook)    WITH_PLAYBOOK="true"; shift ;;
    --without-playbook) WITH_PLAYBOOK="false"; shift ;;
    --playbook-from)    PLAYBOOK_FROM="$2"; shift 2 ;;
    --playbook-version) PLAYBOOK_VERSION="$2"; shift 2 ;;
    --playbook-conflict-policy) PLAYBOOK_CONFLICT_POLICY="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ── 検証 ───────────────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}
require_cmd jq
require_cmd perl
require_cmd awk
require_cmd sed
require_cmd curl

[[ -n "$PROJECT_NAME" ]] || { echo "error: --project-name is required" >&2; usage; exit 1; }
# プロジェクト名は compose のマウントパス・workspaceFolder・sed 置換に流れるため、
# それらを壊す文字を拒否する（| & は sed、: は compose の volume 記法、/ \ はパス、
# " は生成 JSON の文字列リテラル）。
if [[ "$PROJECT_NAME" == *['|&:/\"']* ]]; then
  echo "error: --project-name must not contain any of: | & : / \\ \"" >&2
  exit 1
fi
[[ ${#LANGUAGES[@]} -gt 0 ]] || { echo "error: --languages is required" >&2; usage; exit 1; }

for i in "${!LANGUAGES[@]}"; do
  LANGUAGES[i]=$(echo "${LANGUAGES[i]}" | xargs)
done
for lang in "${LANGUAGES[@]}"; do
  case "$lang" in
    node|go|python|php|rust|ruby) ;;
    *) echo "error: unsupported language: $lang (supported: node, go, python, php, rust, ruby)" >&2; exit 1 ;;
  esac
done
case "$PLAYBOOK_CONFLICT_POLICY" in
  skip|overwrite|prompt) ;;
  *) echo "error: --playbook-conflict-policy must be one of: skip, overwrite, prompt" >&2; exit 1 ;;
esac

# --playbook-version は既定ソース ojos/ai-playbook のタグ tarball への糖衣。
# 版だけで指定でき、長い archive URL を打たずに済む。任意ソース（別 owner・
# ディレクトリ・任意 URL）は従来どおり --playbook-from を使う。両者は排他:
# 同時指定は「どちらのソースか」が曖昧になるため、片方優先ではなくエラーにする。
if [[ -n "$PLAYBOOK_VERSION" ]]; then
  if [[ -n "$PLAYBOOK_FROM" ]]; then
    echo "error: --playbook-version と --playbook-from は同時に指定できません" >&2
    exit 1
  fi
  PLAYBOOK_FROM="https://github.com/ojos/ai-playbook/archive/refs/tags/${PLAYBOOK_VERSION}.tar.gz"
  # 展開結果を明示する（テスト・利用者確認のため。ネットワーク取得の前に出す）。
  echo "[bootstrap] playbook-version=$PLAYBOOK_VERSION -> $PLAYBOOK_FROM"
fi

[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$PWD/$PROJECT_NAME"

# Docker サーバーのプラットフォームに基づいてベースイメージを選択する（安全なフォールバック付き）
detect_server_platform() {
  local platform
  if command -v docker >/dev/null 2>&1; then
    platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)"
    if [[ -n "$platform" && "$platform" == */* ]]; then
      printf '%s\n' "$platform"
      return 0
    fi
  fi
  # ブートストラップ中に docker へアクセスできない環境向けのフォールバック。
  printf '%s\n' "linux/amd64"
}

image_supports_platform() {
  local image="$1"
  local os="$2"
  local arch="$3"
  local manifest

  manifest="$(docker manifest inspect "$image" 2>/dev/null || true)"
  [[ -n "$manifest" ]] || return 1

  printf '%s' "$manifest" | grep -q "\"os\": \"$os\"" || return 1
  printf '%s' "$manifest" | grep -q "\"architecture\": \"$arch\"" || return 1
  return 0
}

select_base_image() {
  local platform os arch
  local candidates
  local image

  if [[ -n "$BASE_IMAGE_OVERRIDE" ]]; then
    BASE_IMAGE="$BASE_IMAGE_OVERRIDE"
    echo "[bootstrap] base-image=override:$BASE_IMAGE"
    return 0
  fi

  platform="$(detect_server_platform)"
  os="${platform%/*}"
  arch="${platform#*/}"

  candidates="mcr.microsoft.com/devcontainers/base:ubuntu mcr.microsoft.com/devcontainers/base:debian"

  if command -v docker >/dev/null 2>&1; then
    for image in $candidates; do
      if image_supports_platform "$image" "$os" "$arch"; then
        BASE_IMAGE="$image"
        echo "[bootstrap] base-image=auto:$BASE_IMAGE ($os/$arch)"
        return 0
      fi
    done
  fi

  BASE_IMAGE="mcr.microsoft.com/devcontainers/base:ubuntu"
  echo "[bootstrap] WARN: no compatible manifest check result; fallback base-image=$BASE_IMAGE ($os/$arch)" >&2
}

select_base_image

# ── 組み込みテンプレート（bash 3 互換） ─────────────────────────────────

# 生成する相対パス一覧。mode を廃したため単一の集合。
template_rel_paths() {
  printf '%s\n' \
    '.env.example' \
    '.devcontainer/compose.yaml' \
    '.devcontainer/devcontainer.json' \
    '.github/workflows/identity-guard.yml' \
    '.github/workflows/verify.yml' \
    'scripts/acceptance.sh' \
    'scripts/check-no-secrets.sh' \
    'scripts/fix-mount-owner.sh' \
    'scripts/install-ai-tools.sh' \
    'scripts/load-project-env.sh' \
    'scripts/loop-gate.sh' \
    'scripts/on-attach.sh' \
    'scripts/post-rebuild-check.sh' \
    'scripts/setup-git-identity.sh' \
    'scripts/verify-commit-identity.sh' \
    'scripts/verify.sh'
}

# --with-* の選択に応じて書き出すテンプレートの相対パス。
# 無条件のものは template_rel_paths() が持つ。両者を分けるのは、
# tests/test-template-mirror.sh が「生成対象の全件」を抽出するとき、
# 条件付きのものを取りこぼさないようにするため（あちらは 2 つの関数の本体を
# 別々の書式で読む。1 つの関数へ混ぜると、条件行を抽出できず分類漏れが素通りする）。
#
# 判定は has_with に依るが、この関数の定義位置は has_with より前でよい。呼び出しは
# 書き出し直前（メイン処理）で、そこでは両方とも定義済みになっている。
#
# 条件は if 文で書く。`has_with aws || has_with gcp && printf ...` の形は、bash では
# || と && が同じ優先順位・左結合なので条件の意味自体は等価だが（実測）、どちらも
# 偽のとき関数の終了ステータスが 1 になる。呼び出し側は下記のとおり
# `{ template_rel_paths; conditional_template_rel_paths; } | sort` で集めており、
# bootstrap.sh は set -euo pipefail なので pipefail がこの 1 をパイプライン全体の
# 失敗へ持ち上げ、**装備を選んでいない構成で bootstrap がその場で停止する**
# （実測: 何も出力しないまま終了コード 1）。if 文は条件が偽でも 0 を返すため起きない。
conditional_template_rel_paths() {
  # 外部層の受け入れ条件は、外部状態を持つ構成だけへ配る。cloud 装備を選んでいない
  # 構成へ空の雛形を配ると、使わないファイルを消す作業をさせることになる。
  if has_with aws || has_with gcp; then
    printf '%s\n' 'scripts/acceptance-remote.sh'
  fi
  # マージ確認フックとその配線先は Claude 実行環境の機構なので --with-claude に従う。
  # .claude/.gitignore は settings.local.json の除外を .claude/ の中で閉じるために配る
  # （生成先の .gitignore 管理セクションへ .claude/ 固有の行を書かないため）。
  if has_with claude; then
    printf '%s\n' \
      '.claude/.gitignore' \
      '.claude/settings.json' \
      'scripts/confirm-merge-hook.sh'
  fi
}

get_template_content() {
  local rel="$1"
  case "$rel" in
    '.env.example')
      # プロジェクト固有値の唯一の供給元。ホストからの注入は行わないため、
      # 利用者はこの雛形を .env へ複製して埋める。
      cat <<'TMPL'
# プロジェクト固有の値。.env へ複製して使う（.env は追跡しない）。
#
# ホスト OS の環境変数はコンテナへ注入されない。devcontainer.json の remoteEnv は
# 作業ディレクトリの受け渡し（LOCAL_WORKSPACE_FOLDER）だけを担う。ここに書いた値が
# 唯一の供給元になり、「どの資格情報を使っているか」がファイルとして目に見える。
#
# 認証そのもの（cloud / AI CLI）はコンテナ内で行う。ログイン状態は named volume に
# 残るため、rebuild しても消えない。トークンをこのファイルへ書き写す必要はない。
# 例外は GitHub（gh）だけで、理由は下の GH_TOKEN の項に書く。

# Gemini API キー（第二意見レビュー scripts/second-opinion-review.sh が読む）
GEMINI_API_KEY=
__SECOND_OPINION_ENGINE_LINES__

# GitHub の PAT（personal access token）。gh がこの名前を直接読む。
#
# 空にすると従来どおり、コンテナ内の `gh auth login` で保存した OAuth トークン
# （~/.config/gh/hosts.yml）が使われる。PAT を持たない利用者はこのまま空でよい。
#
# ただし GITHUB_TOKEN も未設定（または空）であることが条件。gh は
# GH_TOKEN -> GITHUB_TOKEN の順に環境変数を読み、空文字だけを読み飛ばす
# （gh 2.96.0 で実測）。GITHUB_TOKEN に値があると、GH_TOKEN を空にしても
# 保存済み認証へは戻らず GITHUB_TOKEN が使われる。GITHUB_TOKEN は恒久的に
# 設定しないこと。空の GH_TOKEN は GITHUB_TOKEN に対する盾にならない。
#
# ここへ PAT を書き写すのは、gh の OAuth App に「ユーザー × アプリ × scope あたり
# 10 トークン」の上限があるため。上限に達した状態でどこかの環境が認証すると、
# GitHub が既存のトークンを 1 本破棄する（理由コード max_for_app）。溜まる単位は
# 環境ではなく認証の回数で、`gh auth login` も `gh auth refresh` も自分の古い枠を
# 返さない。失効に気づいた環境が再認証し、それがまた別の環境を殺す形で連鎖する。
# これは実運用のセキュリティログで、理由コード max_for_app として確定している。
# PAT は OAuth App の認可ではないため、この枠の外にある。
#
# gh 自身が読む名前をそのまま使う。GIT_IDENTITY_* が別名なのと方針が逆に見えるが、
# 理由が違う。git は自身が読む名前（GIT_AUTHOR_EMAIL 等）を環境へ置くと
# user.useConfigOnly の保護が無効になるため別名にしている。gh には、環境変数を
# 置くことで無効化される保護が無い。別名にしても受け渡しの仕掛けが増えるだけになる。
#
# 設定しているあいだ `gh auth login` は効かなくなる（env が優先される）。これは
# 制約ではなく安全装置として扱う。うっかり再認証して他環境のトークンを殺す事故が
# 構造的に起きなくなる。設定中は login を実行しないこと。実行しても使われないまま
# OAuth トークンが 1 本発行され、上限に達していれば他環境の 1 本が消えるだけになる。
GH_TOKEN=

# git のコミット identity。scripts/setup-git-identity.sh が local へ適用する。
#
# GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL という名前を使わないのは、それが git 自身の読む
# 環境変数だから。環境に置くと local 設定を持たないリポジトリでも identity が解決でき、
# user.useConfigOnly による保護（未設定なら commit を止める）が無効になる。
GIT_IDENTITY_NAME=
GIT_IDENTITY_EMAIL=
TMPL
      ;;
    '.devcontainer/compose.yaml')
      # 永続 volume は構成に応じて条件配線する（__VOLUME_MOUNTS__ /
      # __VOLUME_SECTION__ を render_content が置換）。gh は常時、cloud と AI ツールは
      # 選択時のみ。docker socket は常に明示。
      cat <<'TMPL'
services:
  app:
    image: __BASE_IMAGE__
    volumes:
      - ..:/workspaces/__PROJECT_NAME__:cached
      # docker-outside-of-docker feature 用（compose 利用時は feature 側の mounts が適用されないため明示）
      - /var/run/docker.sock:/var/run/docker-host.sock
__VOLUME_MOUNTS__
    command: sleep infinity
__VOLUME_SECTION__
TMPL
      ;;
    '.devcontainer/devcontainer.json')
      # docker はリッチさ（buildx + compose-switch）を全生成物で標準化。
      # cloud（aws/gcp/terraform）と cloud/AI の VS Code 拡張は --with-* に応じて
      # 条件配線する（__IF_WITH_*__ / __WITH_EXTENSIONS__ を render_content が処理）。
      # 条件行は末尾カンマ付きで置き、write_file の perl 除去 + jq 整形で末尾カンマを畳む。
      # 静的解析器 shellcheck は ripgrep / tmux と同じく常時同梱する（--with-* を増やさない）。
      # この生成物が配る scripts/* は言語やフラグに依らず必ずシェルスクリプトであり、
      # 受け入れ条件の雛形（scripts/acceptance.sh）が静的解析を前提にできる価値が、
      # feature 1 つぶんのビルド時間を上回る。
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__",
  "dockerComposeFile": "compose.yaml",
  "service": "app",
  "workspaceFolder": "/workspaces/__PROJECT_NAME__",
  "shutdownAction": "stopCompose",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:1": {
      "configureZsh": true
    },
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": false,
      "dockerDashComposeVersion": "latest",
      "installDockerComposeSwitch": true,
      "installDockerBuildx": true
    },
    "ghcr.io/devcontainers-extra/features/ripgrep:1": {},
    "ghcr.io/devcontainers-extra/features/shellcheck:1": {},
    "ghcr.io/devcontainers-extra/features/tmux-apt-get:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "__IF_RUNTIME_PHP__": "ghcr.io/devcontainers/features/php:1",
    "__IF_RUNTIME_RUST__": "ghcr.io/devcontainers/features/rust:1",
    "__IF_RUNTIME_RUBY__": "ghcr.io/devcontainers/features/ruby:1",
    "__IF_WITH_AWS__": "ghcr.io/devcontainers/features/aws-cli:1",
    "__IF_WITH_GCP__": "ghcr.io/dhoeric/features/google-cloud-cli:1",
    "__IF_WITH_TERRAFORM__": "ghcr.io/devcontainers/features/terraform:1"
  },
  "remoteEnv": {
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postCreateCommand": "bash scripts/fix-mount-owner.sh && bash scripts/install-ai-tools.sh",
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": [
__LANGUAGE_EXTENSIONS__
__WITH_EXTENSIONS__
        "ms-azuretools.vscode-containers"
      ]
    }
  }
}
TMPL
      ;;
    '.github/workflows/identity-guard.yml')
      # コミット identity の検証ゲート。判定は scripts/verify-commit-identity.sh に置き、
      # ワークフローはそれを呼ぶだけ（CI と手元で同じコードを走らせる）。許可 author email は
      # リポジトリ変数 vars.ALLOWED_AUTHOR_EMAILS を env 経由でスクリプトへ渡す（固有 email を
      # 生成物に焼き込まない）。pull_request と push(main) の 2 系統を張る。
      cat <<'TMPL'
name: identity-guard

# コミット identity の検証ゲート。
#
# git identity の適用漏れにより、別アカウントの identity のコミットが main に
# 直接入り、GitHub の Contributors に意図しないアカウントが現れる事故を防ぐ。
# 適用漏れそのものは scripts/setup-git-identity.sh が塞ぎ、ここはその検知層。
#
# 判定ロジックは scripts/verify-commit-identity.sh に置く。CI と手元で同じ
# コードを走らせ、push 前にローカルで先に落とせるようにするため。
#
# 許可 author email は生成物に焼き込まず、リポジトリ変数から渡す:
#   利用側リポジトリの Settings > Secrets and variables > Actions > Variables に
#   ALLOWED_AUTHOR_EMAILS を作成し、許可する author email を設定する
#   （複数はカンマまたは空白区切り。例: "you@example.com"）。
#
# 2 系統を張る:
#   - pull_request: PR に含まれる全コミットを検査する（通常経路）
#   - push(main):   main の全履歴を検査する（PR を経由しない直接 push を捕捉）
#                   直接 push こそが混入の原因なので、こちらを省略しない。

on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  verify-commit-identity:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # 範囲指定で履歴を辿るため全履歴が要る。
          fetch-depth: 0

      - name: Verify commit identity
        env:
          # 固有 email を焼き込まず、リポジトリ変数から許可 author email を渡す。
          ALLOWED_AUTHOR_EMAILS: ${{ vars.ALLOWED_AUTHOR_EMAILS }}
          EVENT_NAME: ${{ github.event_name }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          if [ "$EVENT_NAME" = "pull_request" ]; then
            bash scripts/verify-commit-identity.sh "${BASE_SHA}..${HEAD_SHA}"
          else
            bash scripts/verify-commit-identity.sh --full
          fi
TMPL
      ;;
    '.github/workflows/verify.yml')
      # 受け入れ検証（scripts/verify.sh）を CI で回すゲート。判定は verify.sh /
      # acceptance.sh 側に置き、ワークフローは段取りだけを持つ（identity-guard.yml と
      # 同じ方針）。言語ランタイムやツールの導入は持たない。何が必要かは acceptance.sh が
      # 何を検査するかに従属し、プロジェクトごとに違うため、位置だけをコメントで示す。
      cat <<'TMPL'
name: verify

# 受け入れ検証（scripts/verify.sh）を CI で回すゲート。
#
# verify.sh / loop-gate.sh は手元で走らせる前提の実行体で、回し忘れても何も
# 起きない。ローカル事前ゲートを通していない PR は、受け入れ条件を満たさないまま
# レビューへ届く。ゲートを整備しても実行を忘れられるなら、守られている外観だけが
# 残る。ここが担うのは判定ではなく「実行されること」の側である。
#
# 判定ロジックはこのファイルへ書き写さない。scripts/verify.sh を呼ぶだけにして、
# 手元と CI が同じコードで判定するようにする。書き写すと、手元で緑・CI で赤に
# なったときにどちらが正しいのかを決められなくなる。
#
# 2 系統を張る:
#   - pull_request: マージ前に落とす（通常経路）
#   - push(main):   PR を経由しない直接 push と、マージ後の統合状態を検査する。
#                   並列に進む PR は互いの変更を見ないまま緑になるため、統合して
#                   初めて壊れる組み合わせがある。こちらを省略しない。

on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [main]

permissions:
  contents: read

# 同じ PR への連続 push で古い実行を積み残さない。
#
# main では取り消さない。push(main) が見ているのはマージ後の統合状態そのもので、
# 続く push で前の実行を消すと「どのコミットから壊れたか」を追えなくなる。
# pull_request では最新の head だけが関心の対象なので取り消す。
#
# 取り消さないことと直列化しないことは別の要求である。push 側のグループ鍵に
# github.ref を使うと、main への push はどのコミットでも同じ ref
# （refs/heads/main）になるため、cancel-in-progress: false と組み合わさって
# 「取り消されない代わりに同じグループで直列にキュー待ちする」状態になる。
# 連続してマージしたときに後続の実行が待たされ、統合状態を素早く追うという
# 目的に反する。github.sha を使い、push はコミットごとに別グループへ分ける
# ことで、取り消しも待ちも起きないようにする。
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  verify:
    runs-on: ubuntu-latest

    # fork からの PR の扱い: この雛形はスキップしない。
    #
    # scripts/verify.sh 自体は Secrets を必要とせず、permissions: contents: read で
    # 足りる。これは fork からの PR に既に与えられている権限であり、走らせられない
    # 理由が無い。スキップすれば、最も検証が要る外部からの変更にだけゲートが
    # 掛からなくなる。スキップの根拠は「その権限では実行できない」ことに限り、
    # 「赤くなりうるから」では外さない。
    #
    # ただし fork からの PR には Secrets もリポジトリ変数（vars）も渡らない。
    # scripts/acceptance.sh へ vars / Secrets に依存する検査を足すと、その検査は
    # fork からの PR でだけ供給元を失う。fail-closed な検査であれば常に赤くなり、
    # 赤が定常状態のゲートは誰も見なくなる。足す側で次のどちらかを選ぶこと。
    #   - 供給元を要する検査を acceptance.sh へ入れず、それ専用のワークフローに
    #     置く（例: 許可 author email を要するコミット identity の検査）。
    #   - fork からの PR を受け付けないリポジトリなら、次の 1 行を有効にする。
    #
    # 条件は fork の真偽で書く。よく使われる
    # `head.repo.full_name == github.repository` の形は、push では
    # github.event.pull_request が無く左辺が空になるため、push(main) の系統まで
    # 丸ごとスキップされる（あちらの形が成り立つのは pull_request だけを契機に
    # 持つワークフロー）。
    # if: github.event.pull_request.head.repo.fork != true

    steps:
      - uses: actions/checkout@v4
        with:
          # 全履歴・全 ref を取る。
          #
          # 既定（fetch-depth: 1）は対象の ref 1 本を深さ 1 で取るだけで、既定
          # ブランチの追跡枝（origin/main）が作られない。ここで起きるのは「範囲が
          # 解決できずに落ちる」ことではなく、範囲を HEAD の全履歴へ落としたうえで、
          # その全履歴が 1 コミットしか無い状態で通過することである。落ちるなら
          # 気づけるが、これは偽の緑になる。
          #
          # 実測（許可外 author を 1 件含む 2 コミットの PR に対する identity 検証）:
          #   深さ 1 -> 検査対象 1 件 / exit 0 で通過
          #   全履歴 -> 検査対象 2 件 / exit 1 で検出
          #
          # acceptance.sh へ履歴を見る検査を足した時点でこの差が効くため、雛形の
          # 側で全履歴を取っておく。
          fetch-depth: 0

      # ── プロジェクトの前提はここへ足す ──────────────────────────────────────
      #
      # 言語ランタイムの用意・ツール（静的解析器など）の導入・依存のインストールは
      # この雛形が持たない。何が必要かは scripts/acceptance.sh が何を検査するかに
      # 従属し、プロジェクトごとに違う。雛形が中途半端に決め打つと、使わない手順を
      # 毎回消す作業をさせることになる。
      #
      # 例（そのまま貼らず、実態に合わせて書く）:
      #   - uses: actions/setup-node@v4
      #     with:
      #       node-version: '20'
      #   - run: npm ci
      #   - run: sudo apt-get update && sudo apt-get install -y shellcheck

      - name: Verify acceptance
        env:
          # CI には .env が無いため、リポジトリ変数がここでの唯一の供給元になる。
          # acceptance.sh が許可 author email を要する検査を持つ構成のために渡す。
          # 要らない構成では空のまま渡り、何も起きない。
          #   利用側リポジトリの Settings > Secrets and variables > Actions >
          #   Variables に ALLOWED_AUTHOR_EMAILS を作成する
          #   （複数はカンマまたは空白区切り。例: "you@example.com"）。
          ALLOWED_AUTHOR_EMAILS: ${{ vars.ALLOWED_AUTHOR_EMAILS }}
        run: bash scripts/verify.sh
TMPL
      ;;
    'scripts/install-ai-tools.sh')
      # 選択された AI CLI のみを無条件に導入する（--with-* による明示 opt-in）。
      # トークン有無での自動インストールは行わない。__AI_INSTALL_LINES__ は
      # render_content が選択 AI ツール分の install 行に置換する（未選択なら空）。
      # 永続 volume の所有権修復は fix-mount-owner.sh が postCreate の先頭で行う。
      #
      # 雛形の地の文へ装備名を列挙しないこと。ヒアドキュメント内は構成によらず
      # そのまま生成物へ入るため、列挙すると選ばれていない装備の名前が残る。
      # 「そのフラグを指定しなければ関連する記述が 1 行も入らない」を、テストが
      # 生成物ツリー全体の grep で検査している（test-antigravity.sh）。
      cat <<'TMPL'
#!/usr/bin/env bash
# 選択された AI CLI ツールを導入する（生成時に --with-* で選ばれたものだけ）。
set -euo pipefail

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[install-ai-tools] $cmd already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing $pkg ..."
  npm install -g "$pkg"
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
}

__AGY_FUNCTION_LINES__
__AI_INSTALL_LINES__
echo "[install-ai-tools] done"
TMPL
      ;;
    'scripts/fix-mount-owner.sh')
      # 永続 volume のマウント先の所有権を remoteUser へ戻す。postCreate の先頭で
      # 走らせ、CLI 導入やログインより前に書き込み可能にする。
      # __MOUNT_OWNER_LINES__ は render_content が対象ディレクトリ分の行へ置換する。
      cat <<'TMPL'
#!/usr/bin/env bash
# fix-mount-owner.sh — 永続 named volume のマウント先を remoteUser 所有へ戻す。
#
# 空の named volume を初回マウントすると、マウントポイントは Docker デーモン
# （root）により root:root 所有で作られる。remoteUser が書き込めず、
# `gh auth login` や AI CLI のログインが Permission denied で落ちる。
#
# 対象は AI ツールに限らない。gh / aws / gcloud の認証ディレクトリも永続化する。
# ネストしたマウント先（~/.config/gh、~/.config/gcloud）は親 ~/.config が
# 先に root:root で作られる経路があるため、親も対象に含める。
#
# 終了コードは常に 0。ここで落ちると postCreate が止まり、CLI 導入まで到達しない。
# 「認証はできないが環境は立ち上がる」ほうが、原因の切り分けができるぶん実害が小さい。
# 失敗は WARN として標準エラーへ出す（握りつぶさない）。
set -uo pipefail

log()  { echo "[fix-mount-owner] $*"; }
warn() { echo "[fix-mount-owner] WARN: $*" >&2; }

# sudo は -n（非対話）で使う。パスワードを要求する環境で -n を落とすと、
# postCreate が入力待ちのまま固まり、原因が見えない形で rebuild が終わらなくなる。
sudo_chown() {
  local recursive="$1" target="$2"
  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo not available; cannot fix owner of $target"
    return 1
  fi
  if [[ "$recursive" == "recursive" ]]; then
    sudo -n chown -R "$(id -un):$(id -gn)" "$target" 2>/dev/null
  else
    sudo -n chown "$(id -un):$(id -gn)" "$target" 2>/dev/null
  fi
}

owned_by_me() {
  local owner
  owner="$(stat -c %U "$1" 2>/dev/null || stat -f %Su "$1" 2>/dev/null || echo '')"
  [[ "$owner" == "$(id -un)" ]]
}

# 親ディレクトリは非再帰で直す。~/.config 配下には他ツールの設定も入るため、
# 再帰 chown で無関係なファイルの所有権まで書き換えない。
fix_parent() {
  local parent="$1"
  [[ -d "$parent" ]] || return 0
  # $HOME 自身と / は対象外。ここを再帰的に遡ると影響範囲が読めなくなる。
  [[ "$parent" != "$HOME" && "$parent" != "/" ]] || return 0
  owned_by_me "$parent" && return 0
  if sudo_chown shallow "$parent"; then
    log "fixed owner of $parent (non-recursive)"
  else
    warn "failed to fix owner of $parent"
  fi
}

fix_mount() {
  local dir="$1"
  # マウントされていないディレクトリは触らない。
  if [[ ! -d "$dir" ]]; then
    log "$dir does not exist, skipping"
    return 0
  fi
  fix_parent "$(dirname "$dir")"
  # 既に現ユーザー所有なら再帰 chown を避ける（冪等・不要な再帰 I/O 回避）。
  if owned_by_me "$dir"; then
    log "$dir already owned by $(id -un), skipping"
    return 0
  fi
  if sudo_chown recursive "$dir"; then
    log "fixed owner of $dir -> $(id -un):$(id -gn)"
  else
    warn "failed to fix owner of $dir"
  fi
}

__MOUNT_OWNER_LINES__
log "done"
exit 0
TMPL
      ;;
    'scripts/load-project-env.sh')
      # プロジェクト .env を「ホスト由来の環境変数（remoteEnv）より優先」で読み込む。
      # 実行ではなく source して使う。source せず KEY=VALUE のみ安全にパースするため、
      # 壊れた .env が対話シェルの初期化ごと落とす事故を防ぐ。CWD 非依存でスクリプト位置から
      # ルートを解決し、bash / zsh の双方でソース中ファイルのパスを解決する。
      cat <<'TMPL'
#!/usr/bin/env bash
# load-project-env.sh — プロジェクト固有の .env を「ホスト由来の環境変数より優先」で読み込む。
#
# 目的: devcontainer の remoteEnv がホスト OS の環境変数（GEMINI_API_KEY 等）を
#       コンテナへ注入する構造は維持したまま、本プロジェクトのみ .env の値を上書き優先する。
#
# 使い方: 実行ではなく source して使う。
#   . scripts/load-project-env.sh
#
# 設計:
#   - 対象 .env はスクリプト自身の位置から解決する（CWD 非依存・パス非ハードコード）。
#     scripts/ の 1 階層上をルートとみなす。別ディレクトリ名でクローンしても追随し、
#     別リポジトリへ cd 済みのシェルから source しても誤検出しない（rc 側は絶対パスを注入）。
#     PROJECT_ENV_FILE で明示的に差し替え可能。
#   - .env は source せず安全にパースする（KEY=VALUE のみ export、任意コードは実行しない）。
#     これにより、壊れた .env が対話シェルの初期化ごと落とす事故を防ぐ。
#   - CRLF・=前後や値前後の空白など、実務的な .env の揺れを吸収する。
#
# 冪等: 複数回 source しても安全。.env が無ければ何もしない。

__load_project_env() {
  local project_root env_file line key val src
  # ソース中ファイルのパスを bash / zsh 双方で解決する。zsh には BASH_SOURCE が無いため
  # ${BASH_SOURCE[0]} は空になり CWD 依存へ化ける。実行シェルを判定して回避する。
  if [ -n "${BASH_VERSION:-}" ]; then
    src="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    # zsh: 現在ソース中ファイルの絶対/相対パス。
    # この展開は zsh 固有で bash には無い。shellcheck は bash として解析するため
    # 構文エラー（SC2296）に見えるが、この行へ到達するのは ZSH_VERSION が立つ
    # zsh のときだけで、bash では評価されない。注記が無いと、scripts/ を静的解析に
    # 掛ける受け入れ条件を持つプロジェクトが、配布物のせいで赤になる。
    # shellcheck disable=SC2296
    src="${(%):-%x}"
  else
    src="$0"
  fi
  # スクリプト位置から解決（scripts/ の 1 階層上がルート）。CWD にもパスにも依存しない。
  project_root="$(cd "$(dirname "$src")/.." && pwd)"
  env_file="${PROJECT_ENV_FILE:-$project_root/.env}"

  # git worktree から実行された場合はメインの作業コピーの .env へ回り込む。
  # worktree は追跡ファイルしか持たず、.gitignore された .env は複製されない。
  # プロジェクト規約は並列実装に worktree 分離を機構で要求するため、ここで .env を
  # 引けないと worktree 側でローカルゲート（identity 検査を含む）が使えなくなる。
  # --git-common-dir はメインリポジトリの .git を指すので、その親がメインの作業コピー。
  # PROJECT_ENV_FILE で明示された場合は回り込まない（明示指定を上書きしないため）。
  if [[ -z "${PROJECT_ENV_FILE:-}" && ! -f "$env_file" ]] && command -v git >/dev/null 2>&1; then
    local common_dir main_root
    if common_dir="$(git -C "$project_root" rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$common_dir" ]]; then
      case "$common_dir" in
        /*) ;;
        *) common_dir="$project_root/$common_dir" ;;
      esac
      if main_root="$(cd "$common_dir/.." 2>/dev/null && pwd)" && [[ -f "$main_root/.env" ]]; then
        env_file="$main_root/.env"
      fi
    fi
  fi

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # CRLF 対策: Windows ホストでクローンされた .env の CR を除去。
    line="${line//$'\r'/}"
    # 行の前後の空白を除去し、空行・コメント行はスキップ。
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # 先頭の `export` 記法を許容。区切りがスペース以外（タブ等）でも剥がせるよう、
    # まず `export` 文字列だけを落としてから先頭空白をトリムする。
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    # KEY=VALUE 形式でなければスキップ。
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    # キー前後の空白を除去し、正当な識別子だけを対象にする（KEY = VALUE を許容）。
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # 値の前後の空白を除去（KEY= VALUE / KEY =VALUE 等）。クォート内の空白は後段で保持。
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # 値を囲む対のクォートがあれば外す（dotenv 慣習）。
    if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    # 後勝ちで既存の環境変数（remoteEnv 由来のホスト値）を上書きする。
    export "$key=$val"
  done < "$env_file"
}

__load_project_env
TMPL
      ;;
    'scripts/on-attach.sh')
      # 対話シェルへ .env autoload を配線する（rc 注入は冪等・マーカー判定・絶対パス参照）。
      # HELPER はスクリプト自身の位置から解決し、起動時 CWD に依存しない。
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] bootstrap active"

# スクリプト自身の位置から解決する（起動時 CWD に依存しない）。scripts/ 直下に
# load-project-env.sh / setup-git-identity.sh が並ぶ。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/load-project-env.sh"

# このスクリプト自身にもプロジェクト .env を効かせる。
#
# 下の rc 注入は「これから開く対話シェル」にしか効かず、bash で実行される
# on-attach.sh 自身には届かない。読まないと .env のキー（GH_TOKEN 等）が常に
# 空に見え、PAT を設定している利用者を「未認証」と誤認して 'gh auth login' を
# 案内してしまう。ローダーは source 専用・冪等で、.env が無ければ何もしない。
if [[ -f "$HELPER" ]]; then
  # shellcheck source=/dev/null
  . "$HELPER"
fi

# git identity の無害化。VS Code の dev.containers.copyGitConfig がリビルドのたびに
# ホストの ~/.gitconfig をコンテナへコピーし直すため、接続のたびに再適用する。
# 失敗しても on-attach 全体は落とさない。identity が未適用でも、未指定のまま
# コミットしようとすれば git 自身が exit 128 で止めるため、ここで打ち切る理由がない。
# `if ! ...` で捕捉するため setup-git-identity.sh が非ゼロで終了しても on-attach は 0 のまま。
if ! bash "$HERE/setup-git-identity.sh"; then
  echo "[on-attach] WARN: git identity の適用に失敗しました。" >&2
  # CWD に依存しないよう絶対パスで案内する（そのままコピペして実行できる形）。
  echo "[on-attach] WARN: 手動確認: bash $HERE/setup-git-identity.sh --check" >&2
fi

# 対話シェルでプロジェクト .env を自動 override 読み込みするための rc 注入（冪等）。
# これにより、ターミナルから起動する CLI（gemini 等）やスクリプトにも .env の値が効く。
inject_env_autoload() {
  local rc="$1"
  local marker="# >>> project .env autoload >>>"
  # rc が無いベースイメージでも autoload を効かせるため、存在しなければ作成する
  # （touch は既存ファイルを切り詰めない）。zsh 未導入環境で作られても無害（誰も読まない）。
  [[ -f "$rc" ]] || touch "$rc"
  grep -qF "$marker" "$rc" && return 0
  {
    echo ""
    echo "$marker"
    echo "if [[ -f \"$HELPER\" ]]; then . \"$HELPER\"; fi"
    echo "# <<< project .env autoload <<<"
  } >> "$rc"
  echo "[on-attach] injected project .env autoload into $rc"
}
inject_env_autoload "$HOME/.bashrc"
inject_env_autoload "$HOME/.zshrc"

# ホストの Docker 資格情報ヘルパーを打ち消す。
#
# VS Code の dev.containers.dockerCredentialHelper は、接続のたびにコンテナの
# ~/.docker/config.json へ credsStore を書き込む。これが残っていると、コンテナ内の
# docker login/pull がホスト OS のキーチェーンへ問い合わせ、ホスト側の資格情報を
# 黙って使う。remoteEnv を絞ってもこの経路は塞がらないため、接続ごとに打ち消す。
#
# 接続順序の都合で VS Code の書き込みに負ける場合があるため、これは多層防御の 1 枚に
# すぎない。確実に塞ぐにはホスト側で dev.containers.dockerCredentialHelper: false を
# 設定する（README 参照）。
strip_docker_creds_store() {
  local cfg="$HOME/.docker/config.json"
  [[ -f "$cfg" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "[on-attach] WARN: jq が無いため $cfg の credsStore を除去できません。" >&2
    return 0
  fi
  # credsStore / credHelpers のどちらも対象にする。前者はレジストリ横断、後者は
  # レジストリ個別にホストのヘルパーを指す。
  if ! jq -e 'has("credsStore") or has("credHelpers")' "$cfg" >/dev/null 2>&1; then
    return 0
  fi
  local tmp="$cfg.on-attach.tmp"
  if jq 'del(.credsStore, .credHelpers)' "$cfg" > "$tmp" 2>/dev/null && mv "$tmp" "$cfg"; then
    echo "[on-attach] removed credsStore/credHelpers from $cfg"
  else
    rm -f "$tmp"
    echo "[on-attach] WARN: $cfg の credsStore を除去できませんでした。" >&2
  fi
}
strip_docker_creds_store

# gh の認証状態を確認する。
#
# 判定は「いま実際に使われている資格情報が有効か」だけに絞る（--active）。環境変数の
# トークンと hosts.yml の保存済み認証は共存しうるため、--active を付けないと gh は
# 両方を並べて報告し、使っていない側が無効なだけで exit=1 になる。
GH_AUTH_TIMEOUT_SECS=10

# gh が資格情報として読む環境変数のうち、いま効いているものの名前を返す（無ければ空）。
#
# gh は GH_TOKEN → GITHUB_TOKEN の順に読み、空文字は読み飛ばして次へ落ちる
# （gh 2.96.0 で実測。GH_TOKEN= だけなら保存済み認証、GH_TOKEN= かつ
# GITHUB_TOKEN=<値> なら GITHUB_TOKEN が使われる）。空文字を未設定と同じに扱うのは、
# この gh 側の境界へ合わせるため。GITHUB_TOKEN を見落とすと、実際は環境変数で
# 認証しているのに「保存済み認証を使用」と報告し、失敗時には 'gh auth login' を
# 案内してしまう。
gh_active_env_token_var() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf 'GH_TOKEN'
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'GITHUB_TOKEN'
  fi
}

check_gh_auth() {
  local rc=0 env_var
  env_var="$(gh_active_env_token_var)"

  # 応答が返らないまま接続処理を止め続けない。timeout が無い環境では打ち切れない
  # ため、その場合だけ素で呼ぶ（124 の分岐へは入らなくなる）。
  if command -v timeout >/dev/null 2>&1; then
    timeout "$GH_AUTH_TIMEOUT_SECS" gh auth status --active >/dev/null 2>&1 || rc=$?
  else
    gh auth status --active >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    if [[ -n "$env_var" ]]; then
      echo "[on-attach] gh auth OK ($env_var の値を使用)"
    else
      echo "[on-attach] gh auth OK (コンテナ内の保存済み認証を使用)"
    fi
    # GITHUB_TOKEN は供給元として想定していない。設定されていると、保存済み認証も
    # .env の GH_TOKEN も黙って上書きされる。動いているうちに知らせる。
    if [[ "$env_var" == "GITHUB_TOKEN" ]]; then
      echo "[on-attach] WARN: GITHUB_TOKEN が保存済み認証より優先されています。恒久的に設定しないでください（空にすれば GH_TOKEN か保存済み認証へ戻ります）。" >&2
    fi
    return 0
  fi

  # ここで「到達できない」とも「認証が無効」とも断定しない。
  #
  # gh の出力では両者を区別できないことを実測している。プロキシ経由でしか外へ出られ
  # ない状態を作って `gh auth status --active` を走らせると、到達できていないだけでも
  # "The token in GH_TOKEN is invalid." と言う。
  #
  # 到達性を自前で測る案（bash の /dev/tcp で 443 へ直接つなぐ）は採らなかった。測れる
  # のは直接経路だけで、gh が使うのはプロキシ経路である。プロキシ経由でしか外へ出られ
  # ない環境では直接接続が塞がれ、gh は疎通しているのに「到達できません」と誤判定する。
  # 逆に直接は開いていてプロキシ設定だけが壊れている環境では、「到達できています」と
  # 誤判定して無効な断定を返す。配布物は網構成を知り得ないため、断定できないものを
  # 断定しない側へ寄せる。
  #
  # 打ち切り（timeout の exit 124）だけは観測できた事実なので、分けて報告する。
  if [[ "$rc" -eq 124 ]]; then
    echo "[on-attach] WARN: gh の認証確認が ${GH_AUTH_TIMEOUT_SECS} 秒で完了しませんでした。認証は判定していません（ネットワークへ到達できていない可能性があります）。" >&2
  else
    echo "[on-attach] WARN: gh の認証を確認できませんでした。認証は判定していません（資格情報が無効か、GitHub へ到達できていない可能性があります）。" >&2
  fi

  if [[ -n "$env_var" ]]; then
    # 環境変数で認証しているあいだは 'gh auth login' を案内しない。
    #
    # gh 2.96.0 で実測: 値が設定されているあいだ、gh はログインを拒否する
    # （--with-token / --web のいずれでも "The value of the <VAR> environment
    # variable is being used for authentication." で終了し、通信もしない）。
    # 危ないのはその先で、拒否メッセージ（"first clear the value from the
    # environment"）に従って値を空にしてログインすると、OAuth トークンの上限枠を
    # 1 つ消費する。上限に達していれば GitHub が既存のトークンを 1 本破棄する
    # （理由コード max_for_app）。ここで案内すると、その手順へ誘導することになる。
    echo "[on-attach] WARN: $env_var が設定されています。gh はこの値を保存済み認証より優先します。'gh auth login' は実行しないでください（gh 自身も値が設定されているあいだはログインを拒否します）。値を空にしてログインすると OAuth トークンの上限枠を 1 つ消費し、上限に達していれば他環境の認証が 1 本失効します。" >&2
    echo "[on-attach] WARN: $env_var の値（有効期限・権限・値の取り違え）と、ネットワークへ出られるかを確認してください。" >&2
  else
    echo "[on-attach] WARN: 未認証であれば、コンテナ内で 'gh auth login' を実行してください。ホストのトークンは注入されません。" >&2
  fi
}

if command -v gh >/dev/null 2>&1; then
  check_gh_auth
fi
TMPL
      ;;
    'scripts/setup-git-identity.sh')
      # identity 未指定のコミットを「黙って通す」経路を塞ぐ適用スクリプト。
      # .env の GIT_IDENTITY_NAME / GIT_IDENTITY_EMAIL を local へ適用し、global は
      # user.useConfigOnly=true + name/email 削除で無害化する。あわせて credential.helper
      # を gh へ固定し、上位スコープからの資格情報の供給を打ち切る。
      cat <<'TMPL'
#!/usr/bin/env bash
# setup-git-identity.sh — identity 未指定のコミットを「黙って通す」経路を塞ぐ
#
# 背景:
#   local 設定を持たないリポジトリは、git が黙って global の user.name/email へ
#   フォールバックしてコミットを通してしまう。リポジトリを新規作成した直後は
#   local 設定が存在しないため、そこが穴になる。これにより、別アカウントの
#   identity でコミットが main に入り、GitHub の Contributors に意図しない
#   アカウントが現れる事故が起きる。
#
#   コンテナの ~/.gitconfig は VS Code の dev.containers.copyGitConfig が
#   ホストの設定をコピーして生成する。リビルドのたびに再生成されるため、
#   一度きりの適用では戻る。接続のたびに再適用する前提で書く（on-attach から呼ぶ）。
#
#   なお .git/config (local) は workspace がホストの bind mount であるため
#   リビルドでは失われない。ここで local を扱うのは、消えた場合の復旧と、
#   このリポジトリで useConfigOnly の失敗に遭わせないための保険。
#
# 適用する内容:
#   1. global の user.name / user.email を削除する
#   2. global に user.useConfigOnly=true を立てる
#      → local 未設定のリポジトリでは commit が exit 128 で止まる。
#         黙って別名義になるより、止まって気づくほうがよい。
#   3. 当リポジトリの local へ identity を適用する
#      （.env の GIT_IDENTITY_NAME / GIT_IDENTITY_EMAIL を読む。
#       未設定なら local 適用は行わず WARN に留める）
#   4. global の credential.helper を「空 → !gh auth git-credential」に固定する
#      → 空文字を先に置くとヘルパー一覧がリセットされ、/etc/gitconfig 側や
#         エディタが注入したヘルパーが応答しなくなる。資格情報の供給元を
#         コンテナ内の gh だけに絞る。
#
# GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL という名前を .env に使わないのは、それが git 自身の
# 読む環境変数だから。環境に置くと local 未設定のリポジトリでも identity が解決でき、
# user.useConfigOnly による保護が無効になる（このガードが塞ぎたい穴そのもの）。
#
# このスクリプトは git config だけを触り、gh を呼ばない。接続のたびにネットワークを
# 叩くのは重く、オフラインでは失敗するため。認証（gh へのログイン）はコンテナ内で
# 利用者が明示的に行う。
#
# 使い方:
#   bash scripts/setup-git-identity.sh            # 適用
#   bash scripts/setup-git-identity.sh --check    # 検証
#
#   --check は「適用をもう一度実行して状態が変化しないこと」も併せて検証する
#   （冪等性と、credential セクションを壊していないことの確認を兼ねる）。
#
# 終了コード:
#   0 = IDENTITY_SETUP_OK / 1 = IDENTITY_SETUP_FAIL
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

# identity の供給元はプロジェクト .env に一本化する。on-attach から呼ばれる文脈では
# 対話シェルの rc は効かないため、ここで明示的にローダーを通す（存在しなければ素通り）。
NAME_VAR="GIT_IDENTITY_NAME"
EMAIL_VAR="GIT_IDENTITY_EMAIL"
if [[ -f "$HERE/load-project-env.sh" ]]; then
  # shellcheck source=/dev/null
  . "$HERE/load-project-env.sh"
fi
EXPECTED_NAME="${GIT_IDENTITY_NAME:-}"
EXPECTED_EMAIL="${GIT_IDENTITY_EMAIL:-}"

log() { echo "[git-identity] $*"; }
err() { echo "[git-identity] $*" >&2; }

# 一時ファイルはスクリプトスコープで持ち、EXIT で片付ける。
# RETURN トラップにすると main の復帰時にも発火し、local が解放済みの状態で
# 参照して set -u に殺される。
SNAPSHOT=""
TMP_SNAPSHOT=""
TMP_REPO=""
cleanup() {
  [[ -n "$SNAPSHOT" ]] && rm -f "$SNAPSHOT"
  [[ -n "$TMP_SNAPSHOT" ]] && rm -f "$TMP_SNAPSHOT"
  [[ -n "$TMP_REPO" ]] && rm -rf "$TMP_REPO"
  return 0
}
trap cleanup EXIT

# git が実際に書き込む global 設定ファイルの実体を git 自身に問い合わせる。
# ~/.gitconfig と XDG 配下のどちらが使われるかは環境で変わるため、決め打ちしない。
resolve_global_config() {
  local origin
  origin="$(git config --global --show-origin --get user.useConfigOnly 2>/dev/null | head -1 || true)"
  if [[ "$origin" == file:* ]]; then
    origin="${origin#file:}"
    printf '%s' "${origin%%$'\t'*}"
    return 0
  fi
  printf '%s' "${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}"
}

# 失敗は必ず return 1 で返す。
# この関数は `if ! apply` の条件文脈から呼ばれることがあり、その中では set -e が
# 無効化される。書き込み失敗を素通りさせると最後の log の終了コード 0 が返り、
# 「適用できていないのに成功」と報告してしまう。

# global の identity キーを削除する。--unset-all は該当キーが無いと exit 5 を返す
# （未設定は正常系）。それ以外の非ゼロは書き込み失敗として扱い、さらに削除後に
# 実際に空になったことを確認する。ここを `|| true` で握りつぶすと、権限・書き込み
# 失敗で削除できていないのに成功扱いになり得る。useConfigOnly=true 下でも明示設定
# された global identity は使われるため、残存すると local 未設定リポジトリで黙って
# 別名義コミットが通る（このガードが防ぎたい事故そのもの）。
unset_global_identity_key() {
  local key="$1" rc=0
  git config --global --unset-all "$key" || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 5 ]]; then
    err "ERROR: global の $key を削除できません (exit $rc)"
    return 1
  fi
  if [[ -n "$(git config --global --get "$key" 2>/dev/null || true)" ]]; then
    err "ERROR: global の $key が削除後も残っています"
    return 1
  fi
  return 0
}

# 資格情報の供給元を gh に絞る。
#
# git はヘルパーを定義順に試し、最初に応答したものを採用する。空文字を置くと
# それまでの一覧が破棄されるため、「空 → gh」の順で global に固定すると、
# /etc/gitconfig（system）側やエディタが注入したヘルパーが応答しなくなる。
# ここが緩いと、ホスト由来の資格情報が git credential fill から警告なく返る。
CRED_HELPER_GH='!gh auth git-credential'
pin_credential_helper() {
  local current
  current="$(git config --global --get-all credential.helper 2>/dev/null | tr '\n' '|' || true)"
  if [[ "$current" == "|${CRED_HELPER_GH}|" ]]; then
    return 0
  fi
  # --unset-all は該当キーが無いと exit 5 を返す（未設定は正常系）。
  local rc=0
  git config --global --unset-all credential.helper || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 5 ]]; then
    err "ERROR: global の credential.helper を削除できません (exit $rc)"
    return 1
  fi
  if ! git config --global --add credential.helper '' ||
    ! git config --global --add credential.helper "$CRED_HELPER_GH"; then
    err "ERROR: global の credential.helper を固定できません"
    return 1
  fi
  log "credential.helper を「空 → gh」に固定しました"
  return 0
}

apply() {
  # global の user.name / user.email を確実に削除する（削除失敗・残存を見逃さない）。
  if ! unset_global_identity_key user.name || ! unset_global_identity_key user.email; then
    return 1
  fi

  if ! git config --global user.useConfigOnly true; then
    err "ERROR: global 設定に user.useConfigOnly を書き込めません"
    return 1
  fi

  if ! pin_credential_helper; then
    return 1
  fi

  if [[ -n "$EXPECTED_NAME" && -n "$EXPECTED_EMAIL" ]]; then
    if ! git config --local user.name "$EXPECTED_NAME" ||
      ! git config --local user.email "$EXPECTED_EMAIL"; then
      err "ERROR: local 設定に identity を書き込めません"
      return 1
    fi
    log "local identity: $EXPECTED_NAME <$EXPECTED_EMAIL>"
  else
    # ここで落とさない。global の無害化は済んでおり、identity 未設定のまま
    # コミットしようとすれば git 自身が exit 128 で止める。
    err "WARN: $NAME_VAR / $EMAIL_VAR が未設定のため local identity を適用しません。"
    err "WARN: このリポジトリでコミットする前に、プロジェクトルートの .env へ設定してください:"
    err "WARN:   $NAME_VAR=<name>"
    err "WARN:   $EMAIL_VAR=<email>"
    err "WARN: 雛形は .env.example にあります。"
  fi

  log "global identity を無効化し user.useConfigOnly=true を設定しました"
}

# 期待どおりに identity が解決できない状態を作って、git が止まることを確かめる。
# GIT_AUTHOR_* / EMAIL が環境にあると git はそれを使うため、判定から除外する。
git_ident_without_env() {
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
      -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      -u EMAIL \
      git "$@"
}

check() {
  local failures=0
  local global_config ident

  global_config="$(resolve_global_config)"

  # 状態の検査を先に行う。適用を先に走らせると「未適用」を検出できなくなるため、
  # 冪等性の検査（apply を伴う）は最後に置く。
  SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/dcb-git-identity-snapshot.XXXXXX")"
  TMP_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/dcb-git-identity-snapshot.XXXXXX")"
  cp "$global_config" "$SNAPSHOT" 2>/dev/null || : >"$SNAPSHOT"

  # 1) global に identity が残っていないこと。
  if [[ -z "$(git config --global --get user.name || true)" ]]; then
    log "OK  global user.name は未設定"
  else
    err "NG  global user.name が残っている: $(git config --global --get user.name)"
    failures=$((failures + 1))
  fi
  if [[ -z "$(git config --global --get user.email || true)" ]]; then
    log "OK  global user.email は未設定"
  else
    err "NG  global user.email が残っている: $(git config --global --get user.email)"
    failures=$((failures + 1))
  fi

  # 2) 未指定コミットを失敗させる設定が効いていること。
  if [[ "$(git config --global --get user.useConfigOnly || true)" == "true" ]]; then
    log "OK  user.useConfigOnly=true"
  else
    err "NG  user.useConfigOnly が true でない"
    failures=$((failures + 1))
  fi

  # 3) 当リポジトリの local identity。
  if [[ -n "$EXPECTED_EMAIL" ]]; then
    if [[ "$(git config --local --get user.email || true)" == "$EXPECTED_EMAIL" ]]; then
      log "OK  local user.email = $EXPECTED_EMAIL"
    else
      err "NG  local user.email が $EXPECTED_EMAIL でない: $(git config --local --get user.email || echo '<unset>')"
      failures=$((failures + 1))
    fi
  else
    log "SKIP $EMAIL_VAR 未設定のため local identity の検査を省略"
  fi

  # 4) 当リポジトリでは identity が解決できること。
  if ident="$(git_ident_without_env var GIT_AUTHOR_IDENT 2>/dev/null)"; then
    log "OK  当リポジトリの author: ${ident% * *}"
  else
    if [[ -n "$EXPECTED_EMAIL" ]]; then
      err "NG  当リポジトリで author identity を解決できない"
      failures=$((failures + 1))
    else
      log "SKIP local identity 未適用のため author 解決の検査を省略"
    fi
  fi

  # 5) local 設定を持たないリポジトリでは identity 解決が失敗すること。
  #    これが本題。黙って global へ落ちないことを確かめる。
  TMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/dcb-git-identity-repo.XXXXXX")"
  git init -q "$TMP_REPO"
  if (cd "$TMP_REPO" && git_ident_without_env var GIT_AUTHOR_IDENT >/dev/null 2>&1); then
    err "NG  local 未設定のリポジトリで author identity が解決できてしまう"
    err "NG  → 未設定のままコミットが通る。黙ったフォールバックが塞がっていない。"
    failures=$((failures + 1))
  else
    log "OK  local 未設定のリポジトリでは author identity 解決が失敗する"
  fi
  rm -rf "$TMP_REPO"
  TMP_REPO=""

  # 6) global の credential.helper が「空 → gh」に固定されていること。
  #    空文字が先頭に無いと、system（/etc/gitconfig）側のヘルパーが先に応答し、
  #    ホスト由来の資格情報が返り得る。
  local helpers
  helpers="$(git config --global --get-all credential.helper 2>/dev/null | tr '\n' '|' || true)"
  if [[ "$helpers" == "|${CRED_HELPER_GH}|" ]]; then
    log "OK  global credential.helper は「空 → gh」"
  else
    err "NG  global credential.helper が「空 → gh」でない: ${helpers:-<unset>}"
    failures=$((failures + 1))
  fi

  # 7) local 設定を持たないリポジトリで、資格情報の供給元が gh だけであること。
  #    ここが本題。設定を持たない新規リポジトリでも、上位スコープのヘルパーが
  #    生き残っていないことを、実際に一時リポジトリを作って確かめる。
  #    git は空文字で一覧をリセットするため、最後の空要素より後ろだけが実効値になる。
  TMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/dcb-git-identity-repo.XXXXXX")"
  git init -q "$TMP_REPO"
  local effective
  # 末尾の `|| true` は if-then-else の代用（A && B || C）ではない。ヘルパーが
  # 1 件も無ければ git config が非ゼロを返すため、空文字を得るための既定値として
  # 置いている。A が真でも C が走ってよく、set -e 下で検査自体を落とさないための
  # ものなので、SC2015 の想定する誤用には当たらない。
  # shellcheck disable=SC2015
  effective="$(cd "$TMP_REPO" && git config --get-all credential.helper 2>/dev/null \
    | awk '$0 == "" { n = 0; next } { v[++n] = $0 } END { for (i = 1; i <= n; i++) print v[i] }' \
    | tr '\n' '|' || true)"
  if [[ "$effective" == "${CRED_HELPER_GH}|" ]]; then
    log "OK  local 未設定のリポジトリでも資格情報の供給元は gh のみ"
  else
    err "NG  local 未設定のリポジトリで gh 以外の供給元が残っている: ${effective:-<none>}"
    err "NG  → ホスト由来の資格情報が git credential fill から返り得る。"
    failures=$((failures + 1))
  fi
  rm -rf "$TMP_REPO"
  TMP_REPO=""

  # 7.5) system スコープ（/etc/gitconfig 等）に置かれた credential.helper を
  #      可視化する。判定には影響させない。
  #
  #      6) は global、7) は実効値しか見ないため、system に何が置かれていても
  #      どちらの出力にも現れない。遮断そのものは成立している（global 先頭の
  #      空文字が一覧をリセットするため system の helper は実効値から外れ、
  #      それは 7) が一時リポジトリで実測済み）。ここで見たいのは遮断の可否では
  #      なく、「自分たちが置いた覚えのないヘルパーが system にある」という
  #      事実そのもの。
  #
  #      分かるのは存在の有無だけで、誰がいつ置いたかはこの検査から判定できない。
  #      そのため出力は「検出」に留め、原因を断定しない。
  #
  #      失敗させない理由: 置く側が接続のたびに書き戻す構成では常時検出され
  #      続けるため、失敗にすると常時赤になる。恒常的な赤は「赤を無視する習慣」
  #      を生み、警告より悪い状態を作る。判定は変えず事実だけを出す。
  #
  #      プレフィクスは log に一元化する（直書きすると log の書式を変えたときに
  #      この行だけが取り残される）。
  #
  #      検出は 1 つの文字列の空判定ではなく、行数で数える。`helper = `（空文字）
  #      だけが置かれている場合、--get-all は空行 1 件を返すが、コマンド置換は
  #      末尾改行を落とすため「1 件ある」と「0 件」が区別できない。キーがあるのに
  #      「無い」と報告するのは、この検査が唯一報告すべきことを取り違えた状態。
  local -a system_helpers=()
  local system_helper
  # git config は該当キーが無いと非ゼロを返す（未設定は正常系）。ここは検出の
  # 有無を見るだけなので、空として受け取る（set -e 下で検査自体を落とさないため）。
  while IFS= read -r system_helper; do
    system_helpers+=("$system_helper")
  done < <(git config --system --get-all credential.helper 2>/dev/null || true)
  if [[ "${#system_helpers[@]}" -gt 0 ]]; then
    log "INFO system スコープに credential.helper があります（実効値からは外れています。上記 7) を参照）:"
    for system_helper in "${system_helpers[@]}"; do
      log "INFO   ${system_helper:-<空文字>}"
    done
    log "INFO 誰がいつ置いたかはこの検査では判定できません。検出のみで、判定には影響させません。"
  else
    log "OK  system スコープに credential.helper は無い"
  fi

  # 8) 冪等性。
  #    適用をもう一度走らせ、global 設定ファイルが 1 バイトも変わらないことを見る。
  #
  #    この検査は apply を伴う。未適用の状態で走らせると「失敗を報告しながら
  #    裏で直してしまう」ことになり、次回の --check が通って問題が見えなくなる。
  #    先行する検査が落ちている場合は、意味を持たないので実行しない。
  if [[ "$failures" -gt 0 ]]; then
    log "SKIP 冪等性検査（先行する検査が失敗しているため。まず適用してください）"
  else
    # apply の失敗を握りつぶすと、何も書き換わらないので cmp が一致し、
    # 「再適用できないのに冪等 OK」という誤った判定になる。失敗は失敗として扱う。
    if ! apply >/dev/null 2>&1; then
      err "NG  再適用に失敗した（apply が非ゼロ終了）"
      failures=$((failures + 1))
    else
      cp "$global_config" "$TMP_SNAPSHOT" 2>/dev/null || : >"$TMP_SNAPSHOT"
      if cmp -s "$SNAPSHOT" "$TMP_SNAPSHOT"; then
        log "OK  冪等: 再適用で $global_config は変化しない（credential セクションを含む）"
      else
        err "NG  冪等性なし: 再適用で $global_config が変化した"
        diff -u "$SNAPSHOT" "$TMP_SNAPSHOT" >&2 || true
        failures=$((failures + 1))
      fi
    fi
  fi

  if [[ "$failures" -gt 0 ]]; then
    err "$failures 件の検査に失敗しました。"
    echo "IDENTITY_SETUP_FAIL"
    return 1
  fi

  echo "IDENTITY_SETUP_OK"
  return 0
}

main() {
  case "${1-}" in
    --check) check ;;
    "") apply ;;
    -h | --help)
      # 先頭コメントブロックをそのままヘルプとして出す（行番号を決め打ちしない）。
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
      ;;
    *)
      err "error: unknown option: $1"
      exit 1
      ;;
  esac
}

main "$@"
TMPL
      ;;
    'scripts/verify-commit-identity.sh')
      # コミット履歴の identity 検証ゲート。CI（identity-guard.yml）と手元で共用する。
      # author は email のみで判定。許可 email は env ALLOWED_AUTHOR_EMAILS（CI は
      # リポジトリ変数から渡す）→ 無ければ .env の GIT_IDENTITY_EMAIL の順で解決する。
      cat <<'TMPL'
#!/usr/bin/env bash
# verify-commit-identity.sh — コミット identity の検証ゲート
#
# コミットの author / committer / Co-Authored-By に、許可外の identity が
# 混入していないことを検証する。GitHub の Contributors は既定ブランチの
# コミット author（email）で集計されるため、email で判定する。
#
# 背景:
#   git identity の適用漏れにより、別アカウントの identity のコミットが
#   main に直接入り、Contributors に意図しないアカウントが現れる事故が起きる。
#   setup-git-identity.sh が適用漏れ（穴）を塞ぎ、このスクリプトが検知層になる。
#
# 名前ではなく email のみで判定する:
#   同じアカウントでも表記が揺れる（ローカル profile と GitHub の squash merge で
#   name が異なる）。名前で判定すると表記揺れで落ちるだけで、アカウントの
#   取り違えは防げない。
#
# 許可 email の与え方:
#   author の許可 email は次の順で解決する。固有 email はスクリプトに焼き込まない。
#     1. 環境変数 ALLOWED_AUTHOR_EMAILS（カンマ/空白区切り）。
#        CI はリポジトリ変数（vars.ALLOWED_AUTHOR_EMAILS）を env 経由で渡す。
#     2. 未設定なら .env の GIT_IDENTITY_EMAIL（コンテナ内の唯一の供給元）。
#   どちらでも解決できなければ「検査対象が無いので通過」にせず、fail-closed で落とす。
#   committer には常に noreply@github.com を、Co-Authored-By には加えて
#   noreply@anthropic.com を許可する（GitHub 上の squash merge / web UI コミットの
#   committer、および AI コーディング規約の trailer に対応）。
#
# 使い方:
#   bash scripts/verify-commit-identity.sh                # origin/main..HEAD
#   bash scripts/verify-commit-identity.sh <range>        # 任意の範囲
#   bash scripts/verify-commit-identity.sh --full         # HEAD の全履歴
#
# --full は HEAD の全履歴であって git rev-list --all ではない。--all は
# refs/original/（filter-branch のバックアップ）や全 remote-tracking ブランチ
# まで拾い、検査対象がチェックアウト環境ごとにぶれる。
#
# 終了コード:
#   0 = IDENTITY_PASS（許可外の identity なし）
#   1 = IDENTITY_FAIL（許可外の identity を検出、または範囲/許可 email が解決できない）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

ALLOWED_AUTHOR_EMAILS_ARR=()
ALLOWED_COMMITTER_EMAILS_ARR=()
ALLOWED_COAUTHOR_EMAILS_ARR=()

# author の許可 email を解決する。env ALLOWED_AUTHOR_EMAILS を最優先し、
# 無ければ .env の GIT_IDENTITY_EMAIL を使う（CI では .env が無いため前者だけが効く）。
resolve_allowed_author_emails() {
  local raw="${ALLOWED_AUTHOR_EMAILS:-}"
  if [[ -z "$raw" ]]; then
    # 環境に値があっても必ずローダーを通す。load-project-env.sh は .env を後勝ちで
    # 上書きする契約であり、「.env が唯一の供給元」を保つには常に通す必要がある。
    # 未設定のときだけ読むと、シェルへ手で export した古い値が .env に勝つ。
    if [[ -f "$HERE/load-project-env.sh" ]]; then
      # shellcheck source=/dev/null
      . "$HERE/load-project-env.sh"
    fi
    raw="${GIT_IDENTITY_EMAIL:-}"
  fi
  # カンマ区切りも空白区切りも受ける。
  printf '%s' "${raw//,/ }"
}

init_allowlists() {
  local resolved
  resolved="$(resolve_allowed_author_emails)"
  # 単語分割だけを行い、パス名展開は行わせない。クォートなしの配列代入
  # （ARR=($resolved)）は分割と同時に glob 展開もするため、許可 email に
  # '*' や '?' が含まれると、許可リストが「検査対象リポジトリにどのファイルが
  # 存在するか」で変わる。検知層の判定が検査対象の中身に左右されるのは、
  # fail-closed 設計の意味を失わせる。here-string は末尾に改行を付けるので
  # set -e 下でも read は 0 を返し、空文字なら空配列になって下の検査に落ちる。
  read -r -a ALLOWED_AUTHOR_EMAILS_ARR <<<"$resolved"

  if [[ "${#ALLOWED_AUTHOR_EMAILS_ARR[@]}" -eq 0 ]]; then
    echo "[identity] 許可 author email が解決できません。" >&2
    echo "[identity] CI はリポジトリ変数 ALLOWED_AUTHOR_EMAILS を、コンテナは .env の GIT_IDENTITY_EMAIL を設定してください。" >&2
    echo "IDENTITY_FAIL"
    exit 1
  fi

  # committer は squash merge / web UI の noreply@github.com を許可。
  ALLOWED_COMMITTER_EMAILS_ARR=("${ALLOWED_AUTHOR_EMAILS_ARR[@]}" "noreply@github.com")
  # Co-Authored-By は加えて AI コーディング規約の trailer を許可。
  ALLOWED_COAUTHOR_EMAILS_ARR=("${ALLOWED_AUTHOR_EMAILS_ARR[@]}" "noreply@github.com" "noreply@anthropic.com")
}

# 許可エントリは既定で完全一致。加えて "@example.com" / "*@example.com" の形だけを
# ドメイン一括許可として解釈する。
#
# ドメイン形に限定するのは、任意の glob を許すと設定ミスの '*' 1 文字で全 email が
# 通り、検知層が黙って無効化されるため。形を限定しておけば、書き間違えても影響範囲は
# そのドメインに閉じる。'*' 単体はどちらの形にも当たらず、何も許可しない。
#
# 大文字小文字は区別する（既存の完全一致と同じ扱い）。git の email は通常小文字で、
# ここだけ緩めると判定基準が 2 種類になる。
is_allowed() {
  local needle="$1"
  shift
  local candidate domain
  for candidate in "$@"; do
    [[ "$needle" == "$candidate" ]] && return 0

    case "$candidate" in
      '*@'*) domain="${candidate#\*}" ;;
      '@'*)  domain="$candidate" ;;
      *)     continue ;;
    esac
    # ローカル部が 1 文字以上あることを要求する。"@example.com" という email
    # そのものを許可しないため。
    #
    # あわせてローカル部に @ が無いことを要求する。末尾一致だけで見ると
    # "attacker@untrusted.com@example.com" のような @ を 2 つ持つ email が
    # 通る。git は author email を検証しないため、この形は実際に作れる。
    [[ "$needle" == ?*"$domain" && "${needle%"$domain"}" != *@* ]] && return 0
  done
  return 1
}

# GitHub 上の操作（PR のマージ、web UI での編集）で作られたコミットかを判定する。
#
# GitHub 側で「メールアドレスを非公開にする」を有効にしていると、これらのコミットの
# author は <login>@users.noreply.github.com（または <id>+<login>@...）になる。
# committer は常に noreply@github.com。ローカルの identity 適用漏れとは発生経路が
# 別で、許可リストに個別の email を足して回っても、メンバーが増えるたびに同じ穴が開く。
#
# 許可は「committer が noreply@github.com であること」に縛る。GitHub 自身が作成した
# コミットに限定され、ローカルで作ったコミットには適用されない。
#
# トレードオフ: リポジトリへの書き込み権限を持つアカウントであれば、その GitHub
# アカウントが Contributors に現れることを許容する。この検知層が塞ぐのはローカルの
# identity 適用漏れ（別アカウントの個人 email の混入）であり、誰に書き込み権限を
# 与えるかはリポジトリ側の責務として切り分ける。
is_github_authored() {
  local author="$1" committer="$2"
  [[ "$committer" == "noreply@github.com" ]] || return 1
  # ローカル部が 1 文字以上あり、かつ @ を含まないことを要求する（ドメイン許可と
  # 同じ判定。末尾一致だけだと x@evil.com@users.noreply.github.com が通る）。
  [[ "$author" == ?*"@users.noreply.github.com" ]] || return 1
  [[ "${author%"@users.noreply.github.com"}" != *@* ]] || return 1
  return 0
}

resolve_range() {
  local arg="${1-}"

  if [[ "$arg" == "--full" ]]; then
    printf '%s' "HEAD"
    return 0
  fi

  if [[ -n "$arg" ]]; then
    printf '%s' "$arg"
    return 0
  fi

  # 既定は origin/main からの差分。取得できない場合のみ全履歴へ落とす。
  # 「範囲が解決できないので何も検査しない」を通過扱いにしない。
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    printf '%s' "origin/main..HEAD"
    return 0
  fi

  printf '%s' "HEAD"
}

main() {
  init_allowlists

  local range
  range="$(resolve_range "${1-}")"

  # 全コミットを git log 1 回で取り出す。コミットごとにプロセスを起動すると、
  # main への全履歴検査が履歴の長さに比例して遅くなり、いずれ CI が
  # タイムアウトする。
  #
  # レコード区切りは制御文字を使う。コミットメッセージの subject や
  # co-author 名に現れないため、区切り文字の衝突を考えなくてよい。
  #   \x1d = レコード終端 / \x1f = フィールド区切り / \x1e = co-author 区切り
  local fmt='%H%x1f%ae%x1f%ce%x1f%s%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x1e)%x1d'

  local records
  if ! records="$(git log --format="$fmt" "$range" 2>/dev/null)"; then
    echo "[identity] 範囲を解決できません: $range" >&2
    echo "IDENTITY_FAIL"
    exit 1
  fi

  if [[ -z "$records" ]]; then
    echo "[identity] 検査対象のコミットがありません（範囲: $range）"
    echo "IDENTITY_PASS"
    exit 0
  fi

  local checked=0
  local violations=0
  local record sha author_email committer_email subject coauthors
  local coauthor coauthor_email

  while IFS= read -r -d $'\x1d' record; do
    # git log はコミットごとに改行を挟むため、レコード先頭の改行を落とす。
    record="${record#$'\n'}"
    [[ -n "$record" ]] || continue
    checked=$((checked + 1))

    IFS=$'\x1f' read -r sha author_email committer_email subject coauthors <<<"$record"

    if ! is_allowed "$author_email" "${ALLOWED_AUTHOR_EMAILS_ARR[@]}" \
      && ! is_github_authored "$author_email" "$committer_email"; then
      echo "[identity] NG ${sha:0:8} author=<${author_email}> — ${subject}" >&2
      violations=$((violations + 1))
    fi

    if ! is_allowed "$committer_email" "${ALLOWED_COMMITTER_EMAILS_ARR[@]}"; then
      echo "[identity] NG ${sha:0:8} committer=<${committer_email}> — ${subject}" >&2
      violations=$((violations + 1))
    fi

    # co-author が無いコミットが大半なので、空なら走査自体を飛ばす。
    # ヒアストリングは末尾に改行を足すため、素通しすると空文字が
    # 「不正形式の co-author 行」として誤検出される。
    [[ -n "${coauthors//[[:space:]]/}" ]] || continue

    while IFS= read -r -d $'\x1e' coauthor || [[ -n "$coauthor" ]]; do
      # 前後の空白（ヒアストリング由来の改行を含む）を落とす。
      coauthor="${coauthor#"${coauthor%%[![:space:]]*}"}"
      coauthor="${coauthor%"${coauthor##*[![:space:]]}"}"
      [[ -n "$coauthor" ]] || continue
      # "Name <email>" から email を取り出す。<> が無い行は不正形式として弾く。
      if [[ "$coauthor" != *"<"*">"* ]]; then
        echo "[identity] NG ${sha:0:8} co-author 行が不正形式です: ${coauthor}" >&2
        violations=$((violations + 1))
        continue
      fi
      coauthor_email="${coauthor##*<}"
      coauthor_email="${coauthor_email%>*}"
      if ! is_allowed "$coauthor_email" "${ALLOWED_COAUTHOR_EMAILS_ARR[@]}"; then
        echo "[identity] NG ${sha:0:8} co-author=<${coauthor_email}> — ${subject}" >&2
        violations=$((violations + 1))
      fi
    done <<<"$coauthors"
  done <<<"$records"

  echo "[identity] 検査したコミット: ${checked}（範囲: ${range}）"

  if [[ "$violations" -gt 0 ]]; then
    echo "[identity] 許可外の identity を ${violations} 件検出しました。" >&2
    echo "[identity] 対処: bash scripts/setup-git-identity.sh で local identity を適用し、" >&2
    echo "[identity] 該当コミットを git rebase で author ごと作り直してください。" >&2
    echo "IDENTITY_FAIL"
    exit 1
  fi

  echo "IDENTITY_PASS"
  exit 0
}

main "$@"
TMPL
      ;;
    'scripts/post-rebuild-check.sh')
      # 基本コマンド + 選択言語（__RUNTIME_CHECK_LINES__）+ 選択装備
      # （__WITH_CHECK_LINES__: 選択した cloud/AI ツールの CLI）+ 永続 volume の
      # 実マウント（__VOLUME_CHECK_LINES__）を検査する。
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] bootstrap checks"
for cmd in bash jq gh docker rg; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done

# 認証状態を保持するディレクトリが named volume として実際にマウントされているかを見る。
# 定義したのにマウントされていない状態（compose の編集ミス、devcontainer.json が別
# サービスを指している等）は、CLI が入っていて動くぶん気づきにくく、rebuild のたびに
# 静かにログインが消える形で表面化する。
#
# /proc/mounts を引くのは、mountpoint コマンドが無いベースイメージがあるため。
# 判定できない環境（/proc/mounts を読めない等）は「不明」として素通りさせる。
check_mounted() {
  local dir="$1" vol="$2"
  if [[ ! -r /proc/mounts ]]; then
    echo "[check] $vol unknown (cannot read /proc/mounts)"
    return 0
  fi
  if awk -v d="$dir" '$2 == d { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts; then
    echo "[check] $vol mounted at $dir"
  else
    echo "[check] WARN: $vol not mounted at $dir (認証状態は rebuild で失われます)" >&2
  fi
}
__VOLUME_CHECK_LINES__
__RUNTIME_CHECK_LINES__
__WITH_CHECK_LINES__
TMPL
      ;;
    'scripts/verify.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# verify.sh — ループコーディングの接地信号（受け入れ条件の機械ゲート）
#
# プロジェクトが宣言した受け入れ条件（acceptance）を非対話で実行し、
# 一意な通過信号を返す。AI エージェントの反復（実装 → 検証 → 修正 → …）が
# 「緑」を判定するための、迂回できない決定的な信号を供給する。
#
# このスクリプトは単体で動作し、外部パッケージの導入を前提にしない。
#
# 使い方:
#   bash scripts/verify.sh
#
# 受け入れ条件の定義:
#   既定で scripts/acceptance.sh を実行する。VERIFY_ACCEPTANCE で差し替え可能。
#
# 規範由来の検査:
#   受け入れ条件の手前で scripts/check-no-secrets.sh（機密混入検査）を実行する。
#   acceptance.sh 側へ置かないのは、あちらがプロジェクトの所有物で、受け入れ条件を
#   書き足すたびに触られるため。規範由来の検査をそこへ置くと消える経路ができる。
#   不在なら失敗させる（検査が成立していないことを合格にしない）。
#
# 終了コード:
#   0 = VERIFY_PASS（受け入れ条件を満たす）
#   1 = VERIFY_FAIL（未達、受け入れ条件が未定義、または機密の混入）
set -euo pipefail

# 受け入れ検証とテストコマンド（package.json / go.mod / Cargo.toml 等の検出）は
# プロジェクトルート基準で実行する。scripts/ は生成先プロジェクト直下にあるため、
# スクリプト位置の 1 階層上がルート。任意の作業ディレクトリから起動しても不変にする。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

ACCEPTANCE="${VERIFY_ACCEPTANCE:-scripts/acceptance.sh}"

if [[ ! -f "$ACCEPTANCE" ]]; then
  echo "[verify] acceptance not found: $ACCEPTANCE" >&2
  echo "[verify] 受け入れ条件が未定義です。実行可能な検証を用意してください。" >&2
  echo "VERIFY_FAIL"
  exit 1
fi

# 機密混入検査。受け入れ条件より前に置く。機密が混入した状態で長い受け入れ検証を
# 回しても直すべきことは変わらないため、安い検査から落として反復を短くする。
SECRETS_CHECK="$HERE/check-no-secrets.sh"

if [[ ! -f "$SECRETS_CHECK" ]]; then
  echo "[verify] secret scan not found: $SECRETS_CHECK" >&2
  echo "[verify] 機密混入検査が配置されていません。検査が成立しないため失敗させます。" >&2
  echo "VERIFY_FAIL"
  exit 1
fi

echo "[verify] running secret scan: scripts/check-no-secrets.sh"
if ! bash "$SECRETS_CHECK"; then
  echo "[verify] 機密混入検査に失敗しました" >&2
  echo "VERIFY_FAIL"
  exit 1
fi

echo "[verify] running acceptance: $ACCEPTANCE"
if bash "$ACCEPTANCE"; then
  echo "VERIFY_PASS"
  exit 0
fi

echo "[verify] acceptance not satisfied" >&2
echo "VERIFY_FAIL"
exit 1
TMPL
      ;;
    'scripts/check-no-secrets.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# check-no-secrets.sh — 機密混入の検知ゲート（共通規範「機密をコミットしない」の機械化）
#
# 位置づけ:
#   判定はこのスクリプトが持ち、scripts/verify.sh と CI は呼ぶだけ。
#   scripts/verify-commit-identity.sh と同じ形にそろえる。
#
#   受け入れ条件の雛形（scripts/acceptance.sh）へ書かない理由: あちらは
#   プロジェクトが所有・編集する設計であり、受け入れ条件を書き足すたびに触られる。
#   規範由来の検査をそこへ置くと、書き換えのたびに検査が消える経路ができる。
#   verify.sh から直接呼べば、その経路を作らずに済む。
#
# 検査は 4 つ:
#
#   1. 追跡前（git status --porcelain -z）
#      追跡対象へ入る「前」に落とす。誤ってコミットしてからでは、削除コミットでは
#      漏洩は解消しない（履歴からの除去と、当該資格情報の失効・再発行が必要になる）。
#      列挙は NUL 区切り（#263）。パス名に改行を含むファイルも 1 レコードのまま
#      崩れずに読める（後述）。
#
#   2. 追跡済み（git ls-files -z）
#      CI で落とす。checkout 直後の作業ツリーはクリーンで 1. の出力が空になるため、
#      追跡前の検査だけでは CI は「何も検査していない状態」で合格する。CI が
#      本来捕まえたいのは機密を含んだままの PR、すなわち追跡済みの状態である。
#      両方あって初めて、どちらの経路でも機密が既定ブランチへ入らない。
#      こちらも列挙は NUL 区切り（#263）。
#
#   3. .env.example に機密の値が入っていないこと
#      機密でない設定既定値は共有する意味があるため、キー名で対象を絞る。
#
#   4. .env と .env.example のキー整合
#      .env が唯一の供給元で、.env.example はその雛形。
#
# 検査が成立していないことを合格にしない:
#   git 管理外での実行、git コマンド自体の失敗、追跡ファイル 0 件は、いずれも
#   「機密が無い」ことを意味しない。空の出力を「該当なし」と読むと、検査して
#   いないのに合格になる。これらはすべて失敗として扱う。
#
# 出力に機密の値を出さない:
#   検出時に出すのはパスとキー名だけで、値は決して出力しない（共通規範
#   「ログ・issue 本文・相談記録・PR 説明に機密を含めない」）。
#
# 終了コード:
#   0 = SECRETS_PASS
#   1 = SECRETS_FAIL（機密の混入、または検査が成立しなかった）
set -euo pipefail

# ロケールを C に固定する。
#
# #263 以前は「判定の解析」（追跡前が git add --dry-run の人間向け出力
# add '<path>' を解析していたため、翻訳されるとパターンに一致しなくなる）も
# 固定の理由だった。追跡前・追跡済みとも git status --porcelain -z /
# git ls-files -z の機械可読出力（ステータス文字とパスのみで、翻訳される
# メッセージ文字列を含まない）へ置き換えたため、この理由は無くなった
# （依存を外したのでここに書く）。
#
# 残る理由（並びの比較）: キー整合は sort / comm で集合差を取る。GNU sort の照合順は
#   ロケールで変わり（実測: C では MYVAR < MY_VAR、en_US.utf8 では MY_VAR < MYVAR）、
#   両辺が別の照合順で並ぶと comm は "not in sorted order" を警告しつつ終了コード 0 を
#   返し、誤った差集合をそのまま使わせる（実測: 存在しないキー AB が片側だけに
#   あると報告された）。両辺を同じ照合順に固定して依存そのものを切る。
export LC_ALL=C

# 検査はプロジェクトルート基準で行う。scripts/ は生成先プロジェクト直下にあるため、
# スクリプト位置の 1 階層上がルート。任意の作業ディレクトリから起動しても不変にする。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

ENV_EXAMPLE=".env.example"
LOADER="$HERE/load-project-env.sh"

VIOLATIONS=0

ng() {
  printf '[secrets] NG %s\n' "$1" >&2
  VIOLATIONS=$((VIOLATIONS + 1))
}

fatal() {
  printf '[secrets] %s\n' "$1" >&2
  echo "SECRETS_FAIL"
  exit 1
}

# git コマンドの stderr を一時退避する。追跡前 / 追跡済みのどちらの経路も、この
# 検査の主題は「検査が成立していないことを合格にしない」ことであり、成立しなかった
# 理由（index の破損・権限・パスの問題など）が読めないと主題と噛み合わない。
#
# 一方でこれらの git コマンドは成功時にも警告（embedded git repository・改行コード
# 等）を出しうるため、常時 stderr をそのまま出すと通常運用で毎回ノイズが出る。それは
# 「赤を無視する習慣」を作る経路であり、出力そのものが読まれなくなる。そのため
# 一時ファイルへ落とし、失敗したときだけ見せる。
#
# mktemp はテンプレート付きで呼ぶ。$$ 由来の予測可能な名前は使わない（同名を先に
# 置かれると書き込み先を乗っ取られる）。後始末は EXIT トラップで行う（この
# スクリプトはここより前で trap を張っていない）。
#
# GIT_STDERR に加え、追跡前 / 追跡済みそれぞれの列挙（NUL 区切り）も一時ファイルへ
# 落とす。bash の変数（"$(...)" によるコマンド置換）は NUL バイトを保持できず、
# 埋め込まれた NUL がそのまま消えてしまう（末尾の改行除去とは別の、bash 自体の
# 制約）。NUL 区切りのまま `while IFS= read -r -d '' ...` で読むには、変数ではなく
# ファイルとして経由させる必要がある。
#
# trap は 3 つの mktemp より「前」に張る。あとから張ると、2 つ目・3 つ目の mktemp が
# 失敗して fatal で抜けたときに、先に作られたファイルが消えずに残る（一時領域の
# 容量やファイル数の上限に当たった環境で起きる）。変数は空で先に宣言する。
#
# 削除は関数に置き、パスを必ず二重引用符で囲む。${VAR:+"$VAR"} を rm の引数へ
# 直接展開する形でも bash では引用が保たれる（実測: TMPDIR にスペースと * を
# 含めても巻き添え削除は起きなかった）が、展開結果が引用されるかどうかはシェルの
# 版ごとに確かめないと読み取れない。この雛形は任意の環境へ配布され、macOS の
# bash 3.2 でも動く必要があるため、確かめなくても読める形にする。
# -- を付けて、パスが rm のオプションとして解釈される経路も閉じる。
GIT_STDERR=""
PENDING_RAW=""
TRACKED_RAW=""
# trap から呼ぶため、静的解析からは呼び出しが見えない。
# shellcheck disable=SC2329
cleanup_temp_files() {
  [[ -n "$GIT_STDERR" ]] && rm -f -- "$GIT_STDERR"
  [[ -n "$PENDING_RAW" ]] && rm -f -- "$PENDING_RAW"
  [[ -n "$TRACKED_RAW" ]] && rm -f -- "$TRACKED_RAW"
  return 0
}
trap cleanup_temp_files EXIT
GIT_STDERR="$(mktemp "${TMPDIR:-/tmp}/check-no-secrets.XXXXXX")" || fatal "一時ファイルを作成できませんでした。stderr の退避が成立しません。"
PENDING_RAW="$(mktemp "${TMPDIR:-/tmp}/check-no-secrets-pending.XXXXXX")" || fatal "一時ファイルを作成できませんでした。追跡前の一覧が保存できません。"
TRACKED_RAW="$(mktemp "${TMPDIR:-/tmp}/check-no-secrets-tracked.XXXXXX")" || fatal "一時ファイルを作成できませんでした。追跡済みの一覧が保存できません。"

# 失敗したときだけ、退避しておいた git の stderr を見せる。正常時は無音のまま。
show_git_stderr_if_any() {
  if [[ -s "$GIT_STDERR" ]]; then
    printf '[secrets] git の出力:\n' >&2
    sed 's/^/    /' "$GIT_STDERR" >&2
  fi
}

# ── 機密とみなすパス ─────────────────────────────────────────────────────────
#
# 判定は 2 経路で同じパターンを使う。片方だけ末尾一致に絞ると、改名・退避ファイル
# （credentials.json.bak / terraform.tfstate-backup）が片側だけすり抜け、「経路が
# 違うだけで守る対象は同じ」という前提が崩れる。
#
# 各名前のうしろに ([-._~][^/]*)? を許すことで、その退避形まで 1 つの式で拾う。
# 境界を [-._~] に限るのは、無制限の後方一致にすると setup.environment.md や
# foo.keys のような無関係な名前まで拾ってしまうため。広すぎる検知層は「赤を無視する
# 習慣」を作り、検知層そのものを無力化する。
#
# 拡張子側は [^/]+ を前置きして、パス区切りをまたがせない。
#
# 接頭辞側（名前系トークンのみ）: credentials.json / client_secret /
# service[-_]account の 3 つに限り、うしろと同じ境界 ([^/]*[-._~])? を前へも許す。
# dev-credentials.json / prod-service-account.json / my-client_secret.json のように
# 環境名や用途名を前置きする運用が実際にあり、先頭固定のままだとこの形がすり抜ける。
# 境界を接尾辞側と同じ [-._~] に揃えるのは、無制限の前方一致にすると無関係な名前まで
# 拾ってしまうため（接尾辞側と同じ理由）。
#
# .env / .netrc / .pgpass / .git-credentials / id_(rsa|...) は対象外のまま先頭固定に
# 残す。これらは名前自体が短く、接頭辞を許すと foo.env のように無関係な名前（英単語
# environment 系）まで拾う経路が接尾辞側より太い。過検知は検知層そのものを無力化する
# ため、実際に接頭辞付き運用が確認された名前系トークンだけに絞る。
SECRET_PATH_RE='(^|/)(\.env|\.netrc|\.pgpass|\.git-credentials|id_(rsa|dsa|ecdsa|ed25519)|([^/]*[-._~])?(credentials\.json|client_secret|service[-_]account)|[^/]+\.(pem|key|p12|pfx|jks|keystore|kdbx|tfstate|tfvars))([-._~][^/]*)?$'

# 値を持たない雛形と公開鍵は共有が前提なので除外する（共通規範「共有するのは値の
# ない雛形のみ」/ .pub は公開鍵）。
#
# トレードオフ: 名前で判定するため、機密を .example という名前で置けばこの検査は
# すり抜ける。名前の検査だけでは中身は見られないので、配布する唯一の雛形である
# .env.example については下の「機密の値」検査を第 2 層として持つ。
SECRET_EXEMPT_RE='\.(example|sample|template|dist|pub)$'

# 1 パスが機密とみなす対象かどうかを判定する。
#
# grep へ渡さず bash の =~ で判定するのは、grep の終了コード（1 = 該当なし /
# 2 = エラー）をパイプライン越しに読み分けようとすると、エラーを「該当なし」と
# 取り違える経路ができるため。ここでは外部プロセスを一切挟まない。
is_secret_path() {
  local path="$1" base
  if [[ ! "$path" =~ $SECRET_PATH_RE ]]; then
    return 1
  fi
  base="${path##*/}"
  if [[ "$base" =~ $SECRET_EXEMPT_RE ]]; then
    return 1
  fi
  return 0
}

# ── 0. 検査が成立する状態か ──────────────────────────────────────────────────

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '[secrets] git の作業ツリーではありません: %s\n' "$PWD" >&2
  printf '[secrets] 機密が無いことと、検査が成立していないことは別です。\n' >&2
  printf '[secrets] 対処: git init し、追跡対象を 1 件以上コミットしてから実行してください。\n' >&2
  fatal "検査が成立しないため失敗させます。"
fi

# ── 1. 追跡前（追跡対象へ入る前に落とす） ────────────────────────────────────
#
# #263 より前は git add --all --dry-run の人間向け出力（add '<path>'）を行単位で
# 解析していた。パス名に改行が含まれると、git はその改行をそのまま出力するため
# 1 パスが 2 行へ割れ、`add '<path>'` の行末アンカー一致が成立せず検知できな
# かった（実測: git 2.53.0 で追跡前・追跡済みとも SECRETS_PASS まで通過）。
#
# 塞ぎ方: 列挙そのものを NUL 区切りへ変える。git add --dry-run に -z は無いため、
# 同じ「index へまだ入っていない変更」を機械可読で返す git status --porcelain -z
# へ置き換える（出力書式の解析そのものが変わる。追跡済み側の ls-files -z と対で
# 読むこと）。
#
# --untracked-files=all: 既定（normal）は未追跡ディレクトリを "?? dir/" と 1 行に
# 畳んでしまい、配下の credentials.json が見えなくなる（実測）。add --dry-run は
# 元々ファイル単位で列挙していたため、同じ広さに戻す。
# --no-renames: 既定では index 側（ステージ済み）の改名が 1 レコード 2 パス
# （新パス\0旧パス\0）になり、NUL 区切りのままでは「次のレコード」との境界が
# 曖昧になる。無効化すると改名は旧パスの削除・新パスの追加という 2 レコードに
# 分かれ、1 レコード = 1 パスの前提が常に成り立つ（実測: 作業ツリー側の改名は
# 既定のままでも常にこの 2 レコード形であり、影響を受けない）。
# パス指定を `.` にしてルート配下へ限るのは、下の git ls-files と同じ広さに
# そろえるため（プロジェクトルートがリポジトリのサブディレクトリである構成でも、
# 2 経路の対象が食い違わないようにする）。
if ! git status --porcelain -z --untracked-files=all --no-renames -- . \
      >"$PENDING_RAW" 2>"$GIT_STDERR"; then
  show_git_stderr_if_any
  fatal "git status --porcelain -z に失敗しました。追跡前の検査が成立しません。"
fi

# 各レコードは "XY<space><path>" で、X が index 側・Y が作業ツリー側の 1 文字
# ステータス。数えるのは「これから git add --all で追跡対象へ入る変更」のみ:
#
#   Y が空白 … 作業ツリーに変更が無い（index 側だけの状態）。既に追跡済みなので
#              下の git ls-files -z が拾う。ここで重複計上しない。
#   Y = D    … 作業ツリーでの削除。git add --all は remove として扱い、削除は
#              追跡対象へ「入る」変更ではない（#263 以前の add --dry-run 版も
#              remove '<path>' 行を対象外にしていたのと同じ扱い）。
#   Y = !    … 無視対象。--ignored を渡していないため通常は現れないが、将来
#              オプションを増やしたときに備えて明示的に除外する。
#   それ以外（?? の未追跡や M・A・T・C 等の未ステージ変更）は対象に含める。
pending_count=0
while IFS= read -r -d '' pending_rec; do
  [[ -n "$pending_rec" ]] || continue
  pending_y="${pending_rec:1:1}"
  if [[ "$pending_y" == ' ' || "$pending_y" == 'D' || "$pending_y" == '!' ]]; then
    continue
  fi
  pending_path="${pending_rec:3}"
  pending_count=$((pending_count + 1))
  if is_secret_path "$pending_path"; then
    ng "追跡対象へ入ろうとしています: $pending_path"
  fi
done <"$PENDING_RAW"

# ── 2. 追跡済み（CI で落とす層） ─────────────────────────────────────────────
#
# -z で列挙する（#263）。ls-files -z / status --porcelain -z は core.quotePath の
# 設定に関わらずパスを一切引用・エスケープせず生バイト列のまま NUL 区切りで返す
# （実測: git 2.53.0、非 ASCII パスも 8 進エスケープされない）。#263 より前は
# newline 区切りの ls-files に -c core.quotePath=false を渡すことで同じ効果を
# 得ていたが、-z へ移ったことでその依存が外れたため、ここでは渡していない
# （依存を外したのでここに書く）。
if ! git ls-files -z -- . >"$TRACKED_RAW" 2>"$GIT_STDERR"; then
  show_git_stderr_if_any
  fatal "git ls-files に失敗しました。追跡済みの検査が成立しません。"
fi

if [[ ! -s "$TRACKED_RAW" ]]; then
  printf '[secrets] 追跡ファイルが 1 件もありません。\n' >&2
  printf '[secrets] 出力が空なのは「機密が無い」ではなく「検査していない」状態です。\n' >&2
  fatal "検査が成立しないため失敗させます。"
fi

tracked_count=0
while IFS= read -r -d '' tracked_path; do
  [[ -n "$tracked_path" ]] || continue
  tracked_count=$((tracked_count + 1))
  if is_secret_path "$tracked_path"; then
    ng "追跡対象に含まれています: $tracked_path"
  fi
done <"$TRACKED_RAW"

# ── .env / .env.example のキー抽出 ───────────────────────────────────────────
#
# 抽出をここへ書き直さず、ローダー（scripts/load-project-env.sh）自身に読ませる。
# 別に書くと「実際には読まれるのに検査からは見えないキー」が生まれ、下の機密値の
# 検査に穴が開く（CRLF・export 記法・KEY = VALUE・クォート囲みの揺れを吸収して
# いるのはローダーだけである）。
#
# env -i を通す理由: 対話シェルには on-attach.sh が .env の読み込みを注入する。
# 呼び出し元のシェルが既に .env を読んでいると、その値が「ファイルに書かれている」
# のと区別できない。最小の環境から始め、ソース前後で export 済みになった変数の差
# だけを取る。PATH / HOME / LC_ALL は落とすと外部コマンド（git / sort / comm）が
# 動かない、あるいは並びが揺れるため明示的に渡す。
#
# 制約: PATH のように最小環境にも存在する名前が .env にあると差分に現れない。
# 実運用の .env でその名前を使うことはなく、使えばローダーがシェルの PATH を
# 壊すので、検査の穴としては表面化しない。
#
# 第 1 引数 = 出力モード（keys = キー名 / valued = 値が空でないキー名）
# 第 2 引数 = ローダーの絶対パス
#
# valued モードでも値は出力しない。機密をログ・差分へ混入させないため、返すのは
# 「値が空でないキーの名前」だけである。
#
# 単一引用符は意図的。この文字列は子 bash が解釈するプログラムで、ここで展開させない。
#
# 子シェルも fail-closed にする（set -euo pipefail）。以前は set -e 系が無く、
# sort / comm が存在しない・失敗する環境でもキー抽出が空のまま exit 0 で完走して
# いた（実測: PATH から comm を外すと `comm: command not found` を stderr へ出し
# つつ空文字列を返し、rc=0 のまま抜ける）。呼び出し側は終了ステータスだけを見て
# いるため、この経路は検出できず、下の機密値検査が「何も検査せずに通る」状態に
# なっていた。git add / git ls-files の失敗は既に fail-closed にしており、内部で
# 扱いが割れていたのをそろえる。
#
# 副作用の確認（実測、git 2.53.0 / bash 5.x）:
#   - compgen -e は env -i でも PATH / HOME / LC_ALL を cns_probe() が明示的に
#     渡しているため常に非空で、pipefail で before="$(compgen -e | sort)" が
#     落ちることはない。
#   - . "$loader" || exit 3 の既存ガードは維持する。
#   - valued モードの ${!k} は compgen -e が返した「現に export 済みの名前」だけを
#     対象にするため、set -u 下でも未定義変数を参照しない。
#   - printf ... | while read ... の pipeline は、read が EOF で通常終了する分には
#     非 0 にならず、pipefail で落ちない。
#
# baseline モード: ローダーを読む「前」に既に export されている名前（PATH / HOME /
# LC_ALL に加え、bash が自動で export する PWD / SHLVL / _ など）をそのまま返す。
# comm -13 は「ローダー実行後に増えた」ものだけを差分として拾うため、この一覧に
# 含まれる名前は .env.example に書かれていても原理的に検出できない（下の空抽出
# ガードが使う。「制約: PATH のように…」の段落と対で読むこと）。keys / valued の
# 挙動は変えない。
#
# shellcheck disable=SC2016
CNS_PROBE='
  set -euo pipefail
  mode="$1"; loader="$2"
  before="$(compgen -e | sort)"
  if [ "$mode" = baseline ]; then
    printf "%s\n" "$before"
    exit 0
  fi
  . "$loader" || exit 3
  after="$(compgen -e | sort)"
  keys="$(comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after"))"
  if [ "$mode" = keys ]; then
    printf "%s\n" "$keys"
    exit 0
  fi
  printf "%s\n" "$keys" | while IFS= read -r k; do
    [ -n "$k" ] || continue
    if [ -n "${!k}" ]; then printf "%s\n" "$k"; fi
  done
  exit 0
'

# $1 = モード / $2 = PROJECT_ENV_FILE へ渡す絶対パス（空ならローダー自身の解決に委ねる）
cns_probe() {
  local mode="$1" env_file="${2-}"
  if [[ -n "$env_file" ]]; then
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C PROJECT_ENV_FILE="$env_file" \
      bash --noprofile --norc -c "$CNS_PROBE" cns-probe "$mode" "$LOADER"
  else
    # .env の場所はローダーに決めさせる。worktree から実行された場合にメインの
    # 作業コピーへ回り込む挙動まで含めて、実際に読まれるファイルを対象にする。
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
      bash --noprofile --norc -c "$CNS_PROBE" cns-probe "$mode" "$LOADER"
  fi
}

if [[ ! -f "$LOADER" ]]; then
  fatal "$LOADER が見つかりません。.env 系の検査が成立しません。"
fi

if [[ ! -f "$ENV_EXAMPLE" ]]; then
  printf '[secrets] %s がありません。\n' "$ENV_EXAMPLE" >&2
  printf '[secrets] 値のない雛形は共通規範が要求する共有物です（値は各自が .env へ設定する）。\n' >&2
  fatal "検査が成立しないため失敗させます。"
fi

example_keys=""
if ! example_keys="$(cns_probe keys "$PWD/$ENV_EXAMPLE")"; then
  fatal "$ENV_EXAMPLE のキーを抽出できませんでした。"
fi

# 抽出そのものが「失敗はしていないが結果が空」になる経路を塞ぐ。CNS_PROBE の
# set -euo pipefail だけでは、非 0 で終わらずに空を返すケースまでは塞げない。
#
# 空の .env.example は正当（環境変数を使わないプロジェクトもある）ため、単純に
# 「空なら落とす」にはできない。KEY=... の形の行が 1 行以上あるのに抽出結果が
# 0 件なら、それは「値が無い」のではなく「抽出そのものが成立していない」ことを
# 意味するため、その場合だけ fatal で落とす……はずだったが、比較対象を素朴な
# 行数にすると誤検知する。CNS_PROBE は「ローダー実行前に既に export されている
# 名前」（baseline: PATH / HOME / LC_ALL や、bash が自動で export する PWD /
# SHLVL / _ など）を comm -13 で除外する構造上、.env.example がそういう名前だけで
# 構成されていると、行はあるのに抽出は原理的に 0 件になる（上の「制約: PATH の
# ように最小環境にも存在する名前が .env にあると差分に現れない」と同じ理由）。
# これは検査していないのではなく、検出できない対象を正しく除外した結果であり、
# fatal にしてはならない。そのため比較対象を「baseline に含まれないキー」だけに
# 絞る。
if [[ -z "$example_keys" ]]; then
  baseline_keys=""
  if ! baseline_keys="$(cns_probe baseline "")"; then
    fatal "ベースラインの環境変数一覧を取得できませんでした。空抽出の判定が成立しません。"
  fi

  # .env.example から KEY=... の行のキー名だけを取り出す（値・コメント・空行は
  # 無視する）。ローダーの正確な解析ルールとは別に、ここでは「fatal を出すか」の
  # 判定にのみ使う概算でよい。
  example_candidate_keys="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$ENV_EXAMPLE")"

  example_non_baseline_count="$(comm -23 \
    <(printf '%s\n' "$example_candidate_keys" | sort) \
    <(printf '%s\n' "$baseline_keys" | sort) \
    | grep -c '[^[:space:]]' || true)"

  if [[ "$example_non_baseline_count" -gt 0 ]]; then
    fatal "$ENV_EXAMPLE にベースライン外の KEY=... 行が $example_non_baseline_count 件あるのに抽出結果が 0 件でした。抽出が成立していない疑いがあります（検査していないことを合格にしない）。"
  fi
fi

# ── 3. .env.example に機密の値が入っていないこと ─────────────────────────────
#
# 機密でない設定既定値（例: 回数・モデル名）は雛形で共有する意味があるため、
# すべてのキーを空必須にはしない。機密を示す語を含むキーと identity キーだけを
# 対象にする。
#
# 部分一致で見る。語尾一致にすると AWS_SECRET_ACCESS_KEY_ID のような修飾付きが
# すり抜ける。PAT だけは PATH との衝突を避けて語境界（先頭か _ に挟まれる）を要求する。
SECRET_KEY_RE='SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE|KEY|AUTH|IDENTITY|(^|_)PAT(_|$)'

example_valued=""
if ! example_valued="$(cns_probe valued "$PWD/$ENV_EXAMPLE")"; then
  fatal "$ENV_EXAMPLE の値を検査できませんでした。"
fi

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if printf '%s' "$key" | grep -Eqi "$SECRET_KEY_RE"; then
    ng "$ENV_EXAMPLE に値が入っています（雛形はキー名だけを共有する）: $key"
  fi
done <<<"$example_valued"

# ── 4. .env と .env.example のキー整合 ───────────────────────────────────────
#
# .env が唯一の供給元で、.env.example はその雛形。.env にしか無いキーは、雛形が
# その設定項目を伝えていない状態で、他の環境が .env を作り直すと黙って欠ける。
#
# .env は追跡外なので、無い環境（CI）ではキーが 1 件も取れない。その場合はスキップ
# する（この検査に限り、issue の指定どおり「.env が無い環境ではスキップ」とする）。
env_keys=""
if ! env_keys="$(cns_probe keys "")"; then
  fatal ".env のキーを抽出できませんでした。"
fi

if [[ -z "$env_keys" ]]; then
  printf '[secrets] .env からキーを取得できないため、キー整合はスキップします（CI など .env が無い環境）。\n'
else
  only_env="$(comm -23 \
    <(printf '%s\n' "$env_keys" | sort) \
    <(printf '%s\n' "$example_keys" | sort))"
  only_example="$(comm -13 \
    <(printf '%s\n' "$env_keys" | sort) \
    <(printf '%s\n' "$example_keys" | sort))"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    ng ".env にあるキーが $ENV_EXAMPLE に無い（雛形から作り直した環境で黙って欠ける）: $key"
  done <<<"$only_env"

  # 逆向き（雛形にあって .env に無い）は失敗にしない。
  #
  # 判断と理由: 雛形へキーが増えた直後は、各環境の .env が追いつくまで必ずこの状態を
  # 通る。ここで落とすと、配布物の更新のたびに全利用者のローカルゲートが赤くなり、
  # 直す先が追跡ファイルではなく各人の手元になる。実測でもこのリポジトリが該当した
  # （#237 が .env.example へ GH_TOKEN を足した一方、手元の .env は 4 キーのまま）。
  # 一方でこの向きが実害になる経路（値が解決できない）は、それを必要とする検査が
  # それぞれ fail-closed で落とす（例: verify-commit-identity.sh の許可 email）。
  # 黙って無視はせず、事実として提示する。
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf '[secrets] NOTICE %s にあるキーが .env に未設定です: %s\n' "$ENV_EXAMPLE" "$key"
  done <<<"$only_example"
fi

# ── 結果 ─────────────────────────────────────────────────────────────────────

printf '[secrets] 検査したパス: 追跡済み %s 件 / 追跡前 %s 件\n' \
  "$tracked_count" "$pending_count"

if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf '[secrets] 機密の混入を %s 件検出しました。\n' "$VIOLATIONS" >&2
  printf '[secrets] 対処: 追跡前なら .gitignore へ加える。追跡済みなら git rm --cached で外し、\n' >&2
  printf '[secrets] 既にコミット済みなら履歴からの除去と、当該資格情報の失効・再発行まで行う\n' >&2
  printf '[secrets] （削除コミットでは漏洩は解消しません）。\n' >&2
  echo "SECRETS_FAIL"
  exit 1
fi

echo "SECRETS_PASS"
exit 0
TMPL
      ;;
    'scripts/acceptance.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# acceptance.sh — このプロジェクトの受け入れ条件（プロジェクトが所有・編集する）
#
# verify.sh がこのスクリプトを実行し、終了コードで合否を判定する。
# 生成時は、選択言語のマニフェスト（package.json / go.mod など）がルート直下に
# 存在する対象だけを、その言語の慣習的なテストで検証する。マニフェストが無い言語は
# スキップし（失敗させない）、マニフェストはあるがツールが無い場合は導入手順を添えて
# 失敗させる。1 つも検証できなければ「受け入れ条件が未定義」として非0で終了する。
# プロジェクトの実態（テスト・ビルド・lint・E2E など）に合わせて自由に編集すること。
# 受け入れ条件が検証可能であるほど、ループコーディングの反復が収束しやすくなる。
#
# 終了コード: 0 = 合格 / 非0 = 不合格・未定義
set -euo pipefail

# 検証はプロジェクトルート基準で行う。scripts/ の 1 階層上がルート。
# 任意の作業ディレクトリから起動しても結果が不変になるよう、起動時 CWD に依存しない。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

echo "[acceptance] project acceptance checks"
# 実際に検証を 1 つでも実行したか。1 つも実行できなければ「合格」ではなく失敗にする。
# 検証していないことを合格として報告するのが最悪であるため。
ran_any=0

__ACCEPTANCE_CHECK_LINES__

if [[ "$ran_any" -eq 0 ]]; then
  echo "[acceptance] 受け入れ条件が未定義です。検証対象のマニフェストが 1 つも見つかりません。" >&2
  echo "[acceptance] このプロジェクトの受け入れ条件（テスト等）を scripts/acceptance.sh に定義してください。" >&2
  exit 1
fi

echo "[acceptance] OK"
TMPL
      ;;
    'scripts/acceptance-remote.sh')
      # 外部層の雛形は骨格だけを持つ。何が外部状態かはプロジェクトごとに違うため、
      # 具体的な検査を決め打つと必ず外れる。骨格（run ヘルパー・一時ログ・失敗の集計・
      # 前提の記述位置）だけを配り、検査は利用側が足す。
      cat <<'TMPL'
#!/usr/bin/env bash
# acceptance-remote.sh — 外部層の受け入れ条件（プロジェクトが所有・編集する）
#
# 受け入れ条件はローカル層と外部層に分かれる。
#
#   ローカル層（scripts/acceptance.sh）  ネットワークも外部認証も要さない検査。
#                                        ループの接地信号。これが緑なら実装は前へ
#                                        進んでよい。
#   外部層（このファイル）               宣言（IaC 等）と実際の外部状態が一致して
#                                        いるかの検査。外部認証とネットワークを要する。
#
# 起動方法:
#   VERIFY_ACCEPTANCE=scripts/acceptance-remote.sh bash scripts/verify.sh
#
# scripts/loop-gate.sh へは含めない:
#   あちらは push / PR 前の単一入口だが、外部層をそこへ入れると、認証の失効や
#   オフラインでゲート全体が止まる。実装が正しいのにループが止まる状態を作らない。
#   単一入口の目的は「複数の検査を別々に思い出す運用は破綻する」ことを機構で塞ぐ
#   ことであって、外部の可用性をゲートの前提条件に持ち込むことではない。
#
# 通す契機:
#   外部状態の宣言を変更したとき。反復のたびに回す層ではない。
#
# 前提:
#   対象サービスへ認証済みであること。このスクリプトは認証を行わない（資格情報を
#   スクリプトへ書き写す経路を作らないため）。未認証やオフラインで回すと個々の検査が
#   失敗するが、それは「宣言と外部状態が食い違っている」ことを意味しない。前提の
#   不成立と実際の乖離を読み分けられるよう、前提の確認（ログイン状態の検査など）を
#   最初の検査として置くとよい。
#
# 終了コード: 0 = 合格 / 非0 = 不合格・未定義
#
# set -e は使わない。1 件目の失敗で止めず、全件を見てから落とすため。
set -uo pipefail

# 検証はプロジェクトルート基準で行う。scripts/ の 1 階層上がルート。
# 任意の作業ディレクトリから起動しても結果が不変になるよう、起動時 CWD に依存しない。
#
# set -e を使わないため、失敗しうる代入には個別にガードを置く。HERE の解決に失敗
# しても止めないと、空の HERE に対して dirname が "." を返し、続く cd が「成功」して
# ガードを素通りする（実測: dirname "" = "." で cd は 0）。ルートへ移れていないのに
# 検査を始めると、相対パスが別の場所を指したまま合否を出すことになる。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
cd "$(dirname "$HERE")" || exit 1

echo "[acceptance-remote] external state checks"

# 実際に検査を 1 つでも実行したか。1 つも実行できなければ「合格」ではなく失敗にする。
# 検証していないことを合格として報告するのが最悪であるため。
ran_any=0
# 失敗件数。外部状態の乖離は複数箇所へ同時に出ることが多く、1 件ずつ往復すると
# 回数だけ増える。
failed=0

# 各検査の出力を退避する一時ログ。mktemp のテンプレートで作り、$$ 由来の予測可能な
# 名前は使わない（同名を先に置かれると書き込み先を乗っ取られる）。
#
# ここも代入ガードを置く（set -e が無いため）。作成に失敗したまま進むと LOG が空になり、
# run の中の >"$LOG" が必ず失敗して、実行できていない検査が「失敗した検査」として
# 報告される（実測: 空の対象へのリダイレクトは rc=1）。原因の異なる赤を同じ形で
# 出さないよう、ここで落とす。
LOG="$(mktemp "${TMPDIR:-/tmp}/acceptance-remote.XXXXXX")" || exit 1
trap 'rm -f "$LOG"' EXIT

# ラベル付きで 1 件実行する。成功時は出力を捨て、失敗したときだけ出力を見せる。
# 正常な実行の出力で画面が埋まると、失敗の位置が読めなくなる。
#
#   run "<ラベル>" <コマンド> [引数...]
#
# サブシェル（パイプの構成要素・コマンド置換・( ) の中）から呼ばないこと。
# ran_any と failed の更新が親へ伝わらず、実行したのに「未定義」、失敗したのに
# 合格という報告になる。
run() {
  local label="$1"
  shift
  ran_any=1
  printf '[acceptance-remote] %s\n' "$label"
  if "$@" >"$LOG" 2>&1; then
    return 0
  fi
  failed=$((failed + 1))
  printf '[acceptance-remote] FAIL: %s\n' "$label" >&2
  sed 's/^/    /' "$LOG" >&2
  return 1
}

# ── ここへ外部状態の検査を足す ────────────────────────────────────────────────
#
# 宣言と実体が一致しているかを見る形にする（例: 宣言の差分検出コマンドが差分なしを
# 返すこと、宣言したリソースが実在すること）。検査を足すまで、このスクリプトは
# 下の判定で失敗する。未定義を合格として報告しないため。

if [[ "$ran_any" -eq 0 ]]; then
  echo "[acceptance-remote] 外部層の受け入れ条件が未定義です。検査を 1 つも実行していません。" >&2
  echo "[acceptance-remote] 宣言と実際の外部状態を照合する検査を scripts/acceptance-remote.sh へ定義してください。" >&2
  exit 1
fi

if [[ "$failed" -gt 0 ]]; then
  echo "[acceptance-remote] $failed 件の検査が失敗しました。" >&2
  echo "[acceptance-remote] 対象サービスへ認証済みか、ネットワークへ到達できるかを先に確認すること。" >&2
  exit 1
fi

echo "[acceptance-remote] OK"
TMPL
      ;;
    # 範囲選択の回帰テストは生成先へ配らない（#242 の判断）。生成先の scripts/ は
    # プロジェクトが所有する運用スクリプトの置き場であり、この配布物の内部実装に
    # 対する回帰テストを置くと、プロジェクトが所有すべきでないものを持たせること
    # になる。acceptance.sh から呼ばせる案も同じ理由で採らない（あちらはプロジェクト
    # が編集する雛形で、規範由来の検査を置くと消える経路ができる）。範囲選択の
    # 正しさは、このパッケージの tests/test-loop-gate-range.sh が担保する。
    'scripts/loop-gate.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# loop-gate.sh — ローカル事前ゲート（ループコーディングの収束点）
#
# push / PR 作成の前に、機械判定の受け入れ検証（verify.sh）と、任意の第二意見
# レビューを直列で通す単一入口。verify が通り、第二意見があればそれも通ったときだけ
# 通過する。
#
# このスクリプトは単体で動作する。第二意見レビューは存在すれば直列化し、
# 無ければ優雅にスキップする（外部パッケージの導入を前提にしない）。
#
# 第二意見レビュー:
#   既定で scripts/second-opinion-review.sh があれば実行する。
#   LOOP_GATE_REVIEW_CMD で任意のコマンドへ差し替え可能。空文字でスキップする。
#
#   second-opinion-review.sh の既定対象はステージ済み差分で、空なら「レビュー対象なし」
#   として 0 を返す。commit 後（ステージが空）にこのゲートを回すと、第二意見が
#   実質スキップされたまま GATE_PASS が出ることになる。push 前ゲートとしては
#   偽の緑なので、ステージが空のときは commit 済み範囲を対象に切り替える。
#
#   切り替えた先が空になる経路も塞ぐ。push 済みのブランチでは上流と HEAD が
#   同じコミットを指すため @{upstream}..HEAD の差分が空になり、同じ偽の緑が
#   復活する。範囲は「解決できたか」ではなく「実際に差分があるか」で選び、
#   無ければ既定ブランチとの分岐点まで戻してブランチ全体を対象にする。
#   それでも差分が無いときは、レビュー対象が無いことを明示したうえで通過する
#   （空を一律 FAIL にすると、差分の無い状態でのゲート実行が落ちるため）。
#
#   上流との差分が空でなくても、その範囲が他ブランチの成果を巻き込むことがある。
#   @{upstream}..HEAD は 2 点間の比較なので、既定ブランチを取り込んだ直後は
#   取り込んだ側のコミットがまるごと差分に入る。それは既にレビューを通った他
#   ブランチの成果であって、このブランチが加えた変更ではない。範囲が既定ブランチ
#   へ到達可能なコミットを含むときは分岐点まで戻し、なぜ範囲を変えたかを出力する。
#
# 終了コード:
#   0 = GATE_PASS（全段通過。push 可）
#   1 = GATE_FAIL（いずれかの段が未通過、または実行不能）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 既定の reviewer へ渡す引数を決める。
#
# ステージ済み差分があるときは何も渡さない（reviewer 側の既定に委ねる）。
# 空のときだけ commit 済み範囲へ切り替える。git リポジトリでない場合や範囲を
# 解決できない場合は、従来どおり引数なしで呼ぶ。範囲を解決できないことは
# reviewer を呼べない理由にならないため、ここでは落とさない。
#
# なお、git 管理外ではこの関数へ到達する前に step 1（verify.sh）が落ちる。
# verify.sh が呼ぶ機密混入検査（check-no-secrets.sh）が git の作業ツリーを前提に
# しており、検査が成立しない状態を合格にしないため。この関数が git 外の経路を
# 持つのは、範囲解決を単体で使えるようにしておくためである。
REVIEW_RANGE=""
# 範囲は解決できたが差分が空だった（= レビューできる対象が無い）状態を表す。
# REVIEW_RANGE="" とは区別する。この状態を reviewer の既定へ流すと、空の
# ステージ済み差分を見せることになり、塞いだはずの素通りへ戻るため。
REVIEW_NO_TARGET=0
# 上流以外を起点に採ったときの理由。黙って範囲を変えると、なぜその差分が
# レビュー対象なのかを読み手が追えないため、採用時に 1 行出力する。
REVIEW_RANGE_REASON=""

# 範囲が実際に差分を持つか。git diff --quiet は差分ありで 1 を返す。
# 128（範囲を解決できない等）を「差分あり」と誤認しないよう、1 だけを真とする。
# 末尾の -- は、範囲と同名のパスが存在するときの曖昧さを排除する。
range_has_diff() {
  local rc=0
  git diff --quiet "$1" -- >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

# 既定ブランチの追跡枝を解決し、名前を標準出力へ返す。見つからなければ 1 を返す。
# 既定ブランチ名は決め打ちせず origin/HEAD → origin/main → origin/master の順で探す。
#
# 解決を 1 箇所へ集約するのは、範囲の汚染判定と分岐点の算出とで**同じ枝**を見る
# 必要があるため。別々に決めると、「汚染ありと判定した枝」と「分岐点を取った枝」が
# 別物になりうる。
resolve_integration_base() {
  local base
  for base in origin/HEAD origin/main origin/master; do
    if git rev-parse --verify --quiet "$base" >/dev/null; then
      printf '%s' "$base"
      return 0
    fi
  done
  return 1
}

# 範囲 <from>..HEAD が、既に既定ブランチ <base> へ到達可能なコミットを含むか。
#
#   all = <from>..HEAD の総数
#   own = そのうち <base> から到達できないもの（= このブランチが加えた分）
#   all != own なら、他ブランチの成果を巻き込んでいる
#
# 「マージコミットを含むか」では判定しない。取り込み方によって現れる形が違い、
# 形ごとに書き分けるほど取りこぼす。到達可能性で見れば取り込み方に依らない。
#
# <base> が空（既定ブランチの追跡枝が無い）なら判定できない。ここで真を返すと
# 分岐点も取れないまま範囲を失うため、偽を返して従来どおり上流を使わせる。
range_includes_base_commits() {
  local from="$1" base="$2" all own
  [[ -n "$base" ]] || return 1
  all="$(git rev-list --count "$from..HEAD" 2>/dev/null || true)"
  own="$(git rev-list --count "$from..HEAD" "^$base" 2>/dev/null || true)"
  # どちらかが数えられなければ判定不能。汚染なし扱いにして上流を使わせる。
  [[ -n "$all" && -n "$own" ]] || return 1
  [[ "$all" != "$own" ]]
}

resolve_review_range() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  # ステージ済みがあるなら reviewer の既定に委ねる。
  git diff --cached --quiet || return 0
  # コミットが 1 件も無ければ比較の起点を作れない。
  git rev-parse --verify --quiet HEAD >/dev/null || return 0

  # 汚染判定と分岐点の算出は、ここで解決した 1 つの枝だけを見る。
  local base=""
  base="$(resolve_integration_base || true)"

  # 上流を起点にできない理由。分岐点を採ったときにそのまま出力する。
  local fallback_reason=""

  # 上流が設定されていればそこからの差分。未 push のコミットがそのまま対象になる。
  # ただし採用条件は 2 つある。
  #   1. 差分が空でないこと。push 済みだと上流 == HEAD で空になり、第二意見が
  #      一度も差分を見ないまま通過する（偽の緑）。
  #   2. 範囲が既定ブランチへ到達可能なコミットを含まないこと。含むなら、その
  #      分は他ブランチが加えた既レビュー済みの成果であって、このブランチの
  #      変更ではない。
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    if ! range_has_diff "$upstream..HEAD"; then
      fallback_reason="upstream range $upstream..HEAD has no diff (branch already pushed)"
    elif range_includes_base_commits "$upstream" "$base"; then
      fallback_reason="upstream range $upstream..HEAD also contains commits already reachable from $base (default branch integrated into this branch)"
    else
      REVIEW_RANGE="$upstream..HEAD"
      return 0
    fi
  else
    fallback_reason="no upstream is configured for this branch"
  fi

  # 既定ブランチの追跡枝との分岐点を起点にし、ブランチ全体をレビュー対象にする。
  #
  # 分岐点（merge-base）を使うのは、base..HEAD が 2 点間の比較であり、base 側に
  # 進んだコミットを「打ち消し」として差分へ混ぜるため。ブランチが加えた変更
  # だけを対象にする。既定ブランチを取り込んでいる場合は分岐点が取り込み地点まで
  # 進むので、取り込んだ成果は範囲から外れる。
  if [[ -n "$base" ]]; then
    local mb
    mb="$(git merge-base "$base" HEAD 2>/dev/null || true)"
    # 履歴が繋がっていない（分岐点が無い）場合の受け皿。
    [[ -n "$mb" ]] || mb="$base"
    if range_has_diff "$mb..HEAD"; then
      REVIEW_RANGE="$mb..HEAD"
      REVIEW_RANGE_REASON="$fallback_reason; reviewing from the merge-base with $base instead"
      return 0
    fi
    # 既定ブランチの追跡枝が見つかった時点で起点は確定する。そこと差分が無いのは
    # 「レビュー対象が無い」であって、空ツリーまで戻してリポジトリ全体を対象に
    # すべき状況ではない。
    REVIEW_NO_TARGET=1
    return 0
  fi

  # 上流はあるが既定ブランチの追跡枝が無い場合。remote は存在するので、下の
  # 空ツリー（= リポジトリ全体）へは広げずレビュー対象なしとして扱う。
  if [[ -n "$upstream" ]]; then
    REVIEW_NO_TARGET=1
    return 0
  fi

  # remote が無いプロジェクト。起点が無いので空ツリーからの全体を対象にする。
  #
  # ここを "HEAD" にしてはならない。reviewer は範囲を git diff に渡すため、
  # git diff HEAD は「作業ツリー vs HEAD」になる。commit 直後は作業ツリーが
  # クリーンで差分が空になり、塞いだはずの素通りがそのまま復活する。
  # （git log HEAD が全履歴を指すのとは意味が違う。verify-commit-identity.sh の
  #   resolve_range が HEAD へ落とすのは git log に渡すためで、こことは別。）
  #
  # 空ツリーのハッシュはオブジェクト形式（sha1 / sha256）で異なるため、
  # 定数を焼き込まず git に計算させる。
  local empty_tree
  empty_tree="$(git hash-object -t tree /dev/null 2>/dev/null || true)"
  if [[ -n "$empty_tree" ]] && range_has_diff "$empty_tree..HEAD"; then
    REVIEW_RANGE="$empty_tree..HEAD"
    REVIEW_RANGE_REASON="$fallback_reason; no default branch tracking ref either, reviewing the whole history"
    return 0
  fi

  # 空ツリーとの差分すら無い（実質空のリポジトリ）。
  REVIEW_NO_TARGET=1
}

main() {
  # verify・第二意見（git diff 等）はプロジェクトルート基準で実行する。
  # scripts/ の 1 階層上がルート。任意の作業ディレクトリから起動しても不変にする。
  #
  # cd を本体側へ置くのは、source した呼び出し元の作業ディレクトリを動かさない
  # ため。範囲解決の回帰テストは、使い捨ての git リポジトリへ cd してから
  # resolve_review_range を呼ぶ。
  cd "$(dirname "$HERE")"

  echo "[loop-gate] step 1: verify (acceptance)"
  if ! bash "$HERE/verify.sh"; then
    echo "[loop-gate] verify not passed" >&2
    echo "GATE_FAIL"
    exit 1
  fi

  echo "[loop-gate] step 2: second opinion"
  if [[ "${LOOP_GATE_REVIEW_CMD-__UNSET__}" == "__UNSET__" ]]; then
    if [[ -f "$HERE/second-opinion-review.sh" ]]; then
      resolve_review_range
      local review_ok=0
      if [[ -n "$REVIEW_RANGE" ]]; then
        # 上流以外を起点に採ったなら、その理由を先に出す。黙って範囲を変えると、
        # なぜその差分がレビュー対象なのかを読み手が追えない。
        if [[ -n "$REVIEW_RANGE_REASON" ]]; then
          echo "[loop-gate] $REVIEW_RANGE_REASON"
        fi
        echo "[loop-gate] staged diff is empty; reviewing $REVIEW_RANGE"
        bash "$HERE/second-opinion-review.sh" --range "$REVIEW_RANGE" || review_ok=1
      elif [[ "$REVIEW_NO_TARGET" -eq 1 ]]; then
        # レビューできる差分が 1 行も無い。第二意見を呼んでも対象が無いため、
        # その事実を明示したうえで通過させる（空を FAIL にすると、差分の無い
        # 状態でのゲート実行が落ちる）。黙って通すと偽の緑と区別が付かない。
        echo "[loop-gate] no reviewable diff; second opinion has nothing to review"
      else
        bash "$HERE/second-opinion-review.sh" || review_ok=1
      fi
      if [[ "$review_ok" -ne 0 ]]; then
        echo "[loop-gate] second opinion reported findings" >&2
        echo "GATE_FAIL"
        exit 1
      fi
    else
      echo "[loop-gate] SKIP (no reviewer present)"
    fi
  elif [[ -n "$LOOP_GATE_REVIEW_CMD" ]]; then
    if ! bash -c "$LOOP_GATE_REVIEW_CMD"; then
      echo "[loop-gate] second opinion reported findings" >&2
      echo "GATE_FAIL"
      exit 1
    fi
  else
    echo "[loop-gate] SKIP (disabled by LOOP_GATE_REVIEW_CMD='')"
  fi

  echo "GATE_PASS"
  exit 0
}

# source ガード。読み込まれただけのときはゲート本体を実行せず、関数定義だけを
# 提供する。範囲解決の回帰テストが resolve_review_range を単体で呼べるようにする
# ため（ガードが無いと、テストが読み込んだだけでゲートが走り出す）。
#
# 逆に、実行されたのに main を呼び損ねると、何も検証しないまま終了コード 0 を
# 返す偽の緑になる。ゲートの出力（step 1 / GATE_PASS / GATE_FAIL）が実行時に必ず
# 現れることを、テスト側で併せて検査すること。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
TMPL
      ;;
    'scripts/confirm-merge-hook.sh')
      # マージ実行の前に確認を挟む PreToolUse フック（--with-claude 連動）。
      # 規範 role-contracts/closer.md の「既定の merge 方針は手動承認とする」を、
      # 呼びかけではなく機構で担保する（shared-ai-rules.md 12 章）。
      cat <<'TMPL'
#!/usr/bin/env bash
# confirm-merge-hook.sh — マージ実行の前に確認を挟む PreToolUse フック。
#
# 規範（role-contracts/closer.md）は「既定の merge 方針は手動承認とする」と定めるが、
# 呼びかけでは破れる。ある利用プロジェクトでは、対話中の許可承認によりマージコマンドが
# 技術的に実行可能になった結果、承認を経ないまま PR 2 本がマージされた。実行できることと
# 実行してよいことが混同された形で、shared-ai-rules.md 12 章が「機構で保証する」を
# 求める対象そのものにあたる。
#
# 保証するのは「黙ってマージしない」ことであって「マージさせない」ことではない。判定は
# deny ではなく ask を返し、利用者が承認すればマージは実行される。指示に従うマージまで
# 塞ぐと「PR を作り、指示を待ち、指示されたらマージする」という本来の運用が成り立たない。
#
# ── なぜ settings.json の permissions.ask で足りないか ────────────────────────
#
# permissions の allow / ask / deny は、コマンド名と引数文字列の前方一致で判定する
# （実測。下記の 2 例はいずれも harmless な echo で確認した）。そのため次を表現できない。
#
#   - 同じ操作の別経路: gh pr merge を対象にした規則は gh api --method PUT .../merge や
#     gh api graphql の mergePullRequest に一致しない。gh api ごと対象にすると、状態を
#     変えない GET まで確認を求める。
#   - 引数の位置に依らない判定: --method PUT が引数の途中や末尾へ来る綴りは、前方一致
#     では捕捉できない（実測: deny 規則 Bash(echo --method PUT:*) は
#     `echo --method PUT repos/o/r/pulls/1/merge` を止めるが、
#     `echo repos/o/r/pulls/1/merge --method PUT` は素通りする）。
#
# 迂回できる機構は守られている外観だけを作る（12 章）。フックは文字列全体を検査できる
# ため、上の 2 つを 1 か所で扱える。
#
# なお「連結（cd ... && gh pr merge）が前方一致を抜ける」は理由として採らない。実測では
# deny 規則 Bash(echo alpha:*) が `cd /tmp && echo alpha beta` を止めており、&& で連結した
# 各コマンドが個別に判定されていた。実行環境の版によって変わり得る挙動であり、この
# フックは連結も捕捉するが、permissions で足りない理由としては上の 2 点だけを挙げる。
#
# ── 検査対象 ──────────────────────────────────────────────────────────────────
#
#   1. gh pr merge          — コマンド位置にあるもの
#   2. pulls/<n>/merge      — かつ PUT を指定しているもの（REST 経由の merge 実行）
#   3. mergePullRequest     — かつ gh api graphql から呼ばれているもの
#
# いずれも「文字列に含まれるか」ではなく「実行しようとしているか」で判定する。単純な
# 部分一致にすると `grep -rn 'mergePullRequest' .` や `git log -S 'gh pr merge'`、GET での
# `pulls/1/merge`（マージ済みか調べるだけ）まで確認を要求する。確認が頻発すれば内容を
# 読まずに承認する習慣ができ、機構は形だけになる。
#
# コマンド位置は「行頭、または ; && || | ( の直後」とし、先行する環境変数代入は読み飛ばす。
# 前方一致にしないのは cd との連結を捕捉するためで、逆に引用符の内側は通る。
#
# ── fail-open にしない ───────────────────────────────────────────────────────
#
# jq でコマンドを取り出せなかった場合は、ペイロード全体を検査対象にする。「取れなければ
# 通す」にすると、jq が無い環境・壊れた JSON・将来のペイロード変更のいずれでも検査を黙って
# 飛ばして通す。検知層が黙って無効化されるのは最悪の壊れ方で、このフックが防ごうとして
# いる「気づかないまま実行できる」状態そのものを再現する。出力側も同じ理由で jq に
# 依存させない（printf のフォールバックを持つ）。
#
# ── 既知の限界（意図的に塞がない）────────────────────────────────────────────
#
# これは「うっかり実行」に確認を挟む guardrail であって、意図的な迂回を防ぐ
# security boundary ではない。文字列照合である以上、書き方を変えれば抜けられる。
#
#   gh -R owner/repo pr merge 1      gh とサブコマンドの間にオプションが挟まる形
#   /usr/bin/gh pr merge 1           絶対パス・相対パスでの起動
#   env gh pr merge 1                env / command などのプレフィックス
#   bash -c "gh pr merge 1"          引用符の内側（引用符の内側を通すことの裏返し）
#   gh api .../pulls/$N/merge        URL に変数展開を含む形
#   gh api graphql -F query=@q.gql   クエリを外部ファイルから読む形
#
# なお -XPUT（連結形）・--method=PUT（= 連結）・--method put（小文字）は、上の一覧とは
# 違って意図的な迂回ではなく curl 風のごく普通の綴りである（実測: いずれも gh が受理する）。
# 「うっかり実行」の側にあたるため、下の判定はこれらも拾う。
#
# ペイロードが空（stdin が空）の場合は確認を求める（ask）。マージコマンドを検知した
# のではなく、検査そのものが成立しなかったことを理由文で伝える。将来ペイロードの
# 渡し方が変わって stdin へ何も来なくなったときにここで気づけるようにするための措置
# であって、配線が生きていることそのものを保証するものではない。配線が生きている
# ことは、フックへ実際にペイロードを流して確かめる以外に保証できない。
#
# 塞ぐたびに新しい書き方が見つかるため、完全性は達成できない。完全であるかのように
# 記録すると、実態より強い保証があると誤認させる（12 章）。
#
# main への直接 push は扱わない。ブランチ保護がサーバ側で拒否しており、そちらのほうが
# 確実なため。ブランチ名に main を含む feature ブランチへの push を誤って止める副作用も
# 避けられる。
#
# 副作用: マージコマンドに見える文字列を行頭に含むコミットメッセージやテストは、そのまま
# では実行できず確認を求められる。ファイル経由（git commit -F、テストスクリプト）で
# 回避できる。
#
# 終了コード: 常に 0。判定は標準出力の JSON（permissionDecision）で伝える。
set -uo pipefail

payload="$(cat)"

reason=""

if [[ -z "$payload" ]]; then
  # ペイロードが空＝配線不全の疑い。matcher で絞られた Bash ツール実行に対して
  # PreToolUse から何も渡っていないということは、フックが実行はされていても実質
  # 機能していない状態になり得る。jq 不在時に「取れなければ通す」を採らなかったのと
  # 同じ理由（検知層が黙って無効化されるのは最悪の壊れ方）で、ここも fail-open に
  # しない。ただしマージを検知したわけではないので、理由文はマージ云々ではなく
  # 「検査が成立しなかったこと」を伝える内容にする。
  reason='PreToolUse フックへ届いたペイロードが空でした。マージを検知したのではなく、検査そのものが成立していません。.claude/settings.json の PreToolUse 配線を確認してください。'
else
  # 検査対象の決定。Bash ツールのコマンド文字列を取り出せればそれを、取り出せなければ
  # ペイロード全体を対象にする（fail-open にしない）。全体を対象にすると確認が増える
  # 側へ振れるが、検査を飛ばす側へ振れるより安全である。
  target=""
  if command -v jq >/dev/null 2>&1; then
    target="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  fi
  extracted=yes
  if [[ -z "$target" ]]; then
    extracted=no
    target="$payload"
  fi

  # バックスラッシュ行継続（\ + 改行）だけを空白へ正規化する。判定にのみ使い、
  # payload・target 自体や理由文は書き換えない。長い REST 呼び出しを \ で複数行に
  # 分けるのは普通の書き方で、-XPUT / --method=PUT と同じ「うっかり実行」側にあたる。
  # 分けて書くと pulls/<n>/merge と PUT が別行になり、REST 判定の同一行条件が外れて
  # 検知漏れになる（実測）。
  #
  # 改行を一律には潰さない。無関係な 2 行（例: echo の次行にたまたま別の gh api 呼び
  # 出しが続くだけの形）まで 1 行へ結合すると、同一行条件が意味を失い誤検知する。
  # 落とすのは直前にバックスラッシュがある改行だけにする。
  #
  # CRLF を先に処理する。LF だけを落とすと \ + CR が残り、CR が語末境界として働いて
  # 判定が外れる。CRLF がこのフックへ届く経路は実測できていないが、置換 1 行で
  # 恒久的に問いを消せるため入れておく。
  norm_target="${target//$'\\\r\n'/ }"
  norm_target="${norm_target//$'\\\n'/ }"

  # コマンド位置の前置き。行頭、または ; && || | ( の直後で、先行する環境変数代入
  # （FOO=bar gh ...）を読み飛ばす。grep は行単位で見るため ^ が各行の先頭に効く。
  #
  # 取り出しに失敗したときはこの前置きを外す。ペイロード全体はシェルの行ではなく JSON
  # であり、コマンドは引用符の内側に現れる。位置を問う条件をそのまま当てると必ず外れ、
  # 「全体を検査対象にする」が実質 fail-open になる（実測: 壊れた JSON
  # {"tool_input": {"command": "gh pr merge 1" が素通りした）。取り出せていない以上
  # 位置は判定できないため、位置を問わない照合へ落として確認を増やす側へ振る。
  cmd_pos='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  if [[ "$extracted" == "no" ]]; then
    cmd_pos=''
  fi

  # 語末の境界。空白か行末だけにすると、JSON の引用符（"gh pr merge"）に隣接した形を
  # 取りこぼす。逆に境界を置かないと gh pr mergequeue のような別サブコマンドまで拾う。
  word_end='([^A-Za-z0-9_-]|$)'

  # パイプは使わずヒアストリングで渡す。grep -q は一致した時点で終了するため、上流を
  # パイプにすると SIGPIPE で pipefail が発火し、一致したのに条件が偽になる経路ができる。
  if grep -qE "${cmd_pos}gh[[:space:]]+pr[[:space:]]+merge${word_end}" <<<"$norm_target"; then
    reason='gh pr merge をコマンド位置で実行しようとしています。既定の merge 方針は手動承認です。承認の記録を確認してください。'
  else
    # REST 経由の merge。PUT の指定と merge エンドポイントが同じ行にあることを条件に
    # する。GET は「マージ済みか」を調べるだけで状態を変えないため対象にしない。
    #
    # --method PUT（空白区切り）に加え、--method=PUT（= 連結）・-XPUT（-X への直接連結）・
    # --method put（小文字）も拾う。value 側の大小混在は [Pp][Uu][Tt] で吸収する
    # （GET 側はそもそもこのパターンに現れないため波及しない）。
    #
    # PUT の直後には word_end を要求する。無いと -XPUTS のような無関係な綴りまで拾う。
    # --method の直後は区切り（= か空白）を要求する。無いと --methodology のような別
    # オプション名の内部にまで一致する。norm_target を見るので、\ 行継続で PUT が
    # 次行にずれていても同一行条件を満たす。
    merge_endpoint_lines="$(grep -E 'pulls/[0-9]+/merge' <<<"$norm_target")"
    if [[ -n "$merge_endpoint_lines" ]] \
      && grep -qE "(--method(=|[[:space:]]+)|-X[[:space:]]*)[Pp][Uu][Tt]${word_end}" \
        <<<"$merge_endpoint_lines"; then
      reason='PR の merge エンドポイントへ PUT を実行しようとしています（REST 経由の merge）。既定の merge 方針は手動承認です。承認の記録を確認してください。'
    elif grep -qF 'mergePullRequest' <<<"$norm_target" \
      && grep -qE "${cmd_pos}gh[[:space:]]+api[[:space:]]+graphql${word_end}" <<<"$norm_target"; then
      # graphql だけは行をまたぐ判定にする。クエリはヒアドキュメントや複数行の
      # -f query=... で渡されることがあり、同じ行にあることを条件にすると外れる。
      reason='gh api graphql から mergePullRequest を実行しようとしています。既定の merge 方針は手動承認です。承認の記録を確認してください。'
    fi
  fi
fi

if [[ -z "$reason" ]]; then
  exit 0
fi

# 出力も jq に依存させない。理由文には二重引用符とバックスラッシュを含めないため、
# フォールバックの printf でも JSON として妥当な出力になる。
if command -v jq >/dev/null 2>&1; then
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
fi
exit 0
TMPL
      ;;
    '.claude/settings.json')
      # PreToolUse フックの配線（--with-claude 連動）。JSON はコメントを持てないため、
      # 何をなぜ配線しているかはフック本体（scripts/confirm-merge-hook.sh）の冒頭と
      # README に置く。matcher を Bash に絞るのは、フックの検査対象がシェルコマンド
      # だからで、他のツールへ配ると取り出せないペイロードでの照合ばかりが増える。
      #
      # 既存ファイルは衝突ポリシー（既定 skip）で温存される。既に settings.json を
      # 持つプロジェクトへ後から入れる場合は、この hooks 節を手で足すことになる。
      cat <<'TMPL'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/confirm-merge-hook.sh\""
          }
        ]
      }
    ]
  }
}
TMPL
      ;;
    '.claude/.gitignore')
      cat <<'TMPL'
# settings.local.json は対話中に許可した操作の一覧を持つ。追跡すると、その場の判断で
# 許可した強い操作が clone した全員へ配られる。.env と同じ理由で共有しない。
#
# ルートの .gitignore（devcontainer-bootstrap managed section）ではなくここへ置くのは、
# .claude/ の中で閉じる除外を .claude/ を配る側の責務にするため。同じ除外を 2 か所に
# 持つと、片方だけ直したときにどちらが効いているのか読めなくなる。
settings.local.json
TMPL
      ;;
    *)
      echo "error: unknown template key: $mode:$rel" >&2
      exit 1
      ;;
  esac
}

# ── 出力生成 ─────────────────────────────────────────────────────────────────

has_language() {
  local target="$1" l
  for l in "${LANGUAGES[@]}"; do [[ "$l" == "$target" ]] && return 0; done
  return 1
}

# --with-* で選択された装備に含まれるか。has_language と対になる述語。
# WITH_SET は空になり得るため、未束縛展開を避けて空配列を安全に扱う。
has_with() {
  local target="$1" w
  for w in ${WITH_SET[@]+"${WITH_SET[@]}"}; do [[ "$w" == "$target" ]] && return 0; done
  return 1
}

# with-feature（devcontainer feature）の path を返す。cloud CLI と Terraform。
with_feature_path() {
  case "$1" in
    aws)       printf 'ghcr.io/devcontainers/features/aws-cli:1' ;;
    gcp)       printf 'ghcr.io/dhoeric/features/google-cloud-cli:1' ;;
    terraform) printf 'ghcr.io/devcontainers/features/terraform:1' ;;
    *)         printf '' ;;
  esac
}

# with-feature を配線するか。Terraform は cloud（aws または gcp）の随伴で、
# いずれかが選択されていれば 1 回だけ有効化する。
with_feature_active() {
  case "$1" in
    aws)       has_with aws ;;
    gcp)       has_with gcp ;;
    terraform) has_with aws || has_with gcp ;;
    *)         return 1 ;;
  esac
}

# 選択した AI ツールの CLI 情報（コマンド名 npmパッケージ）。空行は返さない。
# bash 3.2 互換のため連想配列を使わず case で分岐する。
ai_cli_spec() {
  case "$1" in
    claude)  printf 'claude @anthropic-ai/claude-code' ;;
    gemini)  printf 'gemini @google/gemini-cli' ;;
    copilot) printf 'copilot @github/copilot' ;;
    *)       printf '' ;;
  esac
}

# 選択した AI ツールが rebuild 間で保持する設定ディレクトリ（remoteUser は vscode）。
ai_config_dir() {
  case "$1" in
    claude)  printf '/home/vscode/.claude' ;;
    gemini)  printf '/home/vscode/.gemini' ;;
    copilot) printf '/home/vscode/.copilot' ;;
    # agy は資格情報（OAuth トークン）を ~/.gemini/antigravity-cli/ へ置くため、
    # gemini と同じディレクトリを共有する。専用の volume を切ると
    # ~/.gemini と ~/.gemini/antigravity-cli の入れ子マウントになる。
    antigravity) printf '/home/vscode/.gemini' ;;
    *)       printf '' ;;
  esac
}

# 永続 volume の名前。ディレクトリを共有する装備は volume 名も共有する。
#
# 名前まで共有しないと、--with-antigravity 単独で作った volume が
# antigravity-storage になり、あとから --with-gemini を足した構成では
# gemini-storage を見に行くことになる。同じ場所を指しているのに別の volume へ
# 切り替わり、ログイン状態が消えたように見える。
ai_storage_name() {
  case "$1" in
    antigravity) printf 'gemini' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# with-set のうち AI ツールだけを選択順に列挙する。
# antigravity は末尾に置く。既存構成の生成結果（install 行の並び）を変えないため。
selected_ai_tools() {
  local t
  for t in claude gemini copilot antigravity; do
    has_with "$t" && printf '%s\n' "$t"
  done
}

# rebuild を跨いで保持する認証・設定ディレクトリを "<name> <dir>" で列挙する。
# name は named volume の接頭辞（${name}-storage）になる。
#
# gh は github-cli feature が構成に依らず常時入るため、常に永続化する。
# 資格情報をホストから注入しなくなった以上、コンテナ内のログインが唯一の認証手段で
# あり、それが rebuild のたびに消えると実用に耐えない。
# cloud（aws / gcloud）は該当の --with-* を選んだときだけ定義する。未選択の構成に
# 使われない volume を作らないため。
#
# gemini と antigravity は同じ "gemini /home/vscode/.gemini" を出すため、両方を
# 選んだ構成では行が重複する。重複したまま流すと volume 定義・マウント・所有権修復・
# 実マウント検査のすべてが 2 行ずつになる（compose は同じ名前の volume を 2 回
# 定義した時点で落ちる）。名前とディレクトリの対で一意化する。
persisted_storages() {
  {
    local t dir
    printf '%s %s\n' gh /home/vscode/.config/gh
    with_feature_active aws && printf '%s %s\n' aws /home/vscode/.aws
    with_feature_active gcp && printf '%s %s\n' gcloud /home/vscode/.config/gcloud
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      dir="$(ai_config_dir "$t")"
      [[ -n "$dir" ]] || continue
      printf '%s %s\n' "$(ai_storage_name "$t")" "$dir"
    done < <(selected_ai_tools)
  } | awk '!seen[$0]++'
}

build_default_gitignore_targets() {
  local targets=()
  targets+=("macOS")
  if has_language "node"; then
    targets+=("Node")
  fi
  if has_language "go"; then
    targets+=("Go")
  fi
  if has_language "python"; then
    targets+=("Python")
  fi
  if has_language "php"; then
    targets+=("PHP")
  fi
  if has_language "rust"; then
    targets+=("Rust")
  fi
  if has_language "ruby"; then
    targets+=("Ruby")
  fi
  printf '%s\n' "${targets[@]}" | awk '!seen[$0]++'
}

build_effective_gitignore_targets() {
  local extra_csv="$GITIGNORE_TARGETS"
  local item
  local extra_targets

  build_default_gitignore_targets

  if [[ -n "$extra_csv" ]]; then
    extra_targets="$(printf '%s' "$extra_csv" | tr ',' ' ')"
    for item in $extra_targets; do
      item="$(echo "$item" | xargs)"
      [[ -n "$item" ]] && printf '%s\n' "$item"
    done
  fi
}

fetch_gitignore_template() {
  local name="$1"
  local url

  url="$GITIGNORE_REPO_RAW_BASE/${name}.gitignore"
  if curl -fsL "$url" 2>/dev/null; then
    return 0
  fi

  url="$GITIGNORE_REPO_RAW_BASE/Global/${name}.gitignore"
  curl -fsL "$url" 2>/dev/null
}

build_remote_gitignore_block() {
  local resolved_targets
  local target
  local tmp

  resolved_targets="$(build_effective_gitignore_targets | awk '!seen[$0]++' | paste -sd' ' -)"

  if [[ -z "$resolved_targets" ]]; then
    return 0
  fi

  {
    printf '%s\n' ""
    printf '%s\n' "# github/gitignore generated ignores"
    printf '%s\n' "# templates: $resolved_targets"

    for target in $resolved_targets; do
      printf '%s\n' ""
      printf '%s\n' "# template: $target"
      tmp="$(mktemp "${TMPDIR:-/tmp}/dcb-gitignore-template.XXXXXX")"
      if fetch_gitignore_template "$target" > "$tmp"; then
        cat "$tmp"
      else
        echo "[bootstrap] WARN: gitignore template not found: $target" >&2
      fi
      rm -f "$tmp"
    done
  } | sed '/^$/N;/^\n$/D'
}

# --with-* で入れた装備が作るファイルの除外を出力する。
#
# github/gitignore のテンプレートは言語・OS・エディタの生成物だけを対象にしており、
# 装備フラグで入れたツールの生成物は含まれない。装備を入れた側が後始末を持たないと、
# 各プロジェクトが同じ行を手書きすることになり、書き漏らしがそのまま機密の混入になる。
#
# 出力は github/gitignore ブロックより後ろへ置く。.gitignore は後に書いた行が勝つため、
# テンプレート側の再包含（! 行）でここの除外が打ち消されない順序にする。
#
# 装備を選んでいない構成へは 1 行も出さない。使わない除外を配ると、その行が何のために
# あるのかを利用者が判断できなくなる。
build_static_gitignore_block() {
  local body

  # 出力する行はそのまま .gitignore へ入るため、展開の起きない引用符付き
  # ヒアドキュメントで literal に書く（* や ** をシェルへ解釈させない）。
  body="$(
    if has_with claude; then
      cat <<'CLAUDE_IGNORES'

# Claude Code (--with-claude)
# .mcp.json はプロジェクトスコープの MCP 設定。トークン方式の MCP サーバを追加すると
# 平文の資格情報がここへ入るため、.env と同じ理由で共有しない。
.mcp.json
# .claude/worktrees/ の中身はリポジトリ全体のチェックアウトそのもので、除外しないと
# git add . でリポジトリが自分自身を抱え込む。.claude/ 配下には追跡する成果物
# （skills/）があるため、.claude/ ごとではなくこのディレクトリだけを除外する。
.claude/worktrees/
CLAUDE_IGNORES
    fi

    if with_feature_active terraform; then
      cat <<'TERRAFORM_IGNORES'

# Terraform (--with-aws / --with-gcp)
# tfstate は機密を平文で保持する。tfvars も同じく機密を含みやすい。
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
# plan の出力は変数の値が解決済みで展開されるため、state / tfvars と同じ理由で
# 機密が載る。-out=tfplan（拡張子なし）が慣用のため、両方の書き方を除外する。
tfplan
*.tfplan
# crash log には実行時の変数値が出ることがある。
crash.log
crash.*.log
# override 系と CLI 設定は端末ごとのローカル上書きで、共有すると他者の実行を変える。
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraformrc
terraform.rc
# .terraform.lock.hcl はプロバイダ版の固定に必要なため、意図して除外しない。
TERRAFORM_IGNORES
    fi
  )"

  [[ -n "$body" ]] || return 0

  printf '%s\n' ""
  printf '%s\n' "# devcontainer-bootstrap owned ignores"
  printf '%s\n' "$body"
}

# 言語ランタイムの存在検査に使うコマンド名を返す。
# 既定は言語名と同一だが、rust は実行ファイルが cargo/rustc に分かれ
# 「rust」という実行ファイルが無いため、代表コマンド cargo へ写像する。
# bash 3.2 互換のため連想配列を使わず case で分岐する。
runtime_check_cmd() {
  case "$1" in
    rust) printf 'cargo' ;;
    *)    printf '%s' "$1" ;;
  esac
}

# 言語ごとの慣習的な受け入れ検証（acceptance）の既定コマンドを返す。
# これは生成時の初期値であり、プロジェクトが acceptance.sh を編集して差し替える前提。
# bash 3.2 互換のため連想配列を使わず case で分岐する。
acceptance_check_cmd() {
  case "$1" in
    node)   printf 'npm test' ;;
    go)     printf 'go test ./...' ;;
    python) printf 'python -m pytest' ;;
    php)    printf 'composer test' ;;
    rust)   printf 'cargo test' ;;
    # ruby はテストフレームワークが Minitest / RSpec に分かれ、単一の慣習的
    # コマンドが無い。Rakefile の default タスクへ委譲し、npm test / composer test
    # と同じ「プロジェクトの設定に従う」形にする。
    ruby)   printf 'bundle exec rake' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# 言語の受け入れ検証を実行する前提となるマニフェストの [[ ]] 条件式を返す。
# ルート直下にマニフェストが存在する対象だけを検証する（存在しなければスキップ）。
# bash 3.2 互換のため連想配列を使わず case で分岐する。
acceptance_manifest_cond() {
  case "$1" in
    node)   printf '[[ -f package.json ]]' ;;
    go)     printf '[[ -f go.mod ]]' ;;
    python) printf '[[ -f pyproject.toml || -f requirements.txt ]]' ;;
    php)    printf '[[ -f composer.json ]]' ;;
    rust)   printf '[[ -f Cargo.toml ]]' ;;
    ruby)   printf '[[ -f Gemfile ]]' ;;
    *)      printf 'false' ;;
  esac
}

# スキップ時に表示するマニフェスト名（人間向け）。
acceptance_manifest_name() {
  case "$1" in
    node)   printf 'package.json' ;;
    go)     printf 'go.mod' ;;
    python) printf 'pyproject.toml / requirements.txt' ;;
    php)    printf 'composer.json' ;;
    rust)   printf 'Cargo.toml' ;;
    ruby)   printf 'Gemfile' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# 受け入れ検証の実行に必要なツール名（command -v で存在確認する対象）を返す。
# runtime_check_cmd と同型だが、実行するコマンドに合わせる（node は npm、php は
# composer、ruby は bundle）。
acceptance_tool_cmd() {
  case "$1" in
    node)   printf 'npm' ;;
    go)     printf 'go' ;;
    python) printf 'python' ;;
    php)    printf 'composer' ;;
    rust)   printf 'cargo' ;;
    ruby)   printf 'bundle' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# マニフェストはあるがツールが無い場合に添える導入手順。
# 「スキップ」と「実行できなかった（失敗）」を混同させないためのメッセージ。
acceptance_install_hint() {
  case "$1" in
    node)   printf 'install Node.js (npm) to run this acceptance check.' ;;
    go)     printf 'install the Go toolchain to run this acceptance check.' ;;
    python) printf 'install Python to run this acceptance check.' ;;
    php)    printf 'install PHP and Composer to run this acceptance check.' ;;
    rust)   printf 'install the Rust toolchain (https://rustup.rs) to run this acceptance check.' ;;
    ruby)   printf 'install Ruby and Bundler (gem install bundler) to run this acceptance check.' ;;
    *)      printf 'install the required toolchain to run this acceptance check.' ;;
  esac
}

# 言語に対応する VS Code の language server 拡張 ID を返す。
# 拡張を持たない言語（node は JS/TS が組み込み、php は有料ティアのある
# サードパーティを避ける）は空文字を返す。
language_extension() {
  case "$1" in
    rust)   printf 'rust-lang.rust-analyzer' ;;
    go)     printf 'golang.go' ;;
    python) printf 'ms-python.python' ;;
    ruby)   printf 'Shopify.ruby-lsp' ;;
    *)      printf '' ;;
  esac
}

# 選択言語ごとの post-rebuild-check 検査行を生成する（配列駆動）。
# 検査コマンドは runtime_check_cmd に一元化する。
build_runtime_check_block() {
  local lang cmd out=""
  for lang in "${LANGUAGES[@]}"; do
    cmd="$(runtime_check_cmd "$lang")"
    out+="command -v $cmd >/dev/null 2>&1 && echo \"[check] $cmd OK\" || echo \"[check] $cmd missing\""$'\n'
  done
  printf '%s' "$out"
}

# 選択言語ごとの acceptance.sh 既定検証行を生成する。
# 各言語について「マニフェストの実在を確認 → ツール検査 → 実行」の構造を出す。
#   - マニフェスト不在: 理由を出してスキップ（失敗させない）。
#   - マニフェストあり・ツール無し: 導入手順を添えて非0で終了（スキップと混同しない）。
#   - 実行できたら ran_any=1 を立てる。1 つも立たなければ呼び出し側の枠組みが失敗させる。
# 検査コマンド・条件・ツール・手順は上の acceptance_* ヘルパへ一元化する。プロジェクトが
# 編集する起点であり、生成時点で緑になることは保証しない（受け入れ条件はプロジェクト固有）。
build_acceptance_check_block() {
  local lang cmd cond mname tool hint out=""
  for lang in "${LANGUAGES[@]}"; do
    cmd="$(acceptance_check_cmd "$lang")"
    cond="$(acceptance_manifest_cond "$lang")"
    mname="$(acceptance_manifest_name "$lang")"
    tool="$(acceptance_tool_cmd "$lang")"
    hint="$(acceptance_install_hint "$lang")"
    out+="if $cond; then"$'\n'
    out+="  command -v $tool >/dev/null 2>&1 || { echo \"[acceptance] ($lang) $tool not found. $hint\" >&2; exit 1; }"$'\n'
    out+="  echo \"[acceptance] ($lang) $cmd\""$'\n'
    out+="  $cmd"$'\n'
    out+="  ran_any=1"$'\n'
    out+="else"$'\n'
    out+="  echo \"[acceptance] ($lang) skip: $mname not found\""$'\n'
    out+="fi"$'\n'
  done
  printf '%s' "$out"
}

# 選択言語のうち拡張を持つものだけを、extensions 配列へ入れる JSON 断片として返す。
# 各エントリは末尾カンマ付き。後段の write_file が末尾カンマ除去（perl）+ jq 整形を
# 行うため、直後に固定拡張が続く限り末尾カンマは安全に処理される。
build_language_extensions_block() {
  local lang ext out=""
  for lang in "${LANGUAGES[@]}"; do
    ext="$(language_extension "$lang")"
    [[ -n "$ext" ]] || continue
    out+="        \"$ext\","$'\n'
  done
  printf '%s' "$out"
}

# 選択した装備の VS Code 拡張を、extensions 配列へ入れる JSON 断片として返す。
# 各エントリは末尾カンマ付き。write_file の末尾カンマ除去（perl）+ jq 整形が畳む。
# cloud（aws/gcp/terraform）は with_feature_active、AI ツールは has_with で判定。
build_with_extensions_block() {
  local out=""
  with_feature_active aws       && out+="        \"amazonwebservices.aws-toolkit-vscode\","$'\n'
  with_feature_active gcp       && out+="        \"GoogleCloudTools.cloudcode\","$'\n'
  with_feature_active terraform && out+="        \"hashicorp.terraform\","$'\n'
  has_with claude  && out+="        \"anthropic.claude-code\","$'\n'
  has_with gemini  && out+="        \"Google.gemini-cli-vscode-ide-companion\","$'\n'
  has_with copilot && out+="        \"github.copilot\","$'\n'
  has_with copilot && out+="        \"github.copilot-chat\","$'\n'
  printf '%s' "$out"
}

# 選択した AI ツールの install 行を生成する（install-ai-tools.sh の __AI_INSTALL_LINES__）。
# トークン分岐は行わない。未選択なら空。
# .env.example の __SECOND_OPINION_ENGINE_LINES__。第二意見のエンジン選択。
#
# 既定は gemini で、指定しなければ挙動は変わらない。したがってこの記入欄が要るのは
# antigravity を選べる構成だけで、--with-antigravity のときだけ出す。
# 常時出すと、agy を導入していない生成物に「選べないエンジン」の記入欄が残る。
build_second_opinion_engine_block() {
  has_with antigravity || { printf ''; return; }
  cat <<'ENGTMPL'

# 第二意見レビューのエンジン（gemini | antigravity）。既定は gemini。
#
# antigravity（Antigravity CLI）は Google アカウントの OAuth 認証で、API キーに
# 対応しない。初回は対話で `agy` を起動してログインすること。GEMINI_API_KEY は
# 使わないため、こちらへ寄せる場合は空のままでよい。
SECOND_OPINION_ENGINE=
ENGTMPL
}

# agy は npm 配布ではないため install_if_missing の同型に乗らない。専用の関数
# （__AGY_FUNCTION_LINES__ が展開する）を呼ぶ。呼び出しは導入とオプトアウトの 2 つ。
build_ai_install_block() {
  local tool spec cmd pkg out=""
  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    if [[ "$tool" == "antigravity" ]]; then
      out+="install_agy_if_missing"$'\n'
      out+="disable_agy_telemetry"$'\n'
      continue
    fi
    spec="$(ai_cli_spec "$tool")"
    cmd="${spec%% *}"
    pkg="${spec#* }"
    out+="install_if_missing $cmd \"$pkg\""$'\n'
  done < <(selected_ai_tools)
  printf '%s' "$out"
}

# install-ai-tools.sh の __AGY_FUNCTION_LINES__。agy の導入とテレメトリ無効化の
# 関数定義。--with-antigravity が無ければ空を返し、生成物に agy 関連は 1 行も
# 入らない。
#
# 内容は開発リポジトリの scripts/install-ai-tools.sh と同じ性質を持たせる
# （tests/test-agy-install-mirror.sh が関数本体のバイト一致を照合する）。
build_agy_block() {
  has_with antigravity || { printf ''; return; }
  cat <<'AGYTMPL'
# agy（Antigravity CLI）は npm 配布ではないため install_if_missing の同型に乗らない。
# 配布元のインストーラを取得して実行し、~/.local/bin/agy へ置く。
#
# 認証は OAuth のみで、API キーには対応しない。導入だけでは使えず、初回に
# 対話で `agy` を起動して Google アカウントへログインする必要がある。資格情報は
# ~/.gemini/antigravity-cli/ 配下に置かれ、この devcontainer では ~/.gemini が
# named volume（gemini-storage）なので rebuild しても消えない。
install_agy_if_missing() {
  if command -v agy >/dev/null 2>&1; then
    echo "[install-ai-tools] agy already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing agy (Antigravity CLI) ..."
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  # インストーラは ~/.local/bin へ置く。PATH に無ければ、導入直後の同一シェルからは
  # 見えない。これは失敗ではないので、次に何をすればよいかを言うに留める。
  #
  # ただし「PATH に無いだけ」と「そもそも置かれていない」を取り違えない。実体の
  # 有無で分ける。curl 自体の失敗は set -e + pipefail が捕まえるが、インストーラが
  # 0 で終わりながらバイナリを置かない経路はそれをすり抜ける。取り違えると、導入に
  # 失敗しているのに成功として先へ進む。
  if command -v agy >/dev/null 2>&1; then
    echo "[install-ai-tools] agy installed: $(command -v agy)"
  elif [[ -x "$HOME/.local/bin/agy" ]]; then
    echo "[install-ai-tools] agy installed to ~/.local/bin (PATH に無いため現シェルからは見えません)"
  else
    echo "[install-ai-tools] error: インストーラは完了しましたが agy が見つかりません" >&2
    echo "                   ~/.local/bin/agy が存在しません。導入は失敗しています。" >&2
    return 1
  fi
  echo "[install-ai-tools] agy は OAuth のみです。初回は対話で 'agy' を起動してログインしてください。"
}

# agy のテレメトリ（利用統計・クラッシュログ・対話ログの送信）を既定で止める。
#
# 環境変数によるオプトアウトは存在しない（agy 1.1.11 のバイナリを実測。AGY_* は
# 自動更新・描画・認証まわりのみで、テレメトリ系は無い。DO_NOT_TRACK も非対応）。
# したがって設定ファイルへ書く以外の手段が無い。キーは enableTelemetry（既定 true）。
#
# 上書きではなくマージする。このファイルは agy 自身も書き込む（colorScheme /
# trustedWorkspaces 等）ため、丸ごと置き換えると利用者の設定が消える。
#
# 導入の有無に関わらず毎回通す。「導入したときだけ」にすると、先に手で入れた
# 環境や、既存コンテナへ後追いで適用したい場合にオプトアウトが効かない。
AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

disable_agy_telemetry() {
  local dir tmp current
  dir="$(dirname "$AGY_SETTINGS")"

  # jq が無い場合に「黙って未適用」で先へ進めない。オプトアウトが効いていない
  # ことに誰も気づけないまま、送信だけが続く状態になる。
  if ! command -v jq >/dev/null 2>&1; then
    echo "[install-ai-tools] error: jq が無いため agy のテレメトリを無効化できません" >&2
    echo "                   jq を導入してから再実行してください: bash scripts/install-ai-tools.sh" >&2
    return 1
  fi

  mkdir -p "$dir"
  if [[ ! -e "$AGY_SETTINGS" ]]; then
    printf '{}\n' > "$AGY_SETTINGS"
    chmod 600 "$AGY_SETTINGS"
  fi

  # 壊れた JSON を黙って {} で置き換えない。利用者の設定を捨てることになる。
  if ! jq -e . "$AGY_SETTINGS" >/dev/null 2>&1; then
    echo "[install-ai-tools] error: JSON として読めないため書き換えを中止しました: $AGY_SETTINGS" >&2
    echo "                   内容を修復するか退避してから再実行してください（オプトアウトは未適用です）" >&2
    return 1
  fi

  # 冪等。既に false なら書き込まない（mtime も動かさない）。
  #
  # `// empty` は使わない。jq の `//` は null だけでなく **false も** 代替側へ
  # 落とすため、既に false のときに「未設定」と区別できず、毎回書き込みが起きる。
  # 値をそのまま出す（未設定なら null が出る）。
  current="$(jq -r '.enableTelemetry' "$AGY_SETTINGS")"
  if [[ "$current" == "false" ]]; then
    echo "[install-ai-tools] agy telemetry already disabled, skipping"
    return 0
  fi

  # 一時ファイルへ書いて mv で差し替える。`jq ... > 同じファイル` はリダイレクトが
  # 先に空へ切り詰めるため、設定が消える。一時ファイルは同じディレクトリに作る
  # （/tmp は別ファイルシステムのことがあり、その場合 mv が原子的にならない）。
  # テンプレートを明示するのは BSD 系の mktemp が必須とするため。
  tmp="$(mktemp "$dir/.settings.json.XXXXXX")"
  # jq が落ちたら一時ファイルを残さない。作成先が設定ディレクトリ直下なので、
  # 失敗のたびに .settings.json.XXXXXX が積み上がり、利用者の設定ディレクトリを
  # 汚し続ける（set -e で即座に抜けるため、後始末の機会もここしかない）。
  if ! jq '.enableTelemetry = false' "$AGY_SETTINGS" > "$tmp"; then
    rm -f "$tmp"
    echo "[install-ai-tools] error: settings.json の書き換えに失敗しました: $AGY_SETTINGS" >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$AGY_SETTINGS"
  echo "[install-ai-tools] agy telemetry disabled (enableTelemetry=false)"
}
AGYTMPL
}

# 永続 volume のマウント先の所有権修復行を生成する
# （fix-mount-owner.sh の __MOUNT_OWNER_LINES__）。空の named volume を root:root で
# 初回マウントした際の書き込み不能を復旧する。対象は AI ツールに限らない。
# gh / cloud も永続化するため、ここが漏れると 'gh auth login' が Permission denied で
# 落ち、永続化の意味が無くなる。
build_mount_owner_block() {
  local name dir out=""
  while read -r name dir; do
    [[ -n "$name" ]] || continue
    out+="fix_mount \"$dir\""$'\n'
  done < <(persisted_storages)
  printf '%s' "$out"
}

# compose の app.volumes に足す永続 volume のマウント行（__VOLUME_MOUNTS__）。
# gh は常時、cloud と AI ツールは選択に応じて並ぶ。
build_volume_mounts_block() {
  local name dir out=""
  while read -r name dir; do
    [[ -n "$name" ]] || continue
    out+="      - ${name}-storage:${dir}"$'\n'
  done < <(persisted_storages)
  printf '%s' "$out"
}

# compose のトップレベル volumes: セクション（__VOLUME_SECTION__）。
# gh-storage が常に入るため、このセクションが空になることはない。
build_volume_section_block() {
  local name defs=""
  # volume 名しか使わないので、2 列目（マウント先）は読み捨てる。
  while read -r name _; do
    [[ -n "$name" ]] || continue
    defs+="  ${name}-storage:"$'\n'
  done < <(persisted_storages)
  [[ -n "$defs" ]] || { printf ''; return; }
  printf 'volumes:\n%s' "$defs"
}

# post-rebuild-check.sh の __VOLUME_CHECK_LINES__。永続 volume が実際にマウント
# されているかを検査する。定義しただけでマウントされない（compose の編集ミス、
# devcontainer.json が別サービスを指している等）と、ログイン状態は毎回消えるのに
# CLI は入っているため、原因が分かりにくい形で表面化する。
build_volume_check_block() {
  local name dir out=""
  while read -r name dir; do
    [[ -n "$name" ]] || continue
    out+="check_mounted \"$dir\" \"${name}-storage\""$'\n'
  done < <(persisted_storages)
  printf '%s' "$out"
}

# post-rebuild-check.sh の __WITH_CHECK_LINES__。選択した cloud/AI の CLI を検査する。
build_with_check_block() {
  local out=""
  local checks="" name cmd
  # 表示順: cloud（aws gcp terraform）→ AI（claude gemini copilot）
  with_feature_active aws       && checks+="aws "
  with_feature_active gcp       && checks+="gcloud "
  with_feature_active terraform && checks+="terraform "
  has_with claude  && checks+="claude "
  has_with gemini  && checks+="gemini "
  has_with copilot && checks+="copilot "
  has_with antigravity && checks+="agy "
  for cmd in $checks; do
    out+="command -v $cmd >/dev/null 2>&1 && echo \"[check] $cmd OK\" || echo \"[check] $cmd missing\""$'\n'
  done
  printf '%s' "$out"
}

render_content() {
  local content="$1"
  local sed_args=()
  local escaped_base_image

  # 行単位プレースホルダを awk で差し替える。sed や bash のパターン置換は使わない:
  # 挿入内容が `&`（検査行の `2>&1` / `&&`）を含み、sed の置換記号や Bash 5.1+ の
  # `${//}` 置換で `&` が「マッチ全体」に化けるため（`\&` エスケープは bash 3.2 で
  # 効かず非互換）。ENVIRON 経由 + printf は `&` を素通しし bash 3.2 互換。
  #
  # ブロックは $(...) を通る過程で末尾改行が剥がれる。非空なら改行を 1 つ補って出力し、
  # 空なら行ごと消す。これをしないと、直後の行（別のプレースホルダや YAML の command:、
  # シェルの次コマンド）が同一行へ癒着する（隣接プレースホルダは 2 つ目が一致しなくなる）。
  subst_block() {
    local placeholder="$1" block="$2"
    content="$(PH="$placeholder" BLK="$block" awk '
      $0 == ENVIRON["PH"] { if (length(ENVIRON["BLK"]) > 0) printf "%s\n", ENVIRON["BLK"]; next }
      { print }
    ' <<<"$content")"
  }

  subst_block __RUNTIME_CHECK_LINES__ "$(build_runtime_check_block)"
  subst_block __ACCEPTANCE_CHECK_LINES__ "$(build_acceptance_check_block)"
  subst_block __LANGUAGE_EXTENSIONS__ "$(build_language_extensions_block)"
  subst_block __WITH_EXTENSIONS__ "$(build_with_extensions_block)"
  subst_block __MOUNT_OWNER_LINES__ "$(build_mount_owner_block)"
  subst_block __SECOND_OPINION_ENGINE_LINES__ "$(build_second_opinion_engine_block)"
  subst_block __AGY_FUNCTION_LINES__ "$(build_agy_block)"
  subst_block __AI_INSTALL_LINES__ "$(build_ai_install_block)"
  subst_block __VOLUME_MOUNTS__ "$(build_volume_mounts_block)"
  subst_block __VOLUME_SECTION__ "$(build_volume_section_block)"
  subst_block __VOLUME_CHECK_LINES__ "$(build_volume_check_block)"
  subst_block __WITH_CHECK_LINES__ "$(build_with_check_block)"

  escaped_base_image="$BASE_IMAGE"
  escaped_base_image="${escaped_base_image//&/\\&}"

  sed_args+=(-e "s|__PROJECT_NAME__|$PROJECT_NAME|g")
  sed_args+=(-e "s|__BASE_IMAGE__|$escaped_base_image|g")
  for lang in node go python php rust ruby; do
    local lang_upper lang_options
    lang_upper=$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')
    if has_language "$lang"; then
      # 既定は素の feature（options 無し）。python だけは uv を同梱する。
      # python feature には uv 専用オプションが無いため、pipx 導入の toolsToInstall
      # に uv を追記する。toolsToInstall は上書き（既定リストを置換）なので、既定
      # ツール群を明記した上で uv を足し、既定ツールの回帰を避ける。
      lang_options='{}'
      if [ "$lang" = "python" ]; then
        lang_options='{ "installTools": true, "toolsToInstall": "flake8,autopep8,black,yapf,mypy,pydocstyle,pycodestyle,bandit,pipenv,virtualenv,pytest,pylint,uv" }'
      fi
      sed_args+=(-e "s|\"__IF_RUNTIME_${lang_upper}__\": \"ghcr.io/devcontainers/features/$lang:1\"|\"ghcr.io/devcontainers/features/$lang:1\": $lang_options|g")
    else
      sed_args+=(-e "/\"__IF_RUNTIME_${lang_upper}__\"/d")
    fi
  done
  # cloud feature（aws/gcp/terraform）を with-set に応じて配線する。言語と同型だが
  # feature path が名前と 1 対 1 でないため with_feature_path で解決する。terraform は
  # with_feature_active により「aws または gcp」で有効化される。sed 区切りは path に
  # 含まれる / を避けて | を使う（path に | は無い）。
  local wf wf_upper wf_path
  for wf in aws gcp terraform; do
    wf_upper=$(printf '%s' "$wf" | tr '[:lower:]' '[:upper:]')
    wf_path="$(with_feature_path "$wf")"
    if with_feature_active "$wf"; then
      sed_args+=(-e "s|\"__IF_WITH_${wf_upper}__\": \"$wf_path\"|\"$wf_path\": {}|g")
    else
      sed_args+=(-e "/\"__IF_WITH_${wf_upper}__\"/d")
    fi
  done
  printf '%s' "$content" | sed "${sed_args[@]}"
}

build_gitignore_block() {
  local remote_block="" static_block=""

  remote_block="$(build_remote_gitignore_block)"
  static_block="$(build_static_gitignore_block)"
  if [[ -n "$remote_block" ]]; then
    printf '%s\n' "$remote_block"
  fi
  if [[ -n "$static_block" ]]; then
    printf '%s\n' "$static_block"
  fi
}

upsert_gitignore() {
  local gitignore_path="$OUTPUT_DIR/.gitignore"
  local tmp block prev_mode=""

  block="$(build_gitignore_block)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcb-gitignore-block.XXXXXX")"

  [[ -f "$gitignore_path" ]] && prev_mode="$(file_mode_octal "$gitignore_path")"

  if [[ -f "$gitignore_path" ]]; then
    awk -v start="$GITIGNORE_BEGIN" -v end="$GITIGNORE_END" '
      $0 == start {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    ' "$gitignore_path" > "$tmp"
    if [[ -s "$tmp" ]]; then
      printf '\n' >> "$tmp"
    fi
  fi

  {
    printf '%s\n' "$GITIGNORE_BEGIN"
    printf '%s\n' "$block"
    printf '%s\n' "$GITIGNORE_END"
  } >> "$tmp"

  # mktemp は 0600 で作成し mv がそれを維持するため、既存 .gitignore のモードを
  # 潰してしまう。元のモードを復元し、644 は新規作成したファイルにのみ使う。
  mv "$tmp" "$gitignore_path"
  chmod "${prev_mode:-644}" "$gitignore_path"
  echo "write: $gitignore_path (managed section)"
}

# ── 共通 AI ルール（ai-playbook）の配布 ───────────────────────────────────
# このスクリプトはルールの配布のみを担う。内容の正本は別リポジトリ ai-playbook が持つ。

# ファイルの 8 進パーミッションを返す。判定できない場合は空を返す。
# GNU coreutils は -c、BSD/macOS は -f を使う。GNU は -f も受け付けるが
# --file-system の意味になり無関係な出力を返すため、結果が 8 進数字で
# あることを検証してから採用する。
file_mode_octal() {
  local mode
  for mode in \
    "$(stat -c %a "$1" 2>/dev/null || true)" \
    "$(stat -f %Lp "$1" 2>/dev/null || true)"; do
    case "$mode" in
      '' | *[!0-7]* ) ;;
      * ) printf '%s' "$mode"; return 0 ;;
    esac
  done
  printf ''
}

should_install_playbook() {
  # --with-playbook は明示 opt-in。加えて、--playbook-from / --playbook-version で
  # ソースを指定した時点で配置意図は明確なため、--with-playbook 省略でも配置する
  # （--playbook-version は PLAYBOOK_FROM へ展開済み）。ただし --without-playbook は
  # 明示 opt-out として最優先で尊重する。
  [[ "$WITH_PLAYBOOK" == "false" ]] && return 1
  [[ "$WITH_PLAYBOOK" == "true" ]] && return 0
  [[ -n "$PLAYBOOK_FROM" ]]
}

# 規範ルートを、規範パッケージの内部ファイル名に依存せず構造だけで決める。
# アンカーは DCB 自身の設置規約である .ai-playbook ディレクトリ名のみ。
# base（アーカイブ展開先、または指定ディレクトリ）を見て:
#   1) .ai-playbook/ を含むなら、それをルート（入れ子アーカイブ・モノレポ併設・親指定）。
#   2) 直下がラッパー 1 ディレクトリのみ（通常ファイルなし）なら、それをルート
#      （GitHub archive 形式。ルート = .ai-playbook の中身が ai-playbook-<ver>/ 直下に並ぶ）。
#   3) それ以外（フラット展開、複数エントリ、直下にファイルあり）は base 自身をルート
#      （チェックアウト直下・手製フラット tarball）。
# いずれも規範の有無は判定しない。空ソースは呼び出し側の「規範 0 件」検査で弾く。
resolve_playbook_root() {
  # 末尾スラッシュを落とす。base を規範ルートとして返す経路で、後段の
  # rel="${src#"$common_dir"/}" が二重スラッシュになりプレフィックス除去に失敗する
  # （相対パスにフルパスが残り、配置先が壊れる）のを防ぐ。
  local base="${1%/}" nested dirs files
  [[ -n "$base" ]] || base="/"
  # `find ... | head -n 1` にはしない。head は 1 行目で終了してパイプを閉じるため、
  # まだ書き込み中の find が SIGPIPE で死に、pipefail 下でパイプライン全体が 141 に
  # なる。BSD find（macOS）はこの経路を通り、GNU find は EPIPE を握って 0 で終わる
  # ため、Linux では再現しない差になる。find 自身を -quit で止めればパイプが要らない。
  nested="$(find "$base" -type d -name '.ai-playbook' -print -quit 2>/dev/null)"
  if [[ -n "$nested" ]]; then
    printf '%s' "$nested"
    return
  fi
  dirs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  files="$(find "$base" -mindepth 1 -maxdepth 1 ! -type d | wc -l | tr -d ' ')"
  if [[ "$dirs" -eq 1 && "$files" -eq 0 ]]; then
    find "$base" -mindepth 1 -maxdepth 1 -type d -print -quit
  else
    printf '%s' "$base"
  fi
}

# playbook ディレクトリを、パス・URL・同階層チェックアウトのいずれかから解決する。
# $2 は呼び出し側が所有する作業ディレクトリで、URL の場合にのみ使う。作成と後始末は
# 呼び出し側の責務とする: この関数はコマンド置換の中で実行されるため、ここで trap を
# 登録するとそのサブシェルで発火し、展開したファイルを即座に削除してしまう。
detect_playbook_dir() {
  local source_hint="$1"
  local tmp_root="${2:-}"
  local archive_file extract_dir found candidate

  if [[ -n "$source_hint" ]]; then
    if [[ "$source_hint" =~ ^https?:// ]]; then
      require_cmd curl
      require_cmd tar
      [[ -n "$tmp_root" ]] || {
        echo "error: internal: scratch dir not provided for URL source" >&2
        exit 1
      }
      archive_file="$tmp_root/playbook.tar.gz"
      # ダウンロードした tarball と展開結果を混ぜない。混ぜると展開直下の
      # ファイル数判定に playbook.tar.gz が混入し、ルート判定を誤る。
      extract_dir="$tmp_root/extract"
      mkdir -p "$extract_dir"
      # curl / tar の失敗は明示的に検査する。この関数は
      # PLAYBOOK_DIR="$(detect_playbook_dir ...)" の代入コマンド置換で呼ばれ、
      # 代入 RHS のコマンド置換では set -e が発火しない（bash の既知の挙動）。
      # 検査を省くと 404 等の取得失敗でも後続が進み、ファイルを書いてから遅れて
      # 失敗する（README のアトミック配置の約束が破れる）。
      if ! curl -fsSL "$source_hint" -o "$archive_file"; then
        echo "error: failed to download playbook archive: $source_hint" >&2
        if [[ -n "$PLAYBOOK_VERSION" ]]; then
          echo "       指定した --playbook-version '$PLAYBOOK_VERSION' のタグが存在するか確認してください（'v' 接頭辞が要る場合があります。例: v0.1.1）。" >&2
        fi
        exit 1
      fi
      if ! tar -xzf "$archive_file" -C "$extract_dir" 2>/dev/null; then
        echo "error: failed to extract playbook archive (not a valid .tar.gz?): $source_hint" >&2
        exit 1
      fi
      found="$(resolve_playbook_root "$extract_dir")"
      [[ -n "$found" ]] || {
        echo "error: no playbook directory found in archive: $source_hint" >&2
        exit 1
      }
      printf '%s' "$found"
      return
    fi

    if [[ -d "$source_hint" ]]; then
      printf '%s' "$(resolve_playbook_root "$source_hint")"
      return
    fi

    echo "error: --playbook-from not found: $source_hint" >&2
    exit 1
  fi

  for candidate in \
    "$SCRIPT_DIR/../../.ai-playbook" \
    "$SCRIPT_DIR/../../../.ai-playbook"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done

  printf ''
}

apply_file_with_policy() {
  local src="$1" dest="$2" answer prev_mode

  mkdir -p "$(dirname "$dest")"

  if [[ ! -f "$dest" ]]; then
    cp "$src" "$dest"
    # 取得元は mktemp 由来（0600）。新規作成するファイルは他と同様に読めるようにする。
    chmod 644 "$dest"
    echo "write: $dest"
    return 0
  fi

  # 既存ファイルを上書きする場合は、そのモードを変えてはならない。
  prev_mode="$(file_mode_octal "$dest")"
  prev_mode="${prev_mode:-644}"

  case "$PLAYBOOK_CONFLICT_POLICY" in
    skip)
      echo "skip (exists): $dest"
      ;;
    overwrite)
      cp "$src" "$dest"
      chmod "$prev_mode" "$dest"
      echo "write: $dest (overwrite)"
      ;;
    prompt)
      read -r -p "File exists: $dest. Overwrite? [y/N]: " answer
      if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        cp "$src" "$dest"
        chmod "$prev_mode" "$dest"
        echo "write: $dest (overwrite)"
      else
        echo "skip (declined): $dest"
      fi
      ;;
  esac
}

# 入口ファイルとレビュースクリプトの雛形は、規範パッケージが持つ。
# DCB は配置するだけで内容を持たない。内容を持つと正本が 2 つになり、規範側の
# 変更に追随できずにずれる。
require_playbook_template() {
  local name="$1" path
  path="$PLAYBOOK_DIR/templates/$name"
  [[ -f "$path" ]] || {
    echo "error: template not found in rules source: templates/$name" >&2
    echo "       規範パッケージがこの版に必要な雛形を持っていません。" >&2
    exit 1
  }
  printf '%s' "$path"
}

# どのファイルも書き込む前に一度だけ解決し、不正なソースは副作用なしで失敗させる。
# コマンド置換の中ではなく必ずメインシェルから呼ぶことで、後始末の trap が
# 展開ファイルをまだ必要とするプロセス自身に属するようにする。
resolve_playbook_source_or_die() {
  if [[ "$PLAYBOOK_FROM" =~ ^https?:// ]]; then
    PLAYBOOK_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-playbook.XXXXXX")"
    trap 'rm -rf "$PLAYBOOK_TMP_ROOT"' EXIT
  fi

  # detect_playbook_dir の失敗（curl/tar 失敗・ソース不在）を、書き込み前に確実に
  # 捕捉する。`if ! var="$(...)"` は代入 RHS のコマンド置換の終了コードを見るため、
  # set -e が発火しない代入でも取りこぼさない。具体的な理由は detect 側が stderr へ出す。
  if ! PLAYBOOK_DIR="$(detect_playbook_dir "$PLAYBOOK_FROM" "$PLAYBOOK_TMP_ROOT")"; then
    exit 1
  fi
  if [[ -z "$PLAYBOOK_DIR" ]]; then
    echo "error: playbook source not found. specify --playbook-from <path|url> or --playbook-version <tag>." >&2
    exit 1
  fi
  # 取得できても規範（*.md）が 0 件なら、ファイルを書く前に失敗させる。
  # install_playbook_rules も同種の検査を持つが、そちらは書き込み後に走るため、
  # アトミック配置の約束（取得元が解決できなければ 1 つも書かない）をここで守る。
  # `| grep -q .` にはしない。grep -q は最初のマッチで終了してパイプを閉じ、まだ
  # 書き込み中の find が SIGPIPE で死ぬ。pipefail 下ではパイプライン全体が 141 に
  # なり、**grep が実際にはマッチしているのに** 0 件と判定される。macOS で
  # `--playbook-version` が必ず失敗する原因がこれだった（PIPESTATUS=141 0 を実測）。
  if [[ -z "$(find "$PLAYBOOK_DIR" -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
    echo "error: no rule files found in playbook source: ${PLAYBOOK_FROM:-<adjacent checkout>}" >&2
    exit 1
  fi
}

# クロスモデル二段ゲートの第二意見レビュアー。規範はルールパッケージ側
# （review-workflow.md）にあり、これはその実行側にあたる。
install_playbook_rules() {
  local common_dir="$PLAYBOOK_DIR" rel dest tmp count=0

  echo "[bootstrap] shared AI rules from: $common_dir"

  # 配布ルート直下の README.md / CHANGELOG.md はパッケージ自身の説明と変更履歴で
  # あり、利用者が取り込む規範ではない。フラット化で規範と同階層に並ぶため、
  # 明示的に除外する。
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    rel="${src#"$common_dir"/}"
    [[ "$rel" == "README.md" || "$rel" == "CHANGELOG.md" ]] && continue
    dest="$OUTPUT_DIR/$PLAYBOOK_REL_ROOT/$rel"
    apply_file_with_policy "$src" "$dest"
    count=$((count + 1))
  done < <(find "$common_dir" -type f -name '*.md' | sort)

  # ルールを 1 件も配置していないのに成功を報告すると、入口ファイルが存在しない
  # ファイルを指したままになる。静かな no-op ではなく失敗として扱う。
  if [[ "$count" -eq 0 ]]; then
    echo "error: no rule files found under $common_dir" >&2
    exit 1
  fi
  echo "[bootstrap] shared AI rules: $count file(s)"

  # 雛形は規範パッケージから取る。DCB はどこへ置くかだけを決める。
  local tpl
  tpl="$(require_playbook_template project-ai-rules.md)"
  apply_file_with_policy "$tpl" "$OUTPUT_DIR/.github/project-ai-rules.md"

  # 入口ファイルは実行環境ごとに 1 つ。内容は同一で、雛形も 1 つ。
  tpl="$(require_playbook_template entry.md)"
  apply_file_with_policy "$tpl" "$OUTPUT_DIR/CLAUDE.md"
  apply_file_with_policy "$tpl" "$OUTPUT_DIR/.github/copilot-instructions.md"

  tpl="$(require_playbook_template second-opinion-review.sh)"
  apply_file_with_policy "$tpl" "$OUTPUT_DIR/scripts/second-opinion-review.sh"
  if [[ -f "$OUTPUT_DIR/scripts/second-opinion-review.sh" ]]; then
    chmod +x "$OUTPUT_DIR/scripts/second-opinion-review.sh"
  fi

  # リモート最終ゲートの雛形は、その機構を明示選択した場合のみ配置する。
  # 規範（review-workflow.md）はベンダー中立で「1 回に限定される機構なら自動でよい」
  # とだけ述べ、具体機構は選択時に雛形として置く分離を守る。
  #
  # 判定は --with-copilot ではなく --with-copilot-review で行う。前者はローカルの
  # 開発ツール（CLI・拡張・永続 volume）を配線するフラグで、リモートのレビュー機構
  # とは効く場所が違う。1 つのフラグで両方を制御すると、リモートのゲートだけを
  # 使う構成が機構で表現できない（issue #230）。
  #
  # 雛形は 2 本で 1 組。copilot-review.yml が要求し、review-gate.yml が要求された
  # ことを別の契機（PR 更新・定期実行）から確認する。要求側の契機は届かないことが
  # あり、届かなければ最終ゲートが黙って抜けるため、確認側だけを落として配置する
  # 選択肢は持たせない（規範 review-workflow.md「要求されたことを別の契機で確認する」）。
  if has_with copilot-review; then
    tpl="$(require_playbook_template copilot-review.yml)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.github/workflows/copilot-review.yml"
    tpl="$(require_playbook_template review-gate.yml)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.github/workflows/review-gate.yml"
  fi

  # Claude Code 向け intake 起点スキル。--with-claude を選んだときだけ配置する
  # （選ばなければ .claude/ を作らない）。雛形は規範パッケージが持ち、DCB は置き先
  # だけを決める。Claude Code の機構がスキル定義ファイル名を SKILL.md に固定するため、
  # lower-kebab-case の雛形名から改名して配置する（shared-ai-rules.md 8 章の例外）。
  if has_with claude; then
    tpl="$(require_playbook_template claude-skill-intake.md)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.claude/skills/intake/SKILL.md"

    # 委譲先の model / tools を frontmatter で固定するエージェント定義。同じく
    # --with-claude のときだけ置く。指示文で「haiku を使う」と書いても迂回できるが、
    # frontmatter は実行環境が読む機構なので迂回できない（規範 12 章）。
    #
    # 判定の導線は規範の共通層（shared-ai-rules.md 13 章「実装委譲パターン」）が持つ。
    # 定義だけを配ると、判定から到達できない役割が生成先へ残る。
    tpl="$(require_playbook_template claude-agent-explorer.md)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.claude/agents/explorer.md"
    tpl="$(require_playbook_template claude-agent-implementer.md)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.claude/agents/implementer.md"
  fi

  # 導入した規範のソースを on-disk に記録する。これがないと、生成後の環境から
  # 「どのバージョンの playbook を取り込んだか」を証跡で照合できない
  # （自己診断の F-7）。--playbook-version 指定時はそのタグを、ローカル/URL を
  # 直接指定した場合は解決したソースを残す。
  write_playbook_version_file
}

# .ai-playbook/VERSION を生成する。version はタグが分かる場合のみ、source は
# 常に解決済みソースを記録する。機械可読な key=value 形式にする。
write_playbook_version_file() {
  local dest="$OUTPUT_DIR/$PLAYBOOK_REL_ROOT/VERSION" tmp
  local ver="${PLAYBOOK_VERSION:-(unspecified)}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcb-playbook-version.XXXXXX")"
  {
    echo "# devcontainer-bootstrap が記録した ai-playbook のソース情報。"
    echo "# version は --playbook-version 指定時のタグ。未指定なら (unspecified)。"
    echo "version=$ver"
    echo "source=${PLAYBOOK_FROM:-<adjacent checkout>}"
  } > "$tmp"
  # 規範ファイルと同じ衝突ポリシー（skip/overwrite/prompt）に従わせる。既存を skip
  # した規範を更新していないのに VERSION だけ無条件上書きすると、記録が実際の
  # on-disk 規範とずれて出所が嘘になる。専用分岐を持たず既存機構を再利用する。
  apply_file_with_policy "$tmp" "$dest"
  rm -f "$tmp"
}

write_file() {
  local rel="$1" content="$2" out tmp
  out="$OUTPUT_DIR/$rel"
  if [[ -e "$out" && "$FORCE" != "true" ]]; then
    echo "skip (exists): $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcb-render.XXXXXX")"
  render_content "$content" > "$tmp"
  if [[ "$out" == *.json ]]; then
    perl -0777 -i -pe 's/,\s*([}\]])/$1/g' "$tmp"
    jq . "$tmp" > "$out"
    rm -f "$tmp"
  else
    mv "$tmp" "$out"
  fi
  # mktemp は 0600 で作成し mv がそれを維持するため、生成ファイルが読めるよう正規化する。
  chmod 644 "$out"
  [[ "$out" == *.sh ]] && chmod +x "$out"
  echo "write: $out"
}

# ── メイン処理 ──────────────────────────────────────────────────────────────────────

# --with-copilot-review が配置するのは規範パッケージの雛形だけなので、規範を配置
# しない構成では供給元そのものが無い。require_playbook_template に任せると、規範や
# 入口ファイルを書いたあとで停止し、中途半端な生成物が残る（実測済みの既存挙動）。
# 取得元が解決できなければ 1 つも書かない（v0.4.2）に揃え、書き込み前のここで落とす。
#
# 判定条件は should_install_playbook をそのまま使う。配置は --with-playbook だけで
# なく --playbook-from / --playbook-version でも成立するため、条件を書き写すと
# 「ソース指定だけで配置した構成」を誤って弾く形でずれる。
#
# 検査をここへ置くのは、引数解析の直後では has_with / should_install_playbook が
# まだ定義されていないため。ファイルを 1 つも書いていない点は同じで、アトミック
# 停止の約束は満たす（--dry-run も同じ経路を通り、計画を出す前に落ちる）。
if has_with copilot-review && ! should_install_playbook; then
  echo "error: --with-copilot-review は規範の配置を前提とします。" >&2
  echo "       配置するワークフローの雛形は規範パッケージが持つため、規範を配置しない構成では供給元がありません。" >&2
  echo "       --with-playbook / --playbook-version <tag> / --playbook-from <path|url> のいずれかを併せて指定してください。" >&2
  echo "       （--without-playbook を指定している場合は、両立しないためどちらかを外してください）" >&2
  exit 1
fi

echo "[bootstrap] languages=${LANGUAGES[*]} with=${WITH_SET[*]:-(none)}"
echo "[bootstrap] output=$OUTPUT_DIR"

# ルールソースが指定されたのに使用不能な場合は、何かを書き込む前に失敗させる。
if should_install_playbook; then
  resolve_playbook_source_or_die
fi

# 生成する相対パスを収集してソートする（bash 3 互換）。無条件ぶん（template_rel_paths）と
# --with-* 条件ぶん（conditional_template_rel_paths）を 1 つの一覧へまとめる。ここで
# 合流させるので、dry-run の計画と実際の書き込みは条件付きファイルでも一致する。
sorted_rels="$( { template_rel_paths; conditional_template_rel_paths; } | sort)"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[bootstrap] dry-run: no files will be written"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    echo "plan: $OUTPUT_DIR/$rel"
  done <<EOF
$sorted_rels
EOF

  if [[ "$MANAGE_GITIGNORE" == "true" ]]; then
    echo "plan: $OUTPUT_DIR/.gitignore (managed section update)"
    if [[ -n "$GITIGNORE_TARGETS" ]]; then
      echo "plan: github/gitignore templates = implicit + $GITIGNORE_TARGETS"
    else
      echo "plan: github/gitignore templates = implicit (macOS + language-based)"
    fi
  fi

  if should_install_playbook; then
    echo "plan: shared AI rules from $PLAYBOOK_DIR"
    while IFS= read -r src; do
      [[ -n "$src" ]] || continue
      rel="${src#"$PLAYBOOK_DIR"/}"
      [[ "$rel" == "README.md" || "$rel" == "CHANGELOG.md" ]] && continue
      echo "plan: $OUTPUT_DIR/$PLAYBOOK_REL_ROOT/$rel"
    done < <(find "$PLAYBOOK_DIR" -type f -name '*.md' | sort)
    echo "plan: $OUTPUT_DIR/.github/project-ai-rules.md"
    echo "plan: $OUTPUT_DIR/CLAUDE.md"
    echo "plan: $OUTPUT_DIR/.github/copilot-instructions.md"
    echo "plan: $OUTPUT_DIR/scripts/second-opinion-review.sh"
    if has_with copilot-review; then
      echo "plan: $OUTPUT_DIR/.github/workflows/copilot-review.yml"
      echo "plan: $OUTPUT_DIR/.github/workflows/review-gate.yml"
    fi
    if has_with claude; then
      echo "plan: $OUTPUT_DIR/.claude/skills/intake/SKILL.md"
      echo "plan: $OUTPUT_DIR/.claude/agents/explorer.md"
      echo "plan: $OUTPUT_DIR/.claude/agents/implementer.md"
    fi
    echo "plan: $OUTPUT_DIR/$PLAYBOOK_REL_ROOT/VERSION"
  fi
  exit 0
fi

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  write_file "$rel" "$(get_template_content "$rel")"
done <<EOF
$sorted_rels
EOF

if [[ "$MANAGE_GITIGNORE" == "true" ]]; then
  upsert_gitignore
fi

if should_install_playbook; then
  install_playbook_rules
fi

echo "[bootstrap] completed"
