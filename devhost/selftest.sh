#!/usr/bin/env bash
# selftest.sh — dev（dev.sh）の自己試験。非対話で、本物の devcontainer / docker / tmux /
# systemctl を 1 つも呼ばない。
#
# 偽の道具を一時ディレクトリに置き、PATH をその偽物と最小限の道具（sed など）だけにして
# dev.sh を回す。偽物は呼ばれた引数を 1 行ずつ記録し、試験はその記録を突き合わせる。
#
# ## 偽物を本物に合わせたところ（本物がしないことはさせない）
#
# - devcontainer（CLI 0.89.0 の dist を読んで合わせた）
#   - `up`: 結果を JSON 1 行で標準出力へ、経過を標準エラーへ出す。失敗の JSON
#     （outcome=error）でも 1 で抜ける。devcontainer.json が無いワークスペースは
#     `Dev container config (...) not found.` で失敗する
#   - `exec`: **最初のオプションでない語で引数の解析を止め**（halt-at-non-option）、それより
#     後をそのままコマンドに渡す。動いているコンテナが無ければ `Dev container not found.` で 1
#   - `up --remove-existing-container`: 在るコンテナを消して**別の ID で**作り直す（本物は古い
#     コンテナを削除して新しく作るので ID が変わる）
#   - exec が通らないとき（FAKE_EXEC_FAIL=1）: docker exec の失敗（procReady not received）を
#     1 で返す。本物の終了コードは確かめていない（dev は 0 以外を「入れない」とだけ読む）
#   - `exec ... true`: 偽のコンテナには true が無いので、0 で抜ける
#     （本物はコンテナの中の true を実行して 0 で抜ける）
# - docker `inspect --format '{{.State.Pid}}' <id>`: 動いていれば PID、止まっていれば 0（本物は
#   止まったコンテナの State.Pid を 0 で返す）。無い ID は 1。他の形は落とす
# - ps: `-eo pid=,stat=`（`=` で見出しを消した「PID 状態」の列。PID は右寄せ。この環境の
#   procps-ng 4.0.4 の出力に合わせた）。cgroup の所属は ps に出させず、dev が
#   /proc/<PID>/cgroup を読む（ps の cgroup 列はルートの cgroup で `-` と出る環境があり、
#   パスの形が信用できないため）
# - git: `-C <dir> pull --ff-only` だけ。失敗は本物と同じ形の `fatal: ...` を 128 で返す
# - journalctl: `--user -u <unit> -n <N> --no-pager` だけ。履歴が無ければ本物と同じ `-- No entries --`
# - systemctl: `--user is-active|stop|start <unit>`。stop / start は何も出さず 0
# - /proc と cgroup は偽の木（$WORK/proc と $WORK/cg）を DEV_PROC_ROOT / DEV_CGROUP_ROOT で渡す。
#   cgroup v2 の形に合わせる（/proc/<PID>/cgroup は `0::/パス` の 1 行、pids.current / pids.max は
#   数か `max`、pids.events は `max N`、memory.events は 1 行 1 キー）
# - docker: `ps -a` / `--filter label=k=v`（値の完全一致）/ `--format '{{.ID}} {{.State}}'`、
#   `wait <id>`（止まるまで待ち、終了コードを 1 行出して 0 で抜ける。無い ID は 1）。
#   **知らない形の呼び出しは黙って通さずに落とす**（dev.sh が想定外の形で呼んだら赤にする）
# - tmux: `has-session -t =<名前>`（無ければ 1）と `new-session -A -s <名前>`
# - systemctl: `--user is-active <unit>` は状態の語を 1 行出し、active で 0、それ以外で 3
#
# 使い方:
#   bash packages/devhost/selftest.sh             同じディレクトリの dev.sh を試す
#   DEV_BIN=<path> bash packages/devhost/selftest.sh   別の dev.sh を試す（変異を当てるとき）
#   DEV_UNIT=<path> bash packages/devhost/selftest.sh  別のユニットを試す（同上）
#
# 終了コード: 0 = DEVHOST_SELFTEST_PASS / 1 = 期待と食い違った
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${DEV_BIN:-$HERE/dev.sh}"
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devhost-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKEBIN="$WORK/fakebin"
TOOLBIN="$WORK/toolbin"
mkdir -p "$FAKEBIN" "$TOOLBIN" "$WORK/home"

# dev.sh と偽物が使う道具だけを置く。本物の docker などが入った環境でも PATH から見えない。
for t in sed tail head cat rm mkdir grep tr env awk sleep mktemp; do  # bsd-ok: mktemp は呼び出しではなく、偽の PATH へ写す道具の名前の一覧
  p="$(command -v "$t")" || { echo "[devhost-selftest] $t が見つかりません" >&2; exit 1; }
  ln -s "$p" "$TOOLBIN/$t"
done

# ── 偽物 ──────────────────────────────────────────────────────────────────────
# 記録の書式: 道具の名前に続けて、引数を 1 つずつ [ ] で囲む（空白を含む引数を取り違えない）。
cat >"$FAKEBIN/_log" <<'EOF'
log_call() {
  local line="$1"
  shift
  local a
  for a in "$@"; do line="$line [$a]"; done
  printf '%s\n' "$line" >>"$FAKE_LOG"
}
# コンテナの状態: 1 行 1 つで「ワークスペースのパス<TAB>ID<TAB>状態」。
STATE_FILE="$FAKE_STATE/containers"
touch_state() { [[ -f "$STATE_FILE" ]] || : >"$STATE_FILE"; }
EOF

cat >"$FAKEBIN/devcontainer" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/devcontainer" <<'EOF'
log_call devcontainer "$@"
touch_state
sub="${1:-}"
shift || true
wf=""
remove=0
# オプションは --名前 値 の対で読む。最初のオプションでない語で止まる（exec の halt-at-non-option）。
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --workspace-folder) wf="$2"; shift 2 ;;
    --remove-existing-container) remove=1; shift ;;
    *) echo "fake devcontainer: この試験が想定していないオプションです: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$wf" ]] || { echo "fake devcontainer: --workspace-folder がありません" >&2; exit 2; }
if [[ ! -f "$wf/.devcontainer/devcontainer.json" && ! -f "$wf/.devcontainer.json" ]]; then
  echo "Dev container config ($wf/.devcontainer/devcontainer.json) not found." >&2
  [[ "$sub" == "up" ]] && printf '{"outcome":"error","message":"Dev container config (%s/.devcontainer/devcontainer.json) not found.","description":"Dev container config (%s/.devcontainer/devcontainer.json) not found."}\n' "$wf" "$wf"
  exit 1
fi
find_row() { grep -F "$wf	" "$STATE_FILE" | sed -n 1p || true; }
case "$sub" in
  up)
    [[ $# -eq 0 ]] || { echo "fake devcontainer: up に余分な引数があります: $*" >&2; exit 2; }
    if [[ -n "${FAKE_UP_SIGNAL:-}" ]]; then
      # 作り直しの最中に、dev（親）がシグナルを受ける状況（ssh の切断など）を作る。
      kill -s "$FAKE_UP_SIGNAL" "$PPID"
      exit 1
    fi
    if [[ "${FAKE_UP_FAIL:-0}" == "1" ]]; then
      echo "[fake] Error: docker compose up が失敗しました" >&2
      printf '{"outcome":"error","message":"Command failed: docker compose up -d","description":"An error occurred starting Docker Compose up."}\n'
      exit 1
    fi
    row="$(find_row)"
    if [[ -n "$row" && "$remove" == 1 ]]; then
      # 古いコンテナを消して、別の ID で作り直す。
      id="$(printf '%s\n' "$row" | cut -f 2)"
      grep -vF "$wf	" "$STATE_FILE" >"$STATE_FILE.new" || true
      mv "$STATE_FILE.new" "$STATE_FILE"
      id="${id}n"
    elif [[ -n "$row" ]]; then
      id="$(printf '%s\n' "$row" | cut -f 2)"
      grep -vF "$wf	" "$STATE_FILE" >"$STATE_FILE.new" || true
      mv "$STATE_FILE.new" "$STATE_FILE"
    else
      id="$(printf '%s' "$wf" | cksum | cut -d ' ' -f 1)"
      id="c0ffee${id}"
    fi
    printf '%s\t%s\trunning\n' "$wf" "$id" >>"$STATE_FILE"
    echo "[fake] Start: Run: docker compose up -d" >&2
    printf '{"outcome":"success","containerId":"%s","composeProjectName":"x_devcontainer","remoteUser":"vscode","remoteWorkspaceFolder":"/workspaces/x"}\n' "$id"
    ;;
  exec)
    [[ $# -gt 0 ]] || { echo "Not enough non-option arguments: got 0, need at least 1" >&2; exit 1; }
    row="$(find_row)"
    if [[ -z "$row" || "$(printf '%s\n' "$row" | cut -f 3)" != "running" ]]; then
      echo "Dev container not found." >&2
      exit 1
    fi
    if [[ "${FAKE_EXEC_FAIL:-0}" == "1" ]]; then
      echo "OCI runtime exec failed: exec failed: unable to start container process: procReady not received: unknown" >&2
      exit 1
    fi
    if [[ "${FAKE_EXEC_HANG:-0}" == "ignoreterm" ]]; then
      # TERM を無視して居座る（KILL でしか止まらない）。20 秒で自分で終わる（直す前の dev.sh を
      # 試験に当てたとき、いつまでも居座らないため）。
      trap '' TERM
      for ((hang_i = 0; hang_i < 20; hang_i++)); do sleep 1; done
      exit 0
    fi
    if [[ "${FAKE_EXEC_HANG:-0}" == "1" ]]; then
      # 応答が返らない状況（本物は exec が止まったまま）。sleep そのものに置き換わるので、
      # 親が PID を kill すれば確実に終わる。
      exec sleep 20
    fi
    [[ "$1" == "true" ]] && exit 0
    exec "$@"
    ;;
  *) echo "fake devcontainer: この試験が想定していないサブコマンドです: $sub" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/docker" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/docker" <<'EOF'
log_call docker "$@"
touch_state
sub="${1:-}"
shift || true
case "$sub" in
  ps)
    all=0 filter="" format=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=1; shift ;;
        --filter) filter="$2"; shift 2 ;;
        --format) format="$2"; shift 2 ;;
        *) echo "fake docker: この試験が想定していない ps の引数です: $1" >&2; exit 2 ;;
      esac
    done
    [[ "$filter" == label=devcontainer.local_folder=* ]] || { echo "fake docker: 想定外の filter: $filter" >&2; exit 2; }
    [[ "$format" == '{{.ID}} {{.State}}' ]] || { echo "fake docker: 想定外の format: $format" >&2; exit 2; }
    want="${filter#label=devcontainer.local_folder=}"
    while IFS='	' read -r path id state; do
      [[ "$path" == "$want" ]] || continue
      [[ "$all" == 1 || "$state" == "running" ]] || continue
      printf '%s %s\n' "$id" "$state"
    done <"$STATE_FILE"
    ;;
  inspect)
    [[ $# -eq 3 && "$1" == "--format" && "$2" == '{{.State.Pid}}' ]] || { echo "fake docker: 想定外の inspect の引数: $*" >&2; exit 2; }
    row="$(grep -F "	$3	" "$STATE_FILE" || true)"
    if [[ -z "$row" ]]; then
      echo "Error: No such object: $3" >&2
      exit 1
    fi
    if [[ "$(printf '%s\n' "$row" | cut -f 3)" == "running" ]]; then
      echo "${FAKE_CONTAINER_PID:-4242}"
    else
      echo 0
    fi
    ;;
  wait)
    [[ $# -eq 1 ]] || { echo "fake docker: wait の引数は 1 つだけを想定しています" >&2; exit 2; }
    if ! grep -qF "	$1	" "$STATE_FILE"; then
      echo "Error response from daemon: No such container: $1" >&2
      exit 1
    fi
    # 止まったことにする（本物はここで止まるまで待つ）。
    sed "s/	$1	running\$/	$1	exited/" "$STATE_FILE" >"$STATE_FILE.new"
    mv "$STATE_FILE.new" "$STATE_FILE"
    echo "${FAKE_WAIT_CODE:-137}"
    ;;
  *) echo "fake docker: この試験が想定していないサブコマンドです: $sub" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/tmux" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/tmux" <<'EOF'
log_call tmux "$@"
case "${1:-}" in
  has-session)
    [[ "${2:-}" == "-t" ]] || exit 2
    name="${3#=}"
    for s in ${FAKE_TMUX_SESSIONS:-}; do [[ "$s" == "$name" ]] && exit 0; done
    echo "can't find session: $name" >&2
    exit 1
    ;;
  new-session) exit "${FAKE_TMUX_EXIT:-0}" ;;
  *) echo "fake tmux: この試験が想定していない呼び出しです: $*" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/systemctl" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/systemctl" <<'EOF'
log_call systemctl "$@"
[[ "${1:-}" == "--user" && $# -eq 3 ]] || { echo "fake systemctl: 想定外の呼び出し: $*" >&2; exit 2; }
case "$2" in
  is-active)
    if [[ "${FAKE_SYSTEMCTL_FAIL:-}" == "is-active" ]]; then
      # 問い合わせ自体の失敗（バスに繋がらないなど）。状態の語は出さない。
      echo "Failed to connect to user scope bus via local transport: No medium found" >&2
      exit 1
    fi
    for u in ${FAKE_ACTIVE_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo active; exit 0; }
    done
    # Restart= の待機中は activating、失敗して止まったままのものは failed（どちらも 3 で抜ける）。
    for u in ${FAKE_ACTIVATING_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo activating; exit 3; }
    done
    # ユニットを入れていない機械（dev だけを置く運用）。本物は unknown を出し、4 で抜ける。
    for u in ${FAKE_UNKNOWN_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo unknown; exit 4; }
    done
    for u in ${FAKE_FAILED_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo failed; exit 3; }
    done
    echo inactive
    exit 3
    ;;
  stop | start)
    if [[ "${FAKE_SYSTEMCTL_FAIL:-}" == "$2" ]]; then
      echo "Failed to $2 $3: Access denied" >&2
      exit 1
    fi
    exit 0
    ;;
  *) echo "fake systemctl: 想定外のサブコマンド: $2" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/git" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/git" <<'EOF'
log_call git "$@"
[[ $# -eq 4 && "$1" == "-C" && "$3" == "pull" && "$4" == "--ff-only" ]] || { echo "fake git: 想定外の呼び出し: $*" >&2; exit 2; }
[[ -d "$2" ]] || { echo "fatal: cannot change to '$2': No such file or directory" >&2; exit 128; }
if [[ "${FAKE_GIT_FAIL:-0}" == "1" ]]; then
  echo "fatal: Not possible to fast-forward, aborting." >&2
  exit 128
fi
echo "Already up to date."
EOF

cat >"$FAKEBIN/ps" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/ps" <<'EOF'
log_call ps "$@"
[[ $# -eq 2 && "$1" == "-eo" && "$2" == "pid=,stat=" ]] || { echo "fake ps: 想定外の呼び出し: $*" >&2; exit 2; }
# 「PID 状態」の列を FAKE_STATE/ps（1 行 1 タスクで「PID 状態」）から、PID を右寄せで出す。
[[ -f "$FAKE_STATE/ps" ]] || exit 0
while read -r p s; do
  printf '%7s %s\n' "$p" "$s"
done <"$FAKE_STATE/ps"
EOF

cat >"$FAKEBIN/journalctl" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/journalctl" <<'EOF'
log_call journalctl "$@"
[[ $# -eq 6 && "$1" == "--user" && "$2" == "-u" && "$4" == "-n" && "$6" == "--no-pager" ]] || { echo "fake journalctl: 想定外の呼び出し: $*" >&2; exit 2; }
if [[ -n "${FAKE_JOURNAL:-}" ]]; then
  printf '%s\n' "$FAKE_JOURNAL"
else
  echo "-- No entries --"
fi
EOF
chmod +x "$FAKEBIN/devcontainer" "$FAKEBIN/docker" "$FAKEBIN/tmux" "$FAKEBIN/systemctl" "$FAKEBIN/git" "$FAKEBIN/ps" "$FAKEBIN/journalctl"
for t in cut cksum mv; do
  p="$(command -v "$t")" || { echo "[devhost-selftest] $t が見つかりません" >&2; exit 1; }
  ln -s "$p" "$TOOLBIN/$t"
done

# ── 仕込み ────────────────────────────────────────────────────────────────────
PROJ="$WORK/projects"
mkdir -p "$PROJ/alpha/.devcontainer" "$PROJ/beta"
echo '{}' >"$PROJ/alpha/.devcontainer/devcontainer.json"
echo '{}' >"$PROJ/beta/.devcontainer.json"
CONF="$WORK/conf/projects"
mkdir -p "$WORK/conf"
cat >"$CONF" <<EOF
# 試験の設定
alpha  $PROJ/alpha   # 行末のコメント

beta   $PROJ/beta    tmux_session=work
EOF

# ── 回し方 ────────────────────────────────────────────────────────────────────
fail=0
n=0
ng() { echo "[devhost-selftest] FAIL: $*" >&2; fail=1; }

OUT="$WORK/out" ERR="$WORK/err" LOG="$WORK/calls"
STATE="$WORK/state"

reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : >"$STATE/containers"
}

# run <期待する終了コード> <試験の名前> -- [VAR=値 ...] -- dev の引数 ...
# 呼び出しの記録は毎回空にしてから回す（コンテナの状態は reset_state までは持ち越す）。
run() {
  local want="$1" name="$2" code=0
  shift 2
  [[ "$1" == "--" ]] && shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  : >"$LOG"
  n=$((n + 1))
  CUR="$name"
  env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
    DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
    DEV_PROC_ROOT="$WORK/proc" DEV_CGROUP_ROOT="$WORK/cg" \
    ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$DEV" "$@" >"$OUT" 2>"$ERR" </dev/null || code=$?
  if [[ "$code" != "$want" ]]; then
    ng "$name: 終了コード want $want got $code"
    sed 's/^/    stderr: /' "$ERR" >&2
  fi
}

# 記録がこの並びと完全に一致すること。
expect_calls() {
  local want got
  want="$(printf '%s\n' "$@")"
  got="$(cat "$LOG")"
  if [[ "$got" != "$want" ]]; then
    ng "$CUR: 呼び出しの記録が違います"
    printf '    want:\n%s\n    got:\n%s\n' "$want" "$got" >&2
  fi
}

expect_no_calls() {
  if [[ -s "$LOG" ]]; then
    ng "$CUR: 下の道具を呼ばないはずが呼んでいます"
    sed 's/^/    /' "$LOG" >&2
  fi
}

expect_err() {
  grep -qF -- "$1" "$ERR" || { ng "$CUR: 標準エラーに「$1」がありません"; sed 's/^/    stderr: /' "$ERR" >&2; }
}

expect_out_line() {
  grep -qE -- "$1" "$OUT" || { ng "$CUR: 標準出力に /$1/ の行がありません"; sed 's/^/    stdout: /' "$OUT" >&2; }
}

A="$PROJ/alpha"
B="$PROJ/beta"

# ── 1. 設定ファイル ───────────────────────────────────────────────────────────
reset_state
T_CONF="$WORK/conf/none" run 2 "設定ファイルが無い" -- -- ls
expect_err "設定ファイルがありません: $WORK/conf/none"
expect_no_calls

bad() {
  local name="$1" body="$2" msg="$3"
  printf '%s\n' "$body" >"$WORK/conf/bad"
  T_CONF="$WORK/conf/bad" run 2 "壊れた設定: $name" -- -- up alpha
  expect_err "$msg"
  expect_no_calls
}
bad "パスが無い" "alpha" "$WORK/conf/bad:1: 「名前 絶対パス」の 2 つが要ります"
bad "相対パス" "alpha projects/alpha" "$WORK/conf/bad:1: パスは絶対パスで書きます"
bad "チルダ" "alpha ~/alpha" "$WORK/conf/bad:1: パスは絶対パスで書きます"
bad "知らないキー" "alpha $A aws_profile=x" "$WORK/conf/bad:1: 知らないキーです"
bad "キー=値でない" "alpha $A extra" "$WORK/conf/bad:1: 3 つ目以降は キー=値 で書きます"
bad "空の値" "alpha $A tmux_session=" "$WORK/conf/bad:1: 値が空です"
bad "名前の文字" "al/pha $A" "$WORK/conf/bad:1: 名前に使えるのは"
bad "重複" "$(printf '# c\nalpha %s\nalpha %s' "$A" "$B")" "$WORK/conf/bad:3: 名前が重複しています: alpha"
bad "空" "# だけ" "プロジェクトが 1 つもありません"

# CRLF で保存した設定でも読める（行末の CR がパスに混ざらない）。
printf 'alpha %s\r\n' "$A" >"$WORK/conf/crlf"
reset_state
T_CONF="$WORK/conf/crlf" run 0 "CRLF の設定" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"

# パスの末尾の / は外して扱う（ラベルの照合で動いているコンテナを取り違えない）。
printf 'alpha %s//\n' "$A" >"$WORK/conf/slash"
reset_state
T_CONF="$WORK/conf/slash" run 0 "末尾に / のあるパス: up" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
T_CONF="$WORK/conf/slash" run 0 "末尾に / のあるパス: attach" -- -- attach alpha
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]" \
  "tmux [new-session] [-A] [-s] [main]"

# ── 2. 未登録のプロジェクトを拒む ─────────────────────────────────────────────
for sub in up attach supervise rebuild doctor; do
  reset_state
  run 2 "未登録: $sub" -- -- "$sub" gamma
  expect_err "登録されていないプロジェクトです: gamma（登録済み: alpha beta）"
  expect_no_calls
done

# ── 3. up ─────────────────────────────────────────────────────────────────────
reset_state
run 0 "up alpha" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
expect_out_line '"outcome":"success"'
run 0 "up beta（.devcontainer.json の形）" -- -- up beta
expect_calls "devcontainer [up] [--workspace-folder] [$B]"
run 1 "up が失敗したら 1" -- FAKE_UP_FAIL=1 -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
printf 'ghost %s/ghost\n' "$PROJ" >"$WORK/conf/ghost"
T_CONF="$WORK/conf/ghost" run 1 "ディレクトリが無いプロジェクト" -- -- up ghost
expect_err "プロジェクトのディレクトリがありません: $PROJ/ghost"
expect_no_calls
run 2 "up の引数が多い" -- -- up alpha beta
expect_no_calls

# ── 4. attach ─────────────────────────────────────────────────────────────────
reset_state
run 1 "attach: 止まっていたら入らない" -- -- attach alpha
expect_err "alpha のコンテナが動いていません。dev up alpha"
expect_calls "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]"
run 0 "up してから" -- -- up alpha
run 0 "attach alpha" -- -- attach alpha
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]" \
  "tmux [new-session] [-A] [-s] [main]"
run 0 "up beta" -- -- up beta
run 0 "attach beta（tmux_session=work）" -- -- attach beta
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$B] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$B] [tmux] [new-session] [-A] [-s] [work]" \
  "tmux [new-session] [-A] [-s] [work]"

# ── 5. ls ─────────────────────────────────────────────────────────────────────
reset_state
run 0 "up alpha（ls の仕込み）" -- -- up alpha
run 0 "ls" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_TMUX_SESSIONS=main -- ls
expect_out_line '^NAME +CONTAINER +UNIT +TMUX$'
expect_out_line '^alpha +running +active +main$'
expect_out_line '^beta +none +inactive +-$'
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [has-session] [-t] [=main]" \
  "tmux [has-session] [-t] [=main]" \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$B] [--format] [{{.ID}} {{.State}}]" \
  "systemctl [--user] [is-active] [dev-up@beta.service]"
run 0 "ls（tmux 無し）" -- -- ls
expect_out_line '^alpha +running +inactive +none$'
# systemctl の無い機械（ユニットを使わない）では UNIT を - にする。
mv "$FAKEBIN/systemctl" "$WORK/systemctl.off"
run 0 "ls（systemctl が無い）" -- -- ls
expect_out_line '^alpha +running +- +none$'
mv "$WORK/systemctl.off" "$FAKEBIN/systemctl"
run 2 "ls に余分な引数" -- -- ls alpha

# ── 6. supervise（ユニットの ExecStart）─────────────────────────────────────
reset_state
run 1 "supervise: 起こして、止まったら 0 以外で抜ける" -- FAKE_WAIT_CODE=0 -- supervise alpha
id_a="$(grep -F "$A	" "$STATE/containers" | cut -f 2)"
expect_calls \
  "devcontainer [up] [--workspace-folder] [$A]" \
  "docker [wait] [$id_a]"
expect_err "コンテナ $id_a が止まりました（終了コード 0）"
grep -qF "$A	$id_a	exited" "$STATE/containers" || ng "supervise: 待った後のコンテナが exited になっていません"
run 1 "supervise: 2 回目（止まったコンテナを同じ ID で起こし直す）" -- -- supervise alpha
expect_calls \
  "devcontainer [up] [--workspace-folder] [$A]" \
  "docker [wait] [$id_a]"
expect_err "（終了コード 137）"
run 1 "supervise: up が失敗したら待たない" -- FAKE_UP_FAIL=1 -- supervise alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
expect_err "devcontainer up が失敗しました"

# ── 6a. attach: exec が通らなければ、doctor と rebuild を案内して 1 で終わる ──
DOCKER_PS_A="docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]"
reset_state
run 0 "up alpha（attach の失敗の仕込み）" -- -- up alpha
run 1 "attach: exec が通らない" -- FAKE_EXEC_FAIL=1 -- attach alpha
expect_calls \
  "$DOCKER_PS_A" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]"
expect_err "dev doctor alpha"
expect_err "dev rebuild alpha"
# 入れたあとにセッションが異常終了した場合も、dev は 1 で終わり（0/1/2 の取り決め）、
# 元の終了コードは文面に出す（区別できないと言う）。
run 1 "attach: 1 以外のコードでも 1 で終わり、元のコードを文面に出す" -- FAKE_TMUX_EXIT=7 -- attach alpha
expect_err "dev doctor alpha"
expect_err "終了コード 7"
expect_err "区別できません"

# ── 6b. rebuild ───────────────────────────────────────────────────────────────
UP_RM="devcontainer [up] [--workspace-folder] [$A] [--remove-existing-container]"
reset_state
run 0 "up alpha（rebuild の仕込み）" -- -- up alpha
id_old="$(cut -f 2 "$STATE/containers")"
run 0 "rebuild: 動いているユニットを止め → 作り直し → 起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
id_new="$(cut -f 2 "$STATE/containers")"
[[ -n "$id_new" && "$id_new" != "$id_old" ]] || ng "rebuild: コンテナの ID が変わっていません（作り直していない）"
run 0 "rebuild: 動いていないユニットは止めも起こしもしない" -- -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild: 作り直しが失敗しても、止めたユニットは起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_FAIL=1 -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
expect_err "作り直しが失敗しました"
run 1 "rebuild: 作り直しが失敗し、ユニットも動いていなければ起こさない" -- FAKE_UP_FAIL=1 -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild: ユニットを止められなければ作り直さない" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_SYSTEMCTL_FAIL=stop -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]"
run 1 "rebuild: 起こし直しに失敗したら 1" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_SYSTEMCTL_FAIL=start -- rebuild alpha
expect_err "を起こせませんでした"
mv "$FAKEBIN/systemctl" "$WORK/systemctl.off"
run 0 "rebuild: systemctl が無い機械ではユニットに触らない" -- -- rebuild alpha
expect_calls "$UP_RM"
mv "$WORK/systemctl.off" "$FAKEBIN/systemctl"
run 0 "rebuild --pull: 先に pull してから作り直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha --pull
expect_calls \
  "git [-C] [$A] [pull] [--ff-only]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
run 0 "rebuild --pull（オプションが先でも同じ）" -- -- rebuild --pull alpha
expect_calls \
  "git [-C] [$A] [pull] [--ff-only]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild --pull: pull が失敗したら作り直さない（ユニットにも触らない）" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_GIT_FAIL=1 -- rebuild alpha --pull
expect_calls "git [-C] [$A] [pull] [--ff-only]"
expect_err "作り直しません"
# Restart= の待機中（activating）のユニットも止める。failed は止めない。
STOP_FLOW=(
  "systemctl [--user] [is-active] [dev-up@alpha.service]"
  "systemctl [--user] [stop] [dev-up@alpha.service]"
  "$UP_RM"
  "systemctl [--user] [start] [dev-up@alpha.service]"
)
run 0 "rebuild: activating のユニットも止めて、起こし直す" -- FAKE_ACTIVATING_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls "${STOP_FLOW[@]}"
run 0 "rebuild: failed のユニットは触らない" -- FAKE_FAILED_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
# 作り直しの最中の中断（ssh の切断など）でも、止めたユニットは起こし直してから抜ける。
for sg in "TERM 143" "INT 130" "HUP 129"; do
  run "${sg#* }" "rebuild: ${sg% *} で中断されても起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_SIGNAL="${sg% *}" -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
  expect_err "起こし直しました"
done
# ssh が切れると、標準出力・標準エラーが閉じる（#475）。閉じた出力への書き込みで抜けても、
# 止めたユニットは起こし直していること。終了コードは問わない（出力の失敗をどう返すかより、
# ユニットが戻ることが約束）。2 つの閉じ方を試す: fd を閉じる（EBADF）／読み手の居ないパイプ（SIGPIPE）。
run_closed() { # 閉じ方 名前 -- [環境変数...] -- 引数...
  local how="$1" name="$2"
  shift 2
  [[ "$1" == "--" ]] && shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  : >"$LOG"
  n=$((n + 1))
  CUR="$name"
  if [[ "$how" == "fd" ]]; then
    env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
      DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
      ${envs[@]+"${envs[@]}"} \
      "$BASH_BIN" "$DEV" "$@" </dev/null >&- 2>&- || true
  else
    # 読み手（:）がすぐ終わるので、書き込みは SIGPIPE / EPIPE になる。標準エラーも同じパイプへ。
    { env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
      DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
      ${envs[@]+"${envs[@]}"} \
      "$BASH_BIN" "$DEV" "$@" </dev/null 2>&1 || true; } | sleep 0
  fi
}
for how in fd pipe; do
  run_closed "$how" "rebuild: 出力が閉じていても（$how）、止めたユニットを起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
  run_closed "$how" "rebuild: 出力が閉じたうえで HUP で中断されても（$how）、起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_SIGNAL=HUP -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
done
run 0 "rebuild: unknown（ユニットを入れていない）は触らずに作り直す" -- FAKE_UNKNOWN_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
# systemctl はあるのに状態を引けないときは、止めずに作り直さず、何も変えずに 1 で止まる。
run 1 "rebuild: 状態を引けなければ作り直さない" -- FAKE_SYSTEMCTL_FAIL=is-active -- rebuild alpha
expect_calls "systemctl [--user] [is-active] [dev-up@alpha.service]"
expect_err "状態が分からない"
expect_err "systemctl --user status dev-up@alpha.service"
run 2 "rebuild: 知らないオプション" -- -- rebuild alpha --force
expect_no_calls
run 2 "rebuild: 名前が無い" -- -- rebuild --pull
expect_no_calls
run 2 "rebuild: 名前が 2 つ" -- -- rebuild alpha beta
expect_no_calls

# ── 6c. doctor ────────────────────────────────────────────────────────────────
CG="/system.slice/docker-abc.scope"
# 偽の /proc と cgroup の木を作る。引数: コンテナの PID / cgroup のパス / pids.current / pids.max /
# pids.events の max / memory.events の oom_kill
mk_cg() {
  local cgdir="$WORK/cg$2"
  rm -rf "$WORK/proc" "$WORK/cg"
  rm -f "$STATE/ps"
  mkdir -p "$WORK/proc/$1" "$cgdir"
  printf '0::%s\n' "$2" >"$WORK/proc/$1/cgroup"
  printf '%s\n' "$3" >"$cgdir/pids.current"
  printf '%s\n' "$4" >"$cgdir/pids.max"
  printf 'max %s\n' "$5" >"$cgdir/pids.events"
  printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill %s\noom_group_kill 0\n' "$6" >"$cgdir/memory.events"
}
# ゾンビ（や他の状態）のタスクを足す。引数: PID / 状態 / cgroup のパス
add_task() {
  mkdir -p "$WORK/proc/$1"
  printf '0::%s\n' "$3" >"$WORK/proc/$1/cgroup"
  printf '%s %s\n' "$1" "$2" >>"$STATE/ps"
}
add_zombies() {
  local k
  for ((k = 0; k < $1; k++)); do add_task $((5000 + k)) Z "$2"; done
}
doctor_up() {
  reset_state
  run 0 "up alpha（doctor の仕込み）" -- -- up alpha
}

doctor_up
mk_cg 4242 "$CG" 20 1000 0 0
add_task 1 Ss /init.scope
add_task 4242 Ss "$CG"
add_task 4300 S "$CG/child"
add_zombies 3 "$CG"
add_task 4400 Z "$CG/child"
add_task 4401 Z "/system.slice/docker-abcdef.scope"   # 前方が同じだけの別の cgroup（数えない）
add_task 4402 Z /user.slice
run 0 "doctor: 正常" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_JOURNAL='Oct 07 12:00:00 host dev[1]: 起こしました' -- doctor alpha
expect_out_line '\[OK +\] コンテナ [0-9a-z]+ は running'
expect_out_line '\[OK +\] exec が通ります'
expect_out_line '\[OK +\] pids: 20 / 1000（2%）'
expect_out_line '\[OK +\] pids の上限に当たった回数: 0'
expect_out_line '\[OK +\] oom_kill: 0'
expect_out_line '\[OK +\] ゾンビ: 4$'
expect_out_line 'ユニット dev-up@alpha.service: active'
expect_out_line '^    Oct 07 12:00:00 host dev\[1\]: 起こしました'
expect_out_line '判定: OK'
id_a="$(cut -f 2 "$STATE/containers")"
expect_calls \
  "$DOCKER_PS_A" \
  "devcontainer [exec] [--workspace-folder] [$A] [true]" \
  "docker [inspect] [--format] [{{.State.Pid}}] [$id_a]" \
  "ps [-eo] [pid=,stat=]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "journalctl [--user] [-u] [dev-up@alpha.service] [-n] [10] [--no-pager]"

run 1 "doctor: exec が通らない" -- FAKE_EXEC_FAIL=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が通りません（終了コード 1）: .*procReady not received'
expect_out_line '判定: FAIL'
expect_out_line 'dev rebuild alpha'
mk_cg 4242 "$CG" 18034 18039 5 0
run 1 "doctor: pids が上限に近い（issue の実測の値）" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 18034 / 18039（99%）'
expect_out_line '\[WARN\] pids の上限に当たった回数: 5'
mk_cg 4242 "$CG" 900 1000 0 0
run 1 "doctor: pids が上限のちょうど 90%" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 900 / 1000'
mk_cg 4242 "$CG" 899 1000 0 0
run 0 "doctor: pids が 90% 未満" -- -- doctor alpha
expect_out_line '\[OK +\] pids: 899 / 1000（89%）'
mk_cg 4242 "$CG" 899 max 0 0
run 0 "doctor: pids.max が max（上限なし）" -- -- doctor alpha
expect_out_line '上限なし'
mk_cg 4242 "$CG" 20 1000 0 0
add_zombies 100 "$CG"
run 3 "doctor: ゾンビが 100（WARN だけは 3）" -- -- doctor alpha
expect_out_line '\[WARN\] ゾンビ: 100（100 以上）'
expect_out_line '判定: WARN'
mk_cg 4242 "$CG" 20 1000 0 0
add_zombies 99 "$CG"
run 0 "doctor: ゾンビが 99" -- -- doctor alpha
expect_out_line '\[OK +\] ゾンビ: 99$'
mk_cg 4242 "$CG" 20 1000 1 0
run 3 "doctor: 上限に当たった回数が 1" -- -- doctor alpha
expect_out_line '\[WARN\] pids の上限に当たった回数: 1'
mk_cg 4242 "$CG" 20 1000 0 2
run 3 "doctor: oom_kill が 2" -- -- doctor alpha
expect_out_line '\[WARN\] OOM で殺された回数（oom_kill）: 2'
# pids.max が読めない・壊れている・0。「上限なし」の OK にしない。
mk_cg 4242 "$CG" 20 "" 0 0
run 3 "doctor: pids.max が空" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max を読めません'
if grep -qF '上限なし' "$OUT"; then ng "pids.max が空なのに「上限なし」と出ています"; fi
mk_cg 4242 "$CG" 20 garbage 0 0
run 3 "doctor: pids.max が数でも max でもない" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max が数でも max でもありません: garbage'
mk_cg 4242 "$CG" 0 0 0 0
run 1 "doctor: pids.max が 0" -- -- doctor alpha
expect_out_line '\[FAIL\] pids.max が 0 です'
# 上位の cgroup（systemd の slice の TasksMax など）の上限も見る。
set_pids() { # cgroup のパス pids.current pids.max
  mkdir -p "$WORK/cg$1"
  printf '%s\n' "$2" >"$WORK/cg$1/pids.current"
  printf '%s\n' "$3" >"$WORK/cg$1/pids.max"
}
mk_cg 4242 "$CG" 20 max 0 0
set_pids /system.slice 950 1000
run 1 "doctor: 上位の slice の上限に近い" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 950 / 1000（95%）（階層: /system.slice）'
mk_cg 4242 "$CG" 500 1000 0 0
set_pids /system.slice 960 10000
run 0 "doctor: 比が最大の階層を使う（自身 50% と上位 9%）" -- -- doctor alpha
expect_out_line "\\[OK +\\] pids: 500 / 1000（50%）（階層: $CG）"
mk_cg 4242 "$CG" 500 1000 0 0
set_pids / 2 2   # 根の pids.max は本物には無いが、あっても遡れること
run 1 "doctor: 根まで遡る" -- -- doctor alpha
expect_out_line '階層: /）'
# 上位の階層で pids.max が有限なのに pids.current が読めない／壊れているときは、黙って無視しない。
mk_cg 4242 "$CG" 20 max 0 0
mkdir -p "$WORK/cg/system.slice"
printf '1000\n' >"$WORK/cg/system.slice/pids.max"
run 3 "doctor: 上位の pids.current が読めない" -- -- doctor alpha
expect_out_line '\[WARN\] pids.current を読めません（階層: /system.slice。pids.max は 1000）'
if grep -qF '上限なし' "$OUT"; then ng "上位の pids.current が読めないのに「上限なし」と出ています"; fi
mk_cg 4242 "$CG" 20 max 0 0
mkdir -p "$WORK/cg/system.slice"
printf 'bogus\n' >"$WORK/cg/system.slice/pids.max"
run 3 "doctor: 上位の pids.max が壊れている" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max が数でも max でもありません: bogus（階層: /system.slice）'
# TERM を無視する exec でも、猶予のあとに KILL して、doctor が時間内に FAIL で返る。
mk_cg 4242 "$CG" 20 1000 0 0
kstart=$SECONDS
run 1 "doctor: TERM を無視する exec" -- FAKE_EXEC_HANG=ignoreterm DEV_EXEC_TIMEOUT=1 DEV_EXEC_KILL_GRACE=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が 1 秒で返りません'
if [[ $((SECONDS - kstart)) -ge 10 ]]; then ng "doctor: TERM を無視する exec で $((SECONDS - kstart)) 秒かかりました（KILL で止まるはず）"; fi
run 2 "doctor: DEV_EXEC_KILL_GRACE=0 は使い方の誤り" -- DEV_EXEC_KILL_GRACE=0 -- doctor alpha
expect_err "DEV_EXEC_KILL_GRACE は 1 以上の整数"
expect_no_calls
# DEV_EXEC_TIMEOUT は 1 以上の整数だけ（GNU の timeout 0 は無制限になり、返らなくなる）。
for tv in 0 abc -5 1.5; do
  run 2 "doctor: DEV_EXEC_TIMEOUT=$tv は使い方の誤り" -- DEV_EXEC_TIMEOUT="$tv" -- doctor alpha
  expect_err "DEV_EXEC_TIMEOUT は 1 以上の整数"
  expect_no_calls
done
# ゾンビが多い環境（issue の実測は 18000 超）でも、ゾンビの数に比例してプロセスを起こさず、
# 短い時間で終わる（1 個ごとにサブシェルを起こすと数十秒かかる）。
mk_cg 4242 "$CG" 20 1000 0 0
# mkdir の引数が長くなりすぎないよう（macOS の上限を超えうる）、1000 個ずつ作る。
zdirs=()
for ((zk = 20000; zk < 38000; zk++)); do
  zdirs+=("$WORK/proc/$zk")
  if [[ ${#zdirs[@]} -ge 1000 ]]; then
    mkdir -p "${zdirs[@]}"
    zdirs=()
  fi
done
for ((zk = 20000; zk < 38000; zk++)); do
  printf '0::%s\n' "$CG" >"$WORK/proc/$zk/cgroup"
  printf '%s Z\n' "$zk" >>"$STATE/ps"
done
zstart=$SECONDS
run 3 "doctor: ゾンビが 18000" -- -- doctor alpha
expect_out_line '\[WARN\] ゾンビ: 18000（100 以上）'
echo "[devhost-selftest] ゾンビ 18000 の doctor: $((SECONDS - zstart)) 秒" >&2
if [[ $((SECONDS - zstart)) -ge "${DEVHOST_ZOMBIE_LIMIT:-2}" ]]; then ng "doctor: ゾンビ 18000 の処理に $((SECONDS - zstart)) 秒かかりました（${DEVHOST_ZOMBIE_LIMIT:-2} 秒未満のはず）"; fi
# exec が返らないとき、timeout が無い環境でも時間で切る（この試験の PATH に timeout は無い）。
mk_cg 4242 "$CG" 20 1000 0 0
run 1 "doctor: exec が返らない（timeout 無し）" -- FAKE_EXEC_HANG=1 DEV_EXEC_TIMEOUT=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が 1 秒で返りません'
mk_cg 4242 "$CG" 20 1000 1 0
run 1 "doctor: WARN と FAIL が混ざれば FAIL（1）" -- FAKE_EXEC_FAIL=1 -- doctor alpha
rm -rf "$WORK/proc" "$WORK/cg"
run 3 "doctor: cgroup を読めない（偽の木が空）は WARN" -- -- doctor alpha
expect_out_line '\[WARN\] .*cgroup v2 のパスを読めません'
# 止まっているコンテナと、無いコンテナ。
reset_state
run 1 "doctor: コンテナが無い" -- -- doctor alpha
expect_out_line '\[FAIL\] コンテナがありません'
expect_calls \
  "$DOCKER_PS_A" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "journalctl [--user] [-u] [dev-up@alpha.service] [-n] [10] [--no-pager]"
printf '%s\tdead01\texited\n' "$A" >"$STATE/containers"
run 1 "doctor: コンテナが止まっている" -- -- doctor alpha
expect_out_line '\[FAIL\] コンテナ dead01 の状態が exited です'
run 2 "doctor: 引数なし" -- -- doctor
expect_no_calls

# ── 6d. help ──────────────────────────────────────────────────────────────────
for sub in ls up attach supervise rebuild doctor help; do
  run 0 "help $sub" -- -- help "$sub"
  expect_no_calls
  expect_out_line "^dev $sub — "
  expect_out_line '^終了コード: '
done
run 0 "help（引数なし）は使い方の一覧" -- -- help
expect_out_line "^プロジェクトの一覧は $CONF から読む。\$"
run 0 "help: 設定ファイルの既定のパスを展開して出す" -- XDG_CONFIG_HOME=/xdg DEV_PROJECTS_FILE= -- help
expect_out_line '^プロジェクトの一覧は /xdg/dev/projects から読む。$'
if grep -qF '${' "$OUT"; then ng "help の出力に未展開の \${...} があります"; fi
expect_out_line '^  dev rebuild <名前> \[--pull\]$'
expect_out_line '^  dev doctor <名前>$'
run 2 "help: 知らないサブコマンド" -- -- help stop
expect_err "知らないサブコマンドです: stop"
expect_no_calls
run 2 "help: 引数が多い" -- -- help ls up
expect_no_calls
run 0 "rebuild の説明にユニットの扱いがある" -- -- help rebuild
expect_out_line 'ユニット dev-up@<名前> が inactive / failed / unknown（ユニットを入れていない）でなければ止める'
expect_out_line '3 が失敗しても、INT / HUP / TERM で中断されても'

# ── 6e. README の「コマンドの説明」と dev help の照合 ─────────────────────────
# README の各サブコマンドのブロック（### dev <名前> の次の ```text ... ```）が dev help <名前> の
# 出力と一致すること、README のサブコマンドの集合が dev の受け付ける集合と一致することを確かめる。
# dev の受け付ける集合は、dev help の一覧から取り、さらに 1 つずつ実際に受け付けることを確かめる。
README="${DEV_README:-$HERE/README.md}"
readme_check() {
  local readme="$1" bad=0 usage_set help_set readme_set s want got
  # dev が受け付ける集合は、dev help が判定に使う help_<名前> の定義（dev.sh）から取る。
  # usage の一覧（dev help）も同じ集合でなければ落とす。
  help_set="$(sed -n 's/^help_\([a-z][a-z]*\)() {$/\1/p' "$DEV" | sort -u)"
  usage_set="$("$BASH_BIN" "$DEV" help | sed -n 's/^  dev \([a-z][a-z]*\).*/\1/p' | sort -u)"
  readme_set="$(sed -n 's/^### dev \([a-z][a-z]*\)$/\1/p' "$readme" | sort -u)"
  if [[ -z "$help_set" || "$help_set" != "$readme_set" || "$help_set" != "$usage_set" ]]; then
    echo "サブコマンドの集合が違います" >&2
    printf '  help_ 関数: %s\n  usage:      %s\n  README:     %s\n' "$(echo $help_set)" "$(echo $usage_set)" "$(echo $readme_set)" >&2
    bad=1
  fi
  for s in $help_set; do
    # 実際に受け付ける（知らないサブコマンドなら help が 2 で落ちる）。
    "$BASH_BIN" "$DEV" help "$s" >/dev/null 2>&1 || { echo "dev help $s が通りません" >&2; bad=1; }
    want="$("$BASH_BIN" "$DEV" help "$s" 2>&1 || true)"
    got="$(awk -v h="### dev $s" '
      $0 == h { f = 1; next }
      f && !b && $0 == "```text" { b = 1; next }
      f && b && $0 == "```" { exit }
      f && b { print }
    ' "$readme")"
    if [[ -z "$got" || "$got" != "$want" ]]; then
      echo "README の dev $s のブロックが dev help $s の出力と違います" >&2
      bad=1
    fi
  done
  return "$bad"
}
CUR="README の照合"
n=$((n + 1))
if ! readme_check "$README"; then ng "README が dev help と一致しません"; fi
# dev が実際に受け付けるサブコマンドの確認: 一覧の各名前を引数なしで呼ぶと、使い方の誤り（2）で
# 「使い方: dev <名前>」と返る（知らないサブコマンドなら一覧の usage が出る）。help だけは 0。
for sub in ls up attach supervise rebuild doctor; do
  if [[ "$sub" == "ls" ]]; then
    run 2 "$sub は引数を受け付けない（使い方の誤り）" -- -- "$sub" x
  else
    run 2 "引数なしの $sub は使い方の誤り" -- -- "$sub"
  fi
  expect_err "使い方: dev $sub"
  expect_no_calls
done
# 検査が死んでいないこと: 1 行を書き換えた README では落ちる。
M="$WORK/readme.mut"
sed 's/^dev ls — /dev ls ー /' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README の説明の 1 行を書き換えても照合が通ります"; fi
sed 's/^終了コード: 0 = 作り直した/終了コード: 9 = 作り直した/' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README の終了コードの行を書き換えても照合が通ります"; fi
sed '/^### dev doctor$/d' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README からサブコマンドの見出しを消しても照合が通ります"; fi
{ cat "$README"; printf '\n### dev stop\n\n```text\nx\n```\n'; } >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README へ dev に無いサブコマンドを足しても照合が通ります"; fi
# 検査が元の README では通ること（変異のたびに通らなくなっただけ、を除く）。
readme_check "$README" >/dev/null 2>&1 || ng "README の照合が、変異の後で通らなくなりました"

# ── 7. 使い方 ─────────────────────────────────────────────────────────────────
run 2 "引数なし" -- --
expect_no_calls
run 2 "知らないサブコマンド" -- -- start alpha
expect_no_calls
run 2 "auth は受け付けない（特定クラウドへの認証は持たない）" -- -- auth aws alpha
expect_no_calls

# ── 8. ユニット（dev-up@.service）の要の行 ───────────────────────────────────
# systemd はこの環境に無いので読み込みは試せない。崩すと「戻らない」につながる行だけを綴りで見る。
UNIT="${DEV_UNIT:-$HERE/dev-up@.service}"
CUR="ユニット"
unit_has() { grep -qxF -- "$1" "$UNIT" || ng "ユニットに「$1」の行がありません（$2）"; }
unit_has 'ExecStart=%h/.local/bin/dev supervise %i' "起こして止まるまで待つ口。%I は - を / へ戻すので使わない"
unit_has 'Restart=always' "止まった理由を問わず起こし直す"
unit_has 'StartLimitIntervalSec=0' "起動の直後に Docker が遅れても諦めない"
unit_has 'WantedBy=default.target' "ユーザーのマネージャの起動（linger で起動時）に付く"
if grep -qE '^[^#]*%I' "$UNIT"; then ng "ユニットが %I を使っています（名前の - が / に化ける）"; fi

if [[ "$fail" -ne 0 ]]; then
  echo "DEVHOST_SELFTEST_FAIL" >&2
  exit 1
fi
echo "[devhost-selftest] $n 件の呼び出しを確かめました"
echo "DEVHOST_SELFTEST_PASS"
