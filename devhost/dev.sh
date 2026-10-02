#!/usr/bin/env bash
# dev — SSH で届く外部の機械に置く入口の道具。devcontainer を起こし、入る。
#
# 外部の機械へは `~/.local/bin/dev` として置く（導入の手順は README.md）。端末からは
# `ssh -t <ホスト> .local/bin/dev attach <名前>` の 1 行をショートカットにして叩く。
#
# ## 使い方
#
#   dev ls                     登録したプロジェクトの状態を並べる
#   dev up <名前>               devcontainer を起こす（在れば何もしない）
#   dev attach <名前>           コンテナの中の tmux に入る（無ければ作る）
#   dev supervise <名前>        起こして止まるまで待つ（systemd のユニットから使う）
#
# ## プロジェクトの一覧
#
# **名前とパスはこの道具に書かない。** 外部の機械の設定ファイルから読む（既定は
# `${XDG_CONFIG_HOME:-$HOME/.config}/dev/projects`。`DEV_PROJECTS_FILE` で差し替えられる）。
# 書式は projects.example にある。1 行 1 プロジェクトで、空白区切りの
# `名前 絶対パス [キー=値 ...]`。キーは次の 1 つだけを受け付ける（綴りの誤りを黙って
# 無視しないため、知らないキーは設定の誤りとして止まる）。
#
#   tmux_session=<t>     `dev attach` が入る tmux のセッション名（既定 main）
#
# ## 起動の口を devcontainer CLI に揃える理由
#
# compose 方式でもイメージ方式でも `devcontainer up --workspace-folder` の 1 つの口で起こせ、
# VS Code の「Reopen in Container」と同じラベル（devcontainer.local_folder）でコンテナを
# 探すので、VS Code で作ったコンテナにもそのまま入れる。**各プロジェクトの compose や
# devcontainer.json は書き換えない**（同じ定義を使う別の端末の挙動を変えないため）。
#
# ## しないこと
#
# - **tmux と、その中のエージェントを自動で起こさない。** 自動で戻すのはコンテナまで
#   （systemd のユニット dev-up@.service）。tmux は `dev attach` が手で起こす。
# - **特定のクラウドへの認証を持たない。** 認証はコンテナの中で手で行う。`dev attach` で
#   入ったあとのシェルで、プロジェクトが使う CLI（aws / gcloud 等）を直接叩く。
#
# 終了コード: 0 = 成功 / 1 = 実行の失敗（コンテナが無い・下の道具が失敗した）/
#             2 = 使い方か設定ファイルの誤り（未登録の名前を含む）
set -euo pipefail

PROG="dev"
DEFAULT_TMUX_SESSION="main"

# ssh の非対話のコマンド（`ssh <ホスト> .local/bin/dev ...`）と systemd のユーザーのユニットは
# ~/.profile を読まないので、~/.local/bin などが PATH に無い。devcontainer CLI の既定の置き場所
# （公式の install.sh は ~/.devcontainers/bin）と ~/.local/bin を**末尾へ**足す（先に在る PATH を優先する）。
PATH="$PATH:$HOME/.devcontainers/bin:$HOME/.local/bin"

die() { echo "[$PROG] $*" >&2; exit 1; }
usage_error() { echo "[$PROG] $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
使い方:
  dev ls
  dev up <名前>
  dev attach <名前>
  dev supervise <名前>      （systemd のユニット dev-up@.service から使う）

プロジェクトの一覧は ${DEV_PROJECTS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dev/projects} から読む。
EOF
}

projects_file() {
  if [[ -n "${DEV_PROJECTS_FILE:-}" ]]; then
    printf '%s\n' "$DEV_PROJECTS_FILE"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dev/projects"
  fi
}

# ── 設定ファイル ──────────────────────────────────────────────────────────────
# 読んだ結果は並びの配列に置く（連想配列を使わないのは、macOS の bash 3.2 でも
# 自己試験が読めるようにするため）。
P_NAMES=()
P_PATHS=()
P_TMUX=()

load_projects() {
  local file lineno=0 line name path kv key val i
  local tmux_s
  file="$(projects_file)"
  if [[ ! -f "$file" ]]; then
    usage_error "設定ファイルがありません: $file
[$PROG] 雛形（projects.example）を写して、名前と絶対パスを 1 行ずつ書いてください。"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # 行末の CR（Windows の改行で保存したとき）と、# 以降のコメントを外す。
    line="${line%$'\r'}"
    line="${line%%#*}"
    # 空白で語に分けるのが書式そのもの。glob の展開は set -f で止める。
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [[ $# -gt 0 ]] || continue
    if [[ $# -lt 2 ]]; then
      usage_error "$file:$lineno: 「名前 絶対パス」の 2 つが要ります: $line"
    fi
    name="$1" path="$2"
    shift 2
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      usage_error "$file:$lineno: 名前に使えるのは英数字と _ . - だけです（systemd のインスタンス名にもなるため）: $name"
    fi
    if [[ "$path" != /* ]]; then
      usage_error "$file:$lineno: パスは絶対パスで書きます（~ や \$HOME は展開しません）: $path"
    fi
    # 末尾の / を外す。devcontainer はラベル（devcontainer.local_folder）に / の無い形を
    # 書くので、/ 付きのまま照合すると、動いているコンテナを「無い」と取り違える。
    while [[ "$path" == */ && "$path" != / ]]; do path="${path%/}"; done
    for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
      [[ "${P_NAMES[$i]}" == "$name" ]] && usage_error "$file:$lineno: 名前が重複しています: $name"
    done
    tmux_s="$DEFAULT_TMUX_SESSION"
    for kv in "$@"; do
      if [[ "$kv" != *=* ]]; then
        usage_error "$file:$lineno: 3 つ目以降は キー=値 で書きます: $kv"
      fi
      key="${kv%%=*}" val="${kv#*=}"
      [[ -n "$val" ]] || usage_error "$file:$lineno: 値が空です: $kv"
      case "$key" in
        tmux_session) tmux_s="$val" ;;
        *) usage_error "$file:$lineno: 知らないキーです（tmux_session）: $key" ;;
      esac
    done
    P_NAMES+=("$name")
    P_PATHS+=("$path")
    P_TMUX+=("$tmux_s")
  done <"$file"
  if [[ ${#P_NAMES[@]} -eq 0 ]]; then
    usage_error "設定ファイルにプロジェクトが 1 つもありません: $file"
  fi
}

# 名前から添字を引く。未登録なら登録済みの名前を添えて止まる（下の道具は 1 つも呼ばない）。
IDX=-1
find_project() {
  local name="$1" i
  for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
    if [[ "${P_NAMES[$i]}" == "$name" ]]; then
      IDX=$i
      return 0
    fi
  done
  usage_error "登録されていないプロジェクトです: $name（登録済み: ${P_NAMES[*]}）"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。$2"
}

need_project_dir() {
  local path="${P_PATHS[$IDX]}"
  [[ -d "$path" ]] || die "プロジェクトのディレクトリがありません: $path（設定ファイルのパスを確かめてください）"
}

# devcontainer が付けるラベル（devcontainer.local_folder = 外部の機械のワークスペースの絶対パス）で
# コンテナを探す。VS Code が作ったコンテナも同じラベルを持つ。
# 出力: "<ID> <状態>"（状態は docker の State。running / exited など）。無ければ空。
container_of() {
  # head -n 1 ではなく sed -n 1p で受ける。head は 1 行読んだ時点でパイプを閉じ、
  # docker ps が SIGPIPE で死ぬ（pipefail 下では関数の終了コードが反転する）。
  # sed -n 1p は入力を最後まで読み切るので、生産側は正常終了する。
  docker ps -a --filter "label=devcontainer.local_folder=$1" --format '{{.ID}} {{.State}}' | sed -n '1p'
}

is_running() {
  local row
  row="$(container_of "$1")" || return 1
  [[ "${row#* }" == "running" ]]
}

dc_exec() {
  # devcontainer exec は最初の「オプションでない語」より後をそのままコマンドへ渡す
  # （CLI 0.89.0 の halt-at-non-option）。したがって CLI のオプションは必ずコマンドの前に置く。
  devcontainer exec --workspace-folder "${P_PATHS[$IDX]}" "$@"
}

# ── サブコマンド ──────────────────────────────────────────────────────────────

cmd_up() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev up <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  devcontainer up --workspace-folder "${P_PATHS[$IDX]}"
}

cmd_attach() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev attach <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  if ! is_running "${P_PATHS[$IDX]}"; then
    # 自分では起こさない。ユニットが起こし直している最中に 2 本目の up を重ねないため。
    die "$1 のコンテナが動いていません。dev up $1 で起こしてから入り直してください（ユニットを有効にしていれば、30 秒ほどで戻ります）。"
  fi
  dc_exec tmux new-session -A -s "${P_TMUX[$IDX]}"
}

cmd_ls() {
  [[ $# -eq 0 ]] || usage_error "使い方: dev ls"
  load_projects
  need docker "Docker Engine を入れてください。"
  local i path row state unit tmux_s
  printf '%-20s %-10s %-10s %s\n' NAME CONTAINER UNIT TMUX
  for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
    IDX=$i
    path="${P_PATHS[$i]}"
    row="$(container_of "$path" || true)"
    if [[ -z "$row" ]]; then state="none"; else state="${row#* }"; fi
    unit="-"
    if command -v systemctl >/dev/null 2>&1; then
      # is-active は状態の語を 1 行出し、active 以外では 0 以外で抜ける。
      unit="$(systemctl --user is-active "dev-up@${P_NAMES[$i]}.service" 2>/dev/null || true)"
      [[ -n "$unit" ]] || unit="-"
    fi
    tmux_s="-"
    if [[ "$state" == "running" ]] && command -v devcontainer >/dev/null 2>&1; then
      # =名前 は完全一致（tmux は -t の名前を前方一致でも引くため）。
      if dc_exec tmux has-session -t "=${P_TMUX[$i]}" </dev/null >/dev/null 2>&1; then
        tmux_s="${P_TMUX[$i]}"
      else
        tmux_s="none"
      fi
    fi
    printf '%-20s %-10s %-10s %s\n' "${P_NAMES[$i]}" "$state" "$unit" "$tmux_s"
  done
}

# systemd のユニット（dev-up@.service）の ExecStart。起こしてから、コンテナが止まるまで待つ。
#
# **止まった理由を問わず、0 以外で抜ける。** VS Code の窓を閉じたときの stopCompose は
# docker から見れば「意図した停止」だが、このプロセスにとっては「待っていたコンテナが
# 止まった」でしかない。0 以外で抜けるので、ユニットの Restart= がどの値でも起こし直す
# （判断の全文は README.md の「VS Code の窓を閉じたときの停止（stopCompose）」）。
cmd_supervise() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev supervise <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  local out id code
  # up は結果の JSON を 1 行で標準出力へ、経過を標準エラーへ出す（失敗の JSON でも 1 で抜ける）。
  out="$(devcontainer up --workspace-folder "${P_PATHS[$IDX]}")" || die "$1: devcontainer up が失敗しました: $out"
  id="$(printf '%s\n' "$out" | tail -n 1 | sed -n 's/.*"containerId":"\([0-9A-Za-z]*\)".*/\1/p')"
  [[ -n "$id" ]] || die "$1: devcontainer up の結果にコンテナの ID がありません: $out"
  echo "[$PROG] $1: コンテナ $id を起こしました。止まるまで待ちます。"
  code="$(docker wait "$id")" || die "$1: docker wait が失敗しました（コンテナ $id）"
  die "$1: コンテナ $id が止まりました（終了コード $code）。ユニットが起こし直します。"
}

main() {
  [[ $# -ge 1 ]] || { usage >&2; exit 2; }
  local sub="$1"
  shift
  case "$sub" in
    ls) cmd_ls "$@" ;;
    up) cmd_up "$@" ;;
    attach) cmd_attach "$@" ;;
    supervise) cmd_supervise "$@" ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
