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
# --with-* で選択された装備（cloud / AI ツール）の集合。空既定。
# 例: aws gcp claude gemini copilot。has_with で参照する。
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
  cat <<'EOF'
usage: bash bootstrap.sh [options]

options:
  --project-name <name>       Project name for devcontainer display name (required)
  --languages <csv>           Language runtimes (CSV: node,go,python,php,rust) (required)
  --with-aws                  Install AWS CLI + Terraform (feature/extension)
  --with-gcp                  Install Google Cloud CLI + Terraform (feature/extension)
  --with-claude               Install Claude Code CLI + extension (persisted)
  --with-gemini               Install Gemini CLI + extension (persisted)
  --with-copilot              Install GitHub Copilot CLI + extensions (persisted)
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

  Credentials are never injected from the host. remoteEnv carries only
  LOCAL_WORKSPACE_FOLDER; authenticate inside the container (gh auth login,
  claude /login, ...). Config dirs of the AI CLIs selected with --with-* are
  persisted in named volumes; gh/cloud logins are not persisted yet, so they
  must be repeated after a rebuild. Project-scoped values such as
  GEMINI_API_KEY belong in the project .env, which
  scripts/load-project-env.sh reads.

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
    --with-copilot)     WITH_SET+=("copilot"); shift ;;
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
    node|go|python|php|rust) ;;
    *) echo "error: unsupported language: $lang (supported: node, go, python, php, rust)" >&2; exit 1 ;;
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
    'scripts/acceptance.sh' \
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
# 認証そのもの（gh / cloud / AI CLI）はコンテナ内で行う。ログイン状態は named volume に
# 残るため、rebuild しても消えない。トークンをこのファイルへ書き写す必要はない。

# Gemini API キー（第二意見レビュー scripts/gemini-review.sh が読む）
GEMINI_API_KEY=

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
    "ghcr.io/devcontainers-extra/features/tmux-apt-get:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "__IF_RUNTIME_PHP__": "ghcr.io/devcontainers/features/php:1",
    "__IF_RUNTIME_RUST__": "ghcr.io/devcontainers/features/rust:1",
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
    'scripts/install-ai-tools.sh')
      # 選択された AI CLI のみを無条件に導入する（--with-* による明示 opt-in）。
      # トークン有無での自動インストールは行わない。__AI_INSTALL_LINES__ は
      # render_content が選択 AI ツール分の install 行に置換する（未選択なら空）。
      # 永続 volume の所有権修復は fix-mount-owner.sh が postCreate の先頭で行う。
      cat <<'TMPL'
#!/usr/bin/env bash
# 選択された AI CLI ツールを導入する（--with-claude / --with-gemini / --with-copilot）。
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
    src="${(%):-%x}"
  else
    src="$0"
  fi
  # スクリプト位置から解決（scripts/ の 1 階層上がルート）。CWD にもパスにも依存しない。
  project_root="$(cd "$(dirname "$src")/.." && pwd)"
  env_file="${PROJECT_ENV_FILE:-$project_root/.env}"
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

if command -v gh >/dev/null 2>&1; then
  # 未認証なら、コンテナ内でのログインを案内する。ホストのトークンは注入されない。
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || \
    echo "[on-attach] WARN: gh は未認証です。コンテナ内で 'gh auth login' を実行してください。" >&2
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
  SNAPSHOT="$(mktemp)"
  TMP_SNAPSHOT="$(mktemp)"
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
  TMP_REPO="$(mktemp -d)"
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
  TMP_REPO="$(mktemp -d)"
  git init -q "$TMP_REPO"
  local effective
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
  # shellcheck disable=SC2206
  ALLOWED_AUTHOR_EMAILS_ARR=($resolved)

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

is_allowed() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [[ "$needle" == "$candidate" ]] && return 0
  done
  return 1
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

    if ! is_allowed "$author_email" "${ALLOWED_AUTHOR_EMAILS_ARR[@]}"; then
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
# 終了コード:
#   0 = VERIFY_PASS（受け入れ条件を満たす）
#   1 = VERIFY_FAIL（未達、または受け入れ条件が未定義）
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
#   既定で scripts/gemini-review.sh があれば実行する。
#   LOOP_GATE_REVIEW_CMD で任意のコマンドへ差し替え可能。空文字でスキップする。
#
# 終了コード:
#   0 = GATE_PASS（全段通過。push 可）
#   1 = GATE_FAIL（いずれかの段が未通過、または実行不能）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# verify・第二意見（git diff 等）はプロジェクトルート基準で実行する。
# scripts/ の 1 階層上がルート。任意の作業ディレクトリから起動しても不変にする。
cd "$(dirname "$HERE")"

echo "[loop-gate] step 1: verify (acceptance)"
if ! bash "$HERE/verify.sh"; then
  echo "[loop-gate] verify not passed" >&2
  echo "GATE_FAIL"
  exit 1
fi

echo "[loop-gate] step 2: second opinion"
if [[ "${LOOP_GATE_REVIEW_CMD-__UNSET__}" == "__UNSET__" ]]; then
  if [[ -f "$HERE/gemini-review.sh" ]]; then
    if ! bash "$HERE/gemini-review.sh"; then
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
    *)       printf '' ;;
  esac
}

# with-set のうち AI ツールだけを選択順に列挙する。
selected_ai_tools() {
  local t
  for t in claude gemini copilot; do
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
persisted_storages() {
  local t dir
  printf '%s %s\n' gh /home/vscode/.config/gh
  with_feature_active aws && printf '%s %s\n' aws /home/vscode/.aws
  with_feature_active gcp && printf '%s %s\n' gcloud /home/vscode/.config/gcloud
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    dir="$(ai_config_dir "$t")"
    [[ -n "$dir" ]] || continue
    printf '%s %s\n' "$t" "$dir"
  done < <(selected_ai_tools)
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
      tmp="$(mktemp)"
      if fetch_gitignore_template "$target" > "$tmp"; then
        cat "$tmp"
      else
        echo "[bootstrap] WARN: gitignore template not found: $target" >&2
      fi
      rm -f "$tmp"
    done
  } | sed '/^$/N;/^\n$/D'
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
    *)      printf '%s' "$1" ;;
  esac
}

# 受け入れ検証の実行に必要なツール名（command -v で存在確認する対象）を返す。
# runtime_check_cmd と同型だが、実行するコマンドに合わせる（node は npm、php は composer）。
acceptance_tool_cmd() {
  case "$1" in
    node)   printf 'npm' ;;
    go)     printf 'go' ;;
    python) printf 'python' ;;
    php)    printf 'composer' ;;
    rust)   printf 'cargo' ;;
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
build_ai_install_block() {
  local tool spec cmd pkg out=""
  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    spec="$(ai_cli_spec "$tool")"
    cmd="${spec%% *}"
    pkg="${spec#* }"
    out+="install_if_missing $cmd \"$pkg\""$'\n'
  done < <(selected_ai_tools)
  printf '%s' "$out"
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
  subst_block __AI_INSTALL_LINES__ "$(build_ai_install_block)"
  subst_block __VOLUME_MOUNTS__ "$(build_volume_mounts_block)"
  subst_block __VOLUME_SECTION__ "$(build_volume_section_block)"
  subst_block __VOLUME_CHECK_LINES__ "$(build_volume_check_block)"
  subst_block __WITH_CHECK_LINES__ "$(build_with_check_block)"

  escaped_base_image="$BASE_IMAGE"
  escaped_base_image="${escaped_base_image//&/\\&}"

  sed_args+=(-e "s|__PROJECT_NAME__|$PROJECT_NAME|g")
  sed_args+=(-e "s|__BASE_IMAGE__|$escaped_base_image|g")
  for lang in node go python php rust; do
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
  local remote_block=""

  remote_block="$(build_remote_gitignore_block)"
  if [[ -n "$remote_block" ]]; then
    printf '%s\n' "$remote_block"
  fi
}

upsert_gitignore() {
  local gitignore_path="$OUTPUT_DIR/.gitignore"
  local tmp block prev_mode=""

  block="$(build_gitignore_block)"
  tmp="$(mktemp)"

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
  nested="$(find "$base" -type d -name '.ai-playbook' | head -n 1 || true)"
  if [[ -n "$nested" ]]; then
    printf '%s' "$nested"
    return
  fi
  dirs="$(find "$base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  files="$(find "$base" -mindepth 1 -maxdepth 1 ! -type d | wc -l | tr -d ' ')"
  if [[ "$dirs" -eq 1 && "$files" -eq 0 ]]; then
    find "$base" -mindepth 1 -maxdepth 1 -type d | head -n 1
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
    PLAYBOOK_TMP_ROOT="$(mktemp -d)"
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
  if ! find "$PLAYBOOK_DIR" -type f -name '*.md' 2>/dev/null | grep -q .; then
    echo "error: no rule files found in playbook source: ${PLAYBOOK_FROM:-<adjacent checkout>}" >&2
    exit 1
  fi
}

# クロスモデル二段ゲートの第二意見レビュアー。規範はルールパッケージ側
# （review-workflow.md）にあり、これはその実行側にあたる。
install_playbook_rules() {
  local common_dir="$PLAYBOOK_DIR" rel dest tmp count=0

  echo "[bootstrap] shared AI rules from: $common_dir"

  # 配布ルート直下の README.md はパッケージ自身の説明であり、利用者が取り込む規範
  # ではない。フラット化で規範と同階層に並ぶため、明示的に除外する。
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    rel="${src#"$common_dir"/}"
    [[ "$rel" == "README.md" ]] && continue
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

  tpl="$(require_playbook_template gemini-review.sh)"
  apply_file_with_policy "$tpl" "$OUTPUT_DIR/scripts/gemini-review.sh"
  if [[ -f "$OUTPUT_DIR/scripts/gemini-review.sh" ]]; then
    chmod +x "$OUTPUT_DIR/scripts/gemini-review.sh"
  fi

  # リモート最終ゲートの雛形は、その機構を明示選択した場合のみ配置する。
  # 規範（review-workflow.md）はベンダー中立で「1 回に限定される機構なら自動でよい」
  # とだけ述べ、具体機構は選択時に雛形として置く分離を守る。
  if has_with copilot; then
    tpl="$(require_playbook_template copilot-review.yml)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.github/workflows/copilot-review.yml"
  fi

  # Claude Code 向け intake 起点スキル。--with-claude を選んだときだけ配置する
  # （選ばなければ .claude/ を作らない）。雛形は規範パッケージが持ち、DCB は置き先
  # だけを決める。Claude Code の機構がスキル定義ファイル名を SKILL.md に固定するため、
  # lower-kebab-case の雛形名から改名して配置する（shared-ai-rules.md 8 章の例外）。
  if has_with claude; then
    tpl="$(require_playbook_template claude-skill-intake.md)"
    apply_file_with_policy "$tpl" "$OUTPUT_DIR/.claude/skills/intake/SKILL.md"
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
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
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

echo "[bootstrap] languages=${LANGUAGES[*]} with=${WITH_SET[*]:-(none)}"
echo "[bootstrap] output=$OUTPUT_DIR"

# ルールソースが指定されたのに使用不能な場合は、何かを書き込む前に失敗させる。
if should_install_playbook; then
  resolve_playbook_source_or_die
fi

# 生成する相対パスを収集してソートする（bash 3 互換）
sorted_rels="$(template_rel_paths | sort)"

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
      [[ "$rel" == "README.md" ]] && continue
      echo "plan: $OUTPUT_DIR/$PLAYBOOK_REL_ROOT/$rel"
    done < <(find "$PLAYBOOK_DIR" -type f -name '*.md' | sort)
    echo "plan: $OUTPUT_DIR/.github/project-ai-rules.md"
    echo "plan: $OUTPUT_DIR/CLAUDE.md"
    echo "plan: $OUTPUT_DIR/.github/copilot-instructions.md"
    echo "plan: $OUTPUT_DIR/scripts/gemini-review.sh"
    if has_with copilot; then
      echo "plan: $OUTPUT_DIR/.github/workflows/copilot-review.yml"
    fi
    has_with claude && echo "plan: $OUTPUT_DIR/.claude/skills/intake/SKILL.md"
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
