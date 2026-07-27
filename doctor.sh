#!/usr/bin/env bash
# doctor.sh — 生成済みワークスペースの自己診断コマンド
set -euo pipefail

TARGET_DIR="$PWD"
STRICT="false"

usage() {
  cat <<'EOF'
usage: bash packages/devcontainer-bootstrap/doctor.sh [options]

options:
  --target-dir <path>   Target workspace path (default: current directory)
  --strict              Exit non-zero on warnings
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir) TARGET_DIR="$2"; shift 2 ;;
    --strict) STRICT="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

PASS=0
WARN=0
FAIL=0

ok() { echo "[OK] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }
ng() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

section() {
  echo
  echo "=== $1 ==="
}

require_file() {
  local f="$1"
  if [[ -f "$TARGET_DIR/$f" ]]; then
    ok "$f exists"
  else
    ng "$f missing"
  fi
}

require_exec() {
  local f="$1"
  if [[ -x "$TARGET_DIR/$f" ]]; then
    ok "$f executable"
  else
    warn "$f not executable"
  fi
}

section "Static structure"
require_file ".devcontainer/devcontainer.json"
require_file ".env.example"
require_file "scripts/on-attach.sh"
require_file "scripts/fix-mount-owner.sh"
require_file "scripts/post-rebuild-check.sh"
require_file "scripts/verify.sh"
require_file "scripts/acceptance.sh"
require_file "scripts/loop-gate.sh"

if [[ -f "$TARGET_DIR/.devcontainer/devcontainer.json" ]]; then
  if jq . "$TARGET_DIR/.devcontainer/devcontainer.json" >/dev/null 2>&1; then
    ok "devcontainer.json valid JSON"
  else
    ng "devcontainer.json invalid JSON"
  fi

  # 資格情報のホスト注入は廃止した。remoteEnv に ${localEnv:...} が現れることは、
  # ホスト OS の環境変数をコンテナへ流し込む経路が復活したことを意味する。
  # 作業ディレクトリの受け渡し（localWorkspaceFolder）は localEnv ではないため対象外。
  # shellcheck disable=SC2016
  if grep -q '\${localEnv:' "$TARGET_DIR/.devcontainer/devcontainer.json"; then
    ng "secrets policy: localEnv reference found (ホスト資格情報の注入経路)"
  else
    ok "secrets policy: no localEnv reference"
  fi

  # compose 配線の検査。dockerComposeFile が無い旧 image ベース構成は検査しない（後方互換）。
  compose_files="$(jq -r '.dockerComposeFile // empty | if type == "array" then .[] else . end' \
    "$TARGET_DIR/.devcontainer/devcontainer.json" 2>/dev/null || true)"
  if [[ -n "$compose_files" ]]; then
    while IFS= read -r compose_file; do
      [[ -n "$compose_file" ]] || continue
      case "$compose_file" in
        # 絶対パスは devcontainer.json からの相対解決を行わずそのまま検査する
        /*)
          if [[ -f "$compose_file" ]]; then
            ok "dockerComposeFile exists: $compose_file"
          else
            ng "dockerComposeFile missing: $compose_file"
          fi
          ;;
        *) require_file ".devcontainer/$compose_file" ;;
      esac
    done <<< "$compose_files"
  fi
fi

section "Script checks"
if [[ -f "$TARGET_DIR/scripts/on-attach.sh" ]]; then
  if bash -n "$TARGET_DIR/scripts/on-attach.sh"; then
    ok "on-attach.sh syntax OK"
  else
    ng "on-attach.sh syntax NG"
  fi
  require_exec "scripts/on-attach.sh"
fi

if [[ -f "$TARGET_DIR/scripts/fix-mount-owner.sh" ]]; then
  if bash -n "$TARGET_DIR/scripts/fix-mount-owner.sh"; then
    ok "fix-mount-owner.sh syntax OK"
  else
    ng "fix-mount-owner.sh syntax NG"
  fi
  require_exec "scripts/fix-mount-owner.sh"
fi

if [[ -f "$TARGET_DIR/scripts/post-rebuild-check.sh" ]]; then
  if bash -n "$TARGET_DIR/scripts/post-rebuild-check.sh"; then
    ok "post-rebuild-check.sh syntax OK"
  else
    ng "post-rebuild-check.sh syntax NG"
  fi
  require_exec "scripts/post-rebuild-check.sh"
fi

# ループコーディングの機構（受け入れゲート）。単体で動作する前提で検査する。
for loop_script in verify.sh acceptance.sh loop-gate.sh; do
  if [[ -f "$TARGET_DIR/scripts/$loop_script" ]]; then
    if bash -n "$TARGET_DIR/scripts/$loop_script"; then
      ok "$loop_script syntax OK"
    else
      ng "$loop_script syntax NG"
    fi
    require_exec "scripts/$loop_script"
  fi
done

section "Runtime command availability"
for cmd in bash jq perl gh; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd command available"
  else
    warn "$cmd command missing"
  fi
done

# devcontainer.json の features から設定済み言語を動的に検出する
check_runtime_languages() {
  local devcontainer_json="$TARGET_DIR/.devcontainer/devcontainer.json"
  if [[ ! -f "$devcontainer_json" ]]; then
    warn "devcontainer.json not found for language detection"
    return
  fi

  # features から言語ランタイム（node, go, python, php, rust）を抽出する。
  # feature キー名とランタイムコマンド名は原則一致するが、rust だけは feature が
  # rust なのに実行ファイルが cargo/rustc に分かれ「rust」コマンドは存在しない。
  # bootstrap.sh の runtime_check_cmd と同じ写像で検査コマンドを解決する。
  for lang in node go python php rust; do
    if grep -q "\"ghcr.io/devcontainers/features/$lang:1\"" "$devcontainer_json" 2>/dev/null; then
      local cmd
      case "$lang" in
        rust) cmd="cargo" ;;
        *)    cmd="$lang" ;;
      esac
      if command -v "$cmd" >/dev/null 2>&1; then
        ok "$lang command available ($cmd)"
      else
        warn "$lang command missing ($cmd)"
      fi
    fi
  done
}

check_runtime_languages

# devcontainer.json の features から配線済みの cloud ツールを検出し、対応 CLI を確認する。
# feature キーと CLI 名は 1 対 1 でない（gcp は google-cloud-cli feature → gcloud）。
check_with_features() {
  local devcontainer_json="$TARGET_DIR/.devcontainer/devcontainer.json"
  [[ -f "$devcontainer_json" ]] || return
  # "feature-path:cli-name" の対で検査する。feature path は bootstrap.sh の
  # with_feature_path と一致させる（aws/terraform は devcontainers 名前空間、gcp は
  # 外部 dhoeric）。bash 3.2 互換のため連想配列は使わない。
  local pair feat cli
  for pair in \
    "devcontainers/features/aws-cli:aws" \
    "dhoeric/features/google-cloud-cli:gcloud" \
    "devcontainers/features/terraform:terraform"; do
    feat="${pair%:*}"
    cli="${pair##*:}"
    if grep -q "\"ghcr.io/$feat:1\"" "$devcontainer_json" 2>/dev/null; then
      if command -v "$cli" >/dev/null 2>&1; then
        ok "$cli command available"
      else
        warn "$cli command missing"
      fi
    fi
  done
}

check_with_features

if grep -q 'docker-outside-of-docker' "$TARGET_DIR/.devcontainer/devcontainer.json" 2>/dev/null; then
  if command -v docker >/dev/null 2>&1; then
    ok "docker command available"
  else
    warn "docker command missing"
  fi
fi

echo
echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

if [[ "$STRICT" == "true" && "$WARN" -gt 0 ]]; then
  exit 2
fi

exit 0
