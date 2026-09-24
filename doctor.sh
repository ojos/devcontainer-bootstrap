#!/usr/bin/env bash
# doctor.sh — 生成済みワークスペースの自己診断コマンド
set -euo pipefail

# doctor.sh 自身の版。生成物の由来記録（.devcontainer/ORIGIN の
# `version=`）と比較し、「上流が更新されている」かどうかをネットワーク無しで
# 判定するために使う。bootstrap.sh の DCB_VERSION と同じ値を持つこと
# （bootstrap.sh は curl で単体取得されうるため、この 2 ファイルは互いを参照できず、
# 値をそれぞれ持つ。リリース準備のたびに両方を揃えて更新すること。
# tests/test-origin-record.sh が一致を機械照合する）。
#
# この比較には限界がある。doctor.sh は公開リリースごとに取得し直す前提であり、
# 古い doctor.sh をそのまま使い続けると、上流がその後さらに新しくなっていても
# 「上流が更新されています」を報告できない。診断結果にもこの限界を明示する。
DCB_VERSION="v0.12.0"
ORIGIN_REL_PATH=".devcontainer/ORIGIN"

TARGET_DIR="$PWD"
STRICT="false"

# 呼び出しに使われたパスをそのまま示す。開発リポジトリでは
# packages/devcontainer-bootstrap/doctor.sh、公開配布物ではリポジトリ直下の
# ./doctor.sh に置かれるため、固定パスを書くと片方のレイアウトで解決しない。
usage() {
  cat <<EOF
usage: bash $0 [options]

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

# ファイルの sha256 を計算する。bootstrap.sh の dcb_file_sha256 と同じ実装
# （2 ファイルは互いを参照できないため複製している）。sha256sum は GNU coreutils
# 前提で macOS 既定には無い（shasum -a 256 を使う）。両方無い環境向けに openssl も試す。
dcb_file_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print $NF}'
  else
    echo "error: sha256 を計算できるコマンドが見つかりません（sha256sum / shasum / openssl のいずれかが必要です）" >&2
    exit 1
  fi
}

# vX.Y.Z 形式の版を比較する。a が b より古ければ真（終了コード 0）を返す。
#
# 文字列比較にしないのは、"v0.11.0" と "v0.9.1" を文字ごとに比べると '1' < '9' で
# 前者が小さいと判定され、11 が 9 より大きいという事実と逆転するため。
# 数値化できない区分は 0 として扱う（不正な版文字列を誤って「古い」と断定しない）。
dcb_version_lt() {
  local a="${1#v}" b="${2#v}"
  local a_major a_minor a_patch b_major b_minor b_patch
  IFS='.' read -r a_major a_minor a_patch <<< "$a"
  IFS='.' read -r b_major b_minor b_patch <<< "$b"
  [[ "$a_major" =~ ^[0-9]+$ ]] || a_major=0
  [[ "$a_minor" =~ ^[0-9]+$ ]] || a_minor=0
  [[ "$a_patch" =~ ^[0-9]+$ ]] || a_patch=0
  [[ "$b_major" =~ ^[0-9]+$ ]] || b_major=0
  [[ "$b_minor" =~ ^[0-9]+$ ]] || b_minor=0
  [[ "$b_patch" =~ ^[0-9]+$ ]] || b_patch=0
  if [[ "$a_major" -lt "$b_major" ]]; then return 0; fi
  if [[ "$a_major" -gt "$b_major" ]]; then return 1; fi
  if [[ "$a_minor" -lt "$b_minor" ]]; then return 0; fi
  if [[ "$a_minor" -gt "$b_minor" ]]; then return 1; fi
  if [[ "$a_patch" -lt "$b_patch" ]]; then return 0; fi
  return 1
}

# 生成物の由来（.devcontainer/ORIGIN）を診断する。ネットワークは
# 使わない。上流の更新有無は doctor.sh 自身に埋め込んだ DCB_VERSION とだけ比べる
# （このファイル冒頭のコメント参照）。
#
# 記録が無い生成先・記録が壊れている生成先は、診断できないことを明示して報告する。
# 「検査が成立しないことを合格にしない」ため、この場合に ok() は呼ばない。
check_origin_record() {
  local origin_file="$TARGET_DIR/$ORIGIN_REL_PATH"

  if [[ ! -f "$origin_file" ]]; then
    warn "origin record missing ($ORIGIN_REL_PATH): 生成物の由来が記録されていないため乖離を診断できません（この生成先が本機能より前に作られたか、記録が削除された可能性があります。記録の無い生成先への遡及はできません）"
    return 0
  fi

  if [[ ! -r "$origin_file" ]]; then
    ng "origin record unreadable ($ORIGIN_REL_PATH): 読み取れないため乖離を診断できません"
    return 0
  fi

  # `sed ... | head -1` にしない。version= が複数行あるとき sed が全行を出し切る前に
  # head が読み取りを打ち切り、pipefail 下で SIGPIPE により判定が反転しうる
  # （scripts/check-shell-portability.sh が検出する）。awk 単体で最初の一致だけを取る。
  local origin_version
  origin_version="$(awk '/^version=/ { sub(/^version=/, ""); print; exit }' "$origin_file")"
  if [[ -z "$origin_version" ]]; then
    ng "origin record malformed ($ORIGIN_REL_PATH): version= 行を読み取れません。乖離を診断できません"
    return 0
  fi
  # 値が vX.Y.Z 形式であることを比較の前に検証する。dcb_version_lt は数値化できない
  # 区分を 0 として扱うため、検証せずに渡すと "v0.11.0garbage" のような壊れた値でも
  # 版番号の一部（0.11.0）だけを読んで比較が成立してしまい、壊れた記録を合格にする
  # （実測）。
  if ! [[ "$origin_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ng "origin record malformed ($ORIGIN_REL_PATH): version の値が vX.Y.Z 形式ではありません（recorded=$origin_version）。乖離を診断できません"
    return 0
  fi

  if dcb_version_lt "$origin_version" "$DCB_VERSION"; then
    warn "origin version is older than doctor.sh: recorded=$origin_version self=$DCB_VERSION（上流が更新されています。この判定は doctor.sh 自身の版が基準なので、取得し直した最新の doctor.sh でなければ検知できません）"
  else
    ok "origin version matches or is newer than doctor.sh: recorded=$origin_version self=$DCB_VERSION"
  fi

  local hash_count=0 unchanged_count=0 changed="" missing="" line rel recorded_hash actual_hash
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rel="${line#hash:}"
    rel="${rel%%=*}"
    recorded_hash="${line#*=}"
    [[ -n "$rel" && -n "$recorded_hash" ]] || continue
    hash_count=$((hash_count + 1))
    if [[ ! -f "$TARGET_DIR/$rel" ]]; then
      missing="$missing $rel"
      continue
    fi
    actual_hash="$(dcb_file_sha256 "$TARGET_DIR/$rel")"
    if [[ "$actual_hash" == "$recorded_hash" ]]; then
      unchanged_count=$((unchanged_count + 1))
    else
      changed="$changed $rel"
    fi
  done < <(grep '^hash:' "$origin_file" || true)

  if [[ "$hash_count" -eq 0 ]]; then
    warn "origin record has no per-file hash ($ORIGIN_REL_PATH): 生成物ごとの記録が無いため変化を診断できません"
    return 0
  fi

  if [[ -n "$changed" ]]; then
    ng "changed since generation:$changed"
  fi
  if [[ -n "$missing" ]]; then
    ng "recorded in origin but missing:$missing"
  fi
  if [[ -z "$changed" && -z "$missing" ]]; then
    ok "unchanged since generation ($unchanged_count file(s))"
  fi
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
# verify.sh は不在なら VERIFY_FAIL で止まる（検査が成立していないことを合格に
# しないため）。実在を静的構造として見ておかないと、原因が「機密混入検査の欠落」
# だと分かるのが verify を回した後になる。
require_file "scripts/check-no-secrets.sh"

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
# acceptance-remote.sh（外部層）は --with-aws / --with-gcp を選んだ構成にだけ存在する
# ため、実在検査（require_file）は張らず、あるときだけ構文と実行ビットを見る。
# 生成後にプロジェクトが検査を書き足すファイルなので、構文の検査対象へ入れる価値がある。
# 他の 4 本は無条件に配られるので上で require_file 済みで、ここでは中身を見る。
for loop_script in verify.sh acceptance.sh loop-gate.sh check-no-secrets.sh acceptance-remote.sh; do
  if [[ -f "$TARGET_DIR/scripts/$loop_script" ]]; then
    if bash -n "$TARGET_DIR/scripts/$loop_script"; then
      ok "$loop_script syntax OK"
    else
      ng "$loop_script syntax NG"
    fi
    require_exec "scripts/$loop_script"
  fi
done

section "Generation origin"
check_origin_record

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

  # features から言語ランタイム（node, go, python, php, rust, ruby）を抽出する。
  # feature キー名とランタイムコマンド名は原則一致するが、rust だけは feature が
  # rust なのに実行ファイルが cargo/rustc に分かれ「rust」コマンドは存在しない。
  # bootstrap.sh の runtime_check_cmd と同じ写像で検査コマンドを解決する。
  for lang in node go python php rust ruby; do
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
