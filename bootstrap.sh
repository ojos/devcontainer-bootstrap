#!/usr/bin/env bash
# bootstrap.sh — devcontainer bootstrap one-shot generator (standalone)
# 目的: 新規作業ディレクトリに1コマンドで devcontainer 雛形を生成する
# 使用方法:
#   curl -sSL https://github.com/YOUR_ORG/devcontainer-bootstrap/releases/latest/download/bootstrap.sh \
#     -o bootstrap.sh && bash bootstrap.sh --project-name myapp --languages node,go --mode standard
set -euo pipefail

PROJECT_NAME=""
MODE="standard"
OUTPUT_DIR=""
LANGUAGES=()
FORCE="false"
DRY_RUN="false"
MANAGE_GITIGNORE="true"
GITIGNORE_TARGETS=""

GITHUB_TOKEN_ENV="GITHUB_TOKEN"
GITHUB_PROFILES="primary,secondary"
CLAUDE_TOKEN_ENV="CLAUDE_CODE_OAUTH_TOKEN"
GEMINI_KEY_ENV="GEMINI_API_KEY"
BASE_IMAGE_OVERRIDE=""
BASE_IMAGE=""
GITIGNORE_BEGIN="# >>> devcontainer-bootstrap managed section >>>"
GITIGNORE_END="# <<< devcontainer-bootstrap managed section <<<"
GITIGNORE_REPO_RAW_BASE="https://raw.githubusercontent.com/github/gitignore/main"

usage() {
  cat <<'EOF'
usage: bash bootstrap.sh [options]

options:
  --project-name <name>       Project name for devcontainer display name (required)
  --mode <minimal|standard|full>
                              Template variant (default: standard)
  --languages <csv>           Language runtimes (CSV: node,go,python) (required)
  --output-dir <path>         Output directory (default: $PWD/<project-name>)
  --github-token-env <name>   [legacy] Local env var name for GH token (default: GITHUB_TOKEN)
  --github-profiles <csv>     GitHub profiles for multi-account env injection
                              (default: primary,secondary)
  --claude-token-env <name>   Local env var name for Claude token (default: CLAUDE_CODE_OAUTH_TOKEN)
  --gemini-key-env <name>     Local env var name for Gemini key (default: GEMINI_API_KEY)
  --base-image <image>        Override auto-selected devcontainer base image
  --dry-run                   Show planned outputs without writing files
  --force                     Overwrite existing files
  --no-gitignore              Do not write/update managed .gitignore section
  --gitignore-targets <csv>   Additional template names to use (e.g. VisualStudioCode,JetBrains)
  -h, --help                  Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)     PROJECT_NAME="$2"; shift 2 ;;
    --mode)             MODE="$2"; shift 2 ;;
    --languages)        IFS=',' read -ra LANGUAGES <<< "$2"; shift 2 ;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
    --github-token-env) GITHUB_TOKEN_ENV="$2"; shift 2 ;;
    --github-profiles)  GITHUB_PROFILES="$2"; shift 2 ;;
    --claude-token-env) CLAUDE_TOKEN_ENV="$2"; shift 2 ;;
    --gemini-key-env)   GEMINI_KEY_ENV="$2"; shift 2 ;;
    --base-image)       BASE_IMAGE_OVERRIDE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --force)            FORCE="true"; shift ;;
    --no-gitignore)     MANAGE_GITIGNORE="false"; shift ;;
    --gitignore-targets)   GITIGNORE_TARGETS="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ── Validation ───────────────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}
require_cmd jq
require_cmd perl
require_cmd awk
require_cmd sed
require_cmd curl

[[ -n "$PROJECT_NAME" ]] || { echo "error: --project-name is required" >&2; usage; exit 1; }
[[ ${#LANGUAGES[@]} -gt 0 ]] || { echo "error: --languages is required" >&2; usage; exit 1; }

for i in "${!LANGUAGES[@]}"; do
  LANGUAGES[i]=$(echo "${LANGUAGES[i]}" | xargs)
done
for lang in "${LANGUAGES[@]}"; do
  case "$lang" in
    node|go|python) ;;
    *) echo "error: unsupported language: $lang (supported: node, go, python)" >&2; exit 1 ;;
  esac
done
case "$MODE" in
  minimal|standard|full) ;;
  *) echo "error: invalid --mode: $MODE" >&2; exit 1 ;;
esac
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$PWD/$PROJECT_NAME"

# Select base image based on Docker server platform (with safe fallback)
detect_server_platform() {
  local platform
  if command -v docker >/dev/null 2>&1; then
    platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)"
    if [[ -n "$platform" && "$platform" == */* ]]; then
      printf '%s\n' "$platform"
      return 0
    fi
  fi
  # Fallback for environments without docker access during bootstrap.
      local resolved_targets
      local target
      local tmp
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

# ── Embedded templates (bash 3 compatible) ─────────────────────────────────

mode_rel_paths() {
  case "$1" in
    minimal|standard|full)
      printf '%s\n' \
        '.devcontainer/devcontainer.json' \
        'scripts/github-account-switch.sh' \
        'scripts/on-attach.sh' \
        'scripts/post-rebuild-check.sh'
      ;;
    *)
      echo "error: unsupported mode in mode_rel_paths: $1" >&2
      exit 1
      ;;
  esac
}

get_template_content() {
  local mode="$1"
  local rel="$2"
  case "$mode:$rel" in
    'minimal:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (minimal)",
  "image": "__BASE_IMAGE__",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:1": {
      "configureZsh": true
    },
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": false
    },
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1"
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": ["ms-azuretools.vscode-containers"]
    }
  }
}
TMPL
      ;;
    'minimal:scripts/github-account-switch.sh'|'standard:scripts/github-account-switch.sh'|'full:scripts/github-account-switch.sh')
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

  [[ -n "$git_name" ]] && git config --"$git_scope" user.name "$git_name"
  [[ -n "$git_email" ]] && git config --"$git_scope" user.email "$git_email"
  git config --"$git_scope" github.owner "$owner"
  git config --"$git_scope" github.account "$login"

  echo "[github-account] active profile: $profile"
  echo "[github-account] active login:   $login"
  echo "[github-account] owner:          $owner"
  echo "[github-account] git scope:      $git_scope"
  echo "[github-account] git user.name:  $(git config --"$git_scope" user.name 2>/dev/null || echo '<unchanged>')"
  echo "[github-account] git user.email: $(git config --"$git_scope" user.email 2>/dev/null || echo '<unchanged>')"
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
    'minimal:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] minimal bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || echo "[on-attach] WARN: gh auth missing"
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
TMPL
      ;;
    'minimal:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] minimal bootstrap checks"
command -v bash >/dev/null 2>&1 && echo "[check] bash OK"
command -v gh   >/dev/null 2>&1 && echo "[check] gh OK" || echo "[check] gh missing"
TMPL
      ;;
    'standard:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (standard)",
  "image": "__BASE_IMAGE__",
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
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1"
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "ms-azuretools.vscode-containers",
        "amazonwebservices.aws-toolkit-vscode"
      ]
    }
  }
}
TMPL
      ;;
    'standard:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] standard bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || echo "[on-attach] WARN: gh auth missing"
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
command -v go   >/dev/null 2>&1 && echo "[on-attach] go OK"   || true
command -v node >/dev/null 2>&1 && echo "[on-attach] node OK" || true
TMPL
      ;;
    'standard:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] standard bootstrap checks"
for cmd in bash jq gh node go docker; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done
TMPL
      ;;
    'full:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (full)",
  "image": "__BASE_IMAGE__",
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
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "ghcr.io/devcontainers/features/aws-cli:1": {}
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "mounts": [
    "source=claude-storage,target=/home/node/.claude,type=volume",
    "source=gemini-storage,target=/home/node/.gemini,type=volume"
  ],
  "postCreateCommand": "bash scripts/post-rebuild-check.sh",
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "ms-azuretools.vscode-containers",
        "amazonwebservices.aws-toolkit-vscode"
      ]
    }
  }
}
TMPL
      ;;
    'full:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] full bootstrap active"
for cmd in gh claude gemini go node docker; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[on-attach] $cmd OK" || echo "[on-attach] WARN: $cmd missing"
done
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
TMPL
      ;;
    'full:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] full bootstrap checks"
for cmd in bash jq gh node go docker claude gemini; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done
TMPL
      ;;
    *)
      echo "error: unknown template key: $mode:$rel" >&2
      exit 1
      ;;
  esac
}

# ── Rendering ─────────────────────────────────────────────────────────────────

has_language() {
  local target="$1" l
  for l in "${LANGUAGES[@]}"; do [[ "$l" == "$target" ]] && return 0; done
  return 1
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
    printf -v line '    "GITHUB_TOKEN_%s": "${localEnv:GITHUB_TOKEN_%s}",\n' "$upper" "$upper"
    out+="$line"
    printf -v line '    "GITHUB_OWNER_%s": "${localEnv:GITHUB_OWNER_%s}",\n' "$upper" "$upper"
    out+="$line"
    printf -v line '    "GIT_AUTHOR_NAME_%s": "${localEnv:GIT_AUTHOR_NAME_%s}",\n' "$upper" "$upper"
    out+="$line"
    printf -v line '    "GIT_AUTHOR_EMAIL_%s": "${localEnv:GIT_AUTHOR_EMAIL_%s}",\n' "$upper" "$upper"
    out+="$line"
  done

  printf '%b' "$out"
}

render_content() {
  local content="$1"
  local sed_args=()
  local escaped_base_image
  local github_env_block

  github_env_block="$(build_github_profile_env_block)"
  content="${content//__GITHUB_PROFILE_ENV_BLOCK__/$github_env_block}"

  escaped_base_image="$BASE_IMAGE"
  escaped_base_image="${escaped_base_image//&/\\&}"

  sed_args+=(-e "s|__PROJECT_NAME__|$PROJECT_NAME|g")
  sed_args+=(-e "s|__GITHUB_TOKEN_ENV__|$GITHUB_TOKEN_ENV|g")
  sed_args+=(-e "s|__CLAUDE_TOKEN_ENV__|$CLAUDE_TOKEN_ENV|g")
  sed_args+=(-e "s|__GEMINI_KEY_ENV__|$GEMINI_KEY_ENV|g")
  sed_args+=(-e "s|__BASE_IMAGE__|$escaped_base_image|g")
  for lang in node go python; do
    local lang_upper
    lang_upper=$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')
    if has_language "$lang"; then
      sed_args+=(-e "s|\"__IF_RUNTIME_${lang_upper}__\": \"ghcr.io/devcontainers/features/$lang:1\"|\"ghcr.io/devcontainers/features/$lang:1\": {}|g")
    else
      sed_args+=(-e "/\"__IF_RUNTIME_${lang_upper}__\"/d")
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
  local tmp block

  block="$(build_gitignore_block)"
  tmp="$(mktemp)"

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

  mv "$tmp" "$gitignore_path"
  echo "write: $gitignore_path (managed section)"
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
  [[ "$out" == *.sh ]] && chmod +x "$out"
  echo "write: $out"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "[bootstrap] mode=$MODE languages=${LANGUAGES[*]}"
echo "[bootstrap] output=$OUTPUT_DIR"

# Collect and sort relative paths for the selected mode (bash 3 compatible)
sorted_rels="$(mode_rel_paths "$MODE" | sort)"

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
  exit 0
fi

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  write_file "$rel" "$(get_template_content "$MODE" "$rel")"
done <<EOF
$sorted_rels
EOF

if [[ "$MANAGE_GITIGNORE" == "true" ]]; then
  upsert_gitignore
fi

echo "[bootstrap] completed"
