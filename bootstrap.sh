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

GITHUB_PROFILES="primary,secondary"
CLAUDE_TOKEN_ENV="CLAUDE_CODE_OAUTH_TOKEN"
GEMINI_KEY_ENV="GEMINI_API_KEY"
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
  --github-profiles <csv>     GitHub profiles for multi-account env injection
                              (default: primary,secondary)
  --claude-token-env <name>   Local env var name for Claude token (default: CLAUDE_CODE_OAUTH_TOKEN)
  --gemini-key-env <name>     Local env var name for Gemini key (default: GEMINI_API_KEY)
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
    --github-profiles)  GITHUB_PROFILES="$2"; shift 2 ;;
    --claude-token-env) CLAUDE_TOKEN_ENV="$2"; shift 2 ;;
    --gemini-key-env)   GEMINI_KEY_ENV="$2"; shift 2 ;;
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
    '.devcontainer/compose.yaml' \
    '.devcontainer/devcontainer.json' \
    'scripts/acceptance.sh' \
    'scripts/github-account-switch.sh' \
    'scripts/install-ai-tools.sh' \
    'scripts/loop-gate.sh' \
    'scripts/on-attach.sh' \
    'scripts/post-rebuild-check.sh' \
    'scripts/verify.sh'
}

get_template_content() {
  local rel="$1"
  case "$rel" in
    '.devcontainer/compose.yaml')
      # AI ツールの永続 volume は選択に応じて条件配線する（__AI_VOLUME_MOUNTS__ /
      # __AI_VOLUME_SECTION__ を render_content が置換）。docker socket は常に明示。
      cat <<'TMPL'
services:
  app:
    image: __BASE_IMAGE__
    volumes:
      - ..:/workspaces/__PROJECT_NAME__:cached
      # docker-outside-of-docker feature 用（compose 利用時は feature 側の mounts が適用されないため明示）
      - /var/run/docker.sock:/var/run/docker-host.sock
__AI_VOLUME_MOUNTS__
    command: sleep infinity
__AI_VOLUME_SECTION__
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
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postCreateCommand": "bash scripts/install-ai-tools.sh",
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
    'scripts/github-account-switch.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/github-account-switch.sh list
  bash scripts/github-account-switch.sh status
  bash scripts/github-account-switch.sh use <profile> [--git-scope local|global]

profiles:
  GITHUB_TOKEN_<PROFILE_UPPER> を設定した profile を自動検出
  任意で以下も profile ごとに設定可:
    GITHUB_OWNER_<PROFILE_UPPER>
    GIT_AUTHOR_NAME_<PROFILE_UPPER>
    GIT_AUTHOR_EMAIL_<PROFILE_UPPER>
EOF
}

profile_to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

cmd_list() {
  local found=0
  while IFS='=' read -r key _; do
    if [[ "$key" =~ ^GITHUB_TOKEN_(.+)$ ]]; then
      local suffix="${BASH_REMATCH[1]}"
      local profile
      profile="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
      echo "  $profile  (env: GITHUB_TOKEN_${suffix})"
      found=1
    fi
  done < <(env | sort)
  if [[ "$found" -eq 0 ]]; then
    echo "  (none — set GITHUB_TOKEN_<PROFILE> to register a profile)"
  fi
}

cmd_status() {
  echo "[github-account] gh auth status"
  gh auth status -h github.com || true
  echo
  echo "[github-account] git identity"
  echo "  scope=local  name=$(git config --local user.name 2>/dev/null || echo '<unset>')"
  echo "  scope=local  email=$(git config --local user.email 2>/dev/null || echo '<unset>')"
  echo "  scope=global name=$(git config --global user.name 2>/dev/null || echo '<unset>')"
  echo "  scope=global email=$(git config --global user.email 2>/dev/null || echo '<unset>')"
  echo "  github.owner(local)=$(git config --local github.owner 2>/dev/null || echo '<unset>')"
  echo "  github.owner(global)=$(git config --global github.owner 2>/dev/null || echo '<unset>')"
  echo
  echo "[github-account] registered profiles"
  cmd_list
}

# git push の認証を、いま選択した gh のアカウントへ向ける。
#
# gh auth login --with-token は非対話のため git を設定しない。これを補わないと、
# gh と git identity だけが切り替わり、push の認証は既存の credential.helper
# （エディタが仕込むものなど）が返す別アカウントのまま残る。切替えたつもりで
# 別人として push しようとして 403 になる。
#
# git はヘルパーを定義順に試し、最初に応答したものを採用する。上位スコープに
# ヘルパーがあると必ずそちらが勝つため、空文字を先に入れて一覧をリセットする。
setup_git_credentials() {
  local git_scope="$1"
  command -v gh >/dev/null 2>&1 || return 0
  git config --"$git_scope" --unset-all credential.helper 2>/dev/null || true
  git config --"$git_scope" --add credential.helper ''
  git config --"$git_scope" --add credential.helper '!gh auth git-credential'
}

cmd_use() {
  local profile="$1"
  shift

  [[ "$profile" =~ ^[a-zA-Z0-9_]+$ ]] || {
    echo "error: invalid profile" >&2
    exit 1
  }

  local git_scope="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --git-scope)
        git_scope="$2"
        shift 2
        ;;
      *)
        echo "error: unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  local upper token_env name_env email_env owner_env
  upper="$(profile_to_upper "$profile")"
  token_env="GITHUB_TOKEN_${upper}"
  name_env="GIT_AUTHOR_NAME_${upper}"
  email_env="GIT_AUTHOR_EMAIL_${upper}"
  owner_env="GITHUB_OWNER_${upper}"

  local token="${!token_env:-}"
  [[ -n "$token" ]] || {
    echo "error: $token_env is not set" >&2
    exit 1
  }

  local login
  login="$(GH_TOKEN="$token" gh api user --jq .login)"
  printf '%s' "$token" | gh auth login --hostname github.com --with-token >/dev/null
  if gh auth switch --help >/dev/null 2>&1; then
    gh auth switch --hostname github.com --user "$login" >/dev/null
  fi

  local owner="${!owner_env:-$login}"
  local git_name="${!name_env:-}"
  local git_email="${!email_env:-}"

  if [[ -n "$git_name" ]]; then git config --"$git_scope" user.name "$git_name"; fi
  if [[ -n "$git_email" ]]; then git config --"$git_scope" user.email "$git_email"; fi
  git config --"$git_scope" github.owner "$owner"
  git config --"$git_scope" github.account "$login"

  setup_git_credentials "$git_scope"

  echo "[github-account] active profile: $profile"
  echo "[github-account] active login:   $login"
  echo "[github-account] owner:          $owner"
  echo "[github-account] git scope:      $git_scope"
  echo "[github-account] git user.name:  $(git config --"$git_scope" user.name 2>/dev/null || echo '<unchanged>')"
  echo "[github-account] git user.email: $(git config --"$git_scope" user.email 2>/dev/null || echo '<unchanged>')"
  echo "[github-account] git push auth:  gh ($login)"
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  case "$1" in
    list) cmd_list ;;
    status) cmd_status ;;
    use)
      shift
      [[ $# -ge 1 ]] || {
        echo "error: missing profile" >&2
        exit 1
      }
      cmd_use "$@"
      ;;
    -h|--help|help) usage ;;
    *)
      echo "error: unknown subcommand: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
TMPL
      ;;
    'scripts/install-ai-tools.sh')
      # 選択された AI CLI のみを無条件に導入する（--with-* による明示 opt-in）。
      # トークン有無での自動インストールは行わない。__AI_INSTALL_LINES__ は
      # render_content が選択 AI ツール分の install 行に置換する（未選択なら空）。
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
    'scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || echo "[on-attach] WARN: gh auth missing"
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
TMPL
      ;;
    'scripts/post-rebuild-check.sh')
      # 基本コマンド + 選択言語（__RUNTIME_CHECK_LINES__）+ 選択装備
      # （__WITH_CHECK_LINES__: 選択した cloud/AI ツールの CLI）の存在を検査する。
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] bootstrap checks"
for cmd in bash jq gh docker rg; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done
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
# 生成時に、選択言語の慣習的なテストコマンドを既定として配置している。
# プロジェクトの実態（テスト・ビルド・lint・E2E など）に合わせて自由に編集すること。
# 受け入れ条件が検証可能であるほど、ループコーディングの反復が収束しやすくなる。
#
# 終了コード: 0 = 合格 / 非0 = 不合格
set -euo pipefail

echo "[acceptance] project acceptance checks"
__ACCEPTANCE_CHECK_LINES__
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

build_github_profile_env_block() {
  local csv="$GITHUB_PROFILES"
  local item profile upper out=""
  local line

  IFS=',' read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    profile="$(echo "$item" | xargs)"
    [[ -n "$profile" ]] || continue
    if [[ ! "$profile" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo "error: invalid github profile name: $profile" >&2
      exit 1
    fi
    upper="$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')"
    # shellcheck disable=SC2016
    printf -v line '    "GITHUB_TOKEN_%s": "${localEnv:GITHUB_TOKEN_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GITHUB_OWNER_%s": "${localEnv:GITHUB_OWNER_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GIT_AUTHOR_NAME_%s": "${localEnv:GIT_AUTHOR_NAME_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GIT_AUTHOR_EMAIL_%s": "${localEnv:GIT_AUTHOR_EMAIL_%s}",\n' "$upper" "$upper"
    out+="$line"
  done

  printf '%b' "$out"
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
# 検査コマンドは acceptance_check_cmd に一元化する。プロジェクトが編集する起点であり、
# 生成時点で緑になることは保証しない（受け入れ条件はプロジェクト固有のため）。
build_acceptance_check_block() {
  local lang cmd out=""
  for lang in "${LANGUAGES[@]}"; do
    cmd="$(acceptance_check_cmd "$lang")"
    out+="echo \"[acceptance] ($lang) $cmd\""$'\n'
    out+="$cmd"$'\n'
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

# compose の app.volumes に足す AI 永続 volume のマウント行（__AI_VOLUME_MOUNTS__）。
# 未選択なら空（行ごと消える）。
build_ai_volume_mounts_block() {
  local tool dir out=""
  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    dir="$(ai_config_dir "$tool")"
    out+="      - ${tool}-storage:${dir}"$'\n'
  done < <(selected_ai_tools)
  printf '%s' "$out"
}

# compose のトップレベル volumes: セクション（__AI_VOLUME_SECTION__）。
# AI ツールを 1 つでも選べば named volume を定義、なければ空（セクションごと消える）。
build_ai_volume_section_block() {
  local tool defs=""
  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    defs+="  ${tool}-storage:"$'\n'
  done < <(selected_ai_tools)
  [[ -n "$defs" ]] || { printf ''; return; }
  printf 'volumes:\n%s' "$defs"
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
  local github_env_block

  github_env_block="$(build_github_profile_env_block)"
  content="${content//__GITHUB_PROFILE_ENV_BLOCK__/$github_env_block}"

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
  subst_block __AI_INSTALL_LINES__ "$(build_ai_install_block)"
  subst_block __AI_VOLUME_MOUNTS__ "$(build_ai_volume_mounts_block)"
  subst_block __AI_VOLUME_SECTION__ "$(build_ai_volume_section_block)"
  subst_block __WITH_CHECK_LINES__ "$(build_with_check_block)"

  escaped_base_image="$BASE_IMAGE"
  escaped_base_image="${escaped_base_image//&/\\&}"

  sed_args+=(-e "s|__PROJECT_NAME__|$PROJECT_NAME|g")
  sed_args+=(-e "s|__CLAUDE_TOKEN_ENV__|$CLAUDE_TOKEN_ENV|g")
  sed_args+=(-e "s|__GEMINI_KEY_ENV__|$GEMINI_KEY_ENV|g")
  sed_args+=(-e "s|__BASE_IMAGE__|$escaped_base_image|g")
  for lang in node go python php rust; do
    local lang_upper
    lang_upper=$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')
    if has_language "$lang"; then
      sed_args+=(-e "s|\"__IF_RUNTIME_${lang_upper}__\": \"ghcr.io/devcontainers/features/$lang:1\"|\"ghcr.io/devcontainers/features/$lang:1\": {}|g")
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
