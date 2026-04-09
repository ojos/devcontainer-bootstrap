#!/usr/bin/env bash
# doctor.sh — generated workspace self-diagnosis command
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
require_file "scripts/on-attach.sh"
require_file "scripts/post-rebuild-check.sh"

if [[ -f "$TARGET_DIR/.devcontainer/devcontainer.json" ]]; then
  if jq . "$TARGET_DIR/.devcontainer/devcontainer.json" >/dev/null 2>&1; then
    ok "devcontainer.json valid JSON"
  else
    ng "devcontainer.json invalid JSON"
  fi

  # shellcheck disable=SC2016
  if grep -q '\${localEnv:' "$TARGET_DIR/.devcontainer/devcontainer.json"; then
    ok "secrets policy: localEnv reference found"
  else
    warn "secrets policy: localEnv reference not found"
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

if [[ -f "$TARGET_DIR/scripts/post-rebuild-check.sh" ]]; then
  if bash -n "$TARGET_DIR/scripts/post-rebuild-check.sh"; then
    ok "post-rebuild-check.sh syntax OK"
  else
    ng "post-rebuild-check.sh syntax NG"
  fi
  require_exec "scripts/post-rebuild-check.sh"
fi

section "Runtime command availability"
for cmd in bash jq perl gh; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd command available"
  else
    warn "$cmd command missing"
  fi
done

# Dynamically detect configured languages from devcontainer.json features
check_runtime_languages() {
  local devcontainer_json="$TARGET_DIR/.devcontainer/devcontainer.json"
  if [[ ! -f "$devcontainer_json" ]]; then
    warn "devcontainer.json not found for language detection"
    return
  fi

  # Extract language runtimes from features (node, go, python)
  for lang in node go python; do
    if grep -q "\"ghcr.io/devcontainers/features/$lang:1\"" "$devcontainer_json" 2>/dev/null; then
      if command -v "$lang" >/dev/null 2>&1; then
        ok "$lang command available"
      else
        warn "$lang command missing"
      fi
    fi
  done
}

check_runtime_languages

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
