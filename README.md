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
このパッケージは devcontainer と対応言語（node / go / python / php / rust / ruby）を前提とするため、それ以外の環境では ai-playbook 側の導入手順を使ってください。

## 3 パッケージの関係

<!-- package-relations:begin -->
ai-playbook・devcontainer-bootstrap（DCB）・devcontainer-host（devhost）は、それぞれ単体で使えます。DCB を中心に組み合わせると、効果が最大になります。

| パッケージ | 単体での用途 | 配布先 |
|---|---|---|
| ai-playbook | AI 運用の規範（ルール）だけを、プロジェクトへ入れる | ojos/ai-playbook |
| DCB | プロジェクトの devcontainer を 1 コマンドで生成する | ojos/devcontainer-bootstrap |
| devhost | 任意の `devcontainer.json` を持つプロジェクトを、SSH で届く外部の機械で常駐させる | ojos/devcontainer-host |

**DCB が中心です。** DCB は、ほかの 2 つが着地する場所（プロジェクトの devcontainer）を作ります。ai-playbook の規範はその中に置かれ（DCB が配布機構で、正本は ai-playbook です）、devhost はそのコンテナを外部の機械で動かし続けます。

- **DCB と ai-playbook**: DCB が、生成先のプロジェクトへ規範を配置します（`--playbook-version` などで取得元を指定する。新しい版へ移るときは、`--upgrade` に新しい `--playbook-version` を渡す）。DCB は規範の内容を持ちません。
- **DCB と devhost**: DCB の生成物には、devhost が前提にする、または助かるもの（tmux、compose の `init: true`、codex のサンドボックスの設定（`--with-codex` のとき）、UID の合わせ込み）が入っています。devhost は DCB の生成物でなくても使えますが、DCB の生成物ならこれらが最初から揃います。理由と意味は devhost の README の「DCB と一緒に使うと揃うもの」にあります。
- **ai-playbook と devhost**: 今は直接の関係がありません。

**入れ方は 2 段です。** 置く場所と単位が違うため、DCB のオプションでは devhost は入りません（DCB が書き込むのは生成先のプロジェクトの中だけで、外部の機械のホームやユーザーの systemd には書き込みません）。

1. プロジェクトごとに、プロジェクトの中へ DCB で devcontainer（と、必要なら規範）を生成する。
2. 外部の機械ごとに、外部の機械のホームへ devhost を入れ、設定ファイル（`projects`）にそのプロジェクトを 1 行足す。
<!-- package-relations:end -->

## 実行前提コマンド

`bootstrap.sh` は起動直後に次のコマンドの実在を検査し、**1 つでも欠けていればファイルを 1 つも書かずにエラー終了**します（`error: required command not found: <cmd>`）。

| コマンド | 必要になる場面 | 用途 |
|---|---|---|
| `jq` | 常時 | 生成する `devcontainer.json` の整形 |
| `perl` | 常時 | JSON テンプレートの末尾カンマ除去 |
| `awk` | 常時 | `.gitignore` の managed セクション差し替え、テンプレート名の重複除去 |
| `sed` | 常時 | テンプレートのプレースホルダ置換 |
| `curl` | 常時 | github/gitignore テンプレートの取得、規範アーカイブのダウンロード |
| `tar` | 規範の取得元に **URL** を指定した場合のみ（`--playbook-version` / URL 形式の `--playbook-from`） | アーカイブの展開 |

`doctor.sh` は `jq` と `perl` を使います（`devcontainer.json` の JSON 妥当性検査と `dockerComposeFile` の読み取り）。`--with-codex` の `devcontainer.json` は説明のコメント（`//`）を持つので、`doctor.sh` はコメントを除いてから `jq` へ渡します（JSONC として読みます。文字列の中の `//` は残します）。

`docker` は**任意**です。あればベースイメージの `os/arch` 適合を実際のマニフェストで判定し、無ければ既定の `mcr.microsoft.com/devcontainers/base:noble` へフォールバックします（警告のみで停止しません）。候補は版の名前（コードネーム）で固定しており、`ubuntu` / `debian` のような浮動タグは使いません（上流が指す版を無告知で進め、features の導入が壊れることがあるため）。

## 公開リリースからの利用

公開リポジトリ:
- https://github.com/ojos/devcontainer-bootstrap

最新安定リリース:
- `v0.23.6`

取得したスクリプトは実行前に必ず検証します。取得と実行は一時ディレクトリで行い、生成先は `--output-dir` で指定します。スクリプトの置き場所と生成先は独立しているため、実行後は `trap` で作業ディレクトリごと破棄でき、手元に取得物や後片付けが残りません。

```bash
TAG=v0.23.6
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"

d="$(mktemp -d "${TMPDIR:-/tmp}/dcb.XXXXXX")" || exit 1
trap 'rm -rf "$d"' EXIT
curl -sSL "${BASE}/bootstrap.sh" -o "$d/bootstrap.sh"
curl -sSL "${BASE}/SHA256SUMS"  -o "$d/SHA256SUMS"

# sha256sum は GNU coreutils のコマンドで、macOS には無い。shasum へ分岐する。
#
# SHA256SUMS は doctor.sh も対象にするため、取得した行だけを抜き出して検証する。
# --ignore-missing は実装と版によって有無が違うので使わない。一致する行が 1 件も
# 無ければ、どちらの実装も「整形された行が無い」として非 0 で終わるため、検証が
# 成立しないまま通ることはない。
#
# 検証と実行は && で連結する。この手順は対話シェルへ貼って使うため set -e が効かず、
# 行を分けると検証に失敗しても次の bash が走る。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
( cd "$d" && grep ' bootstrap.sh$' SHA256SUMS | $sha256c -c - ) &&
bash "$d/bootstrap.sh" --project-name myapp --output-dir "$PWD/myapp" \
  --languages node,go --with-aws --with-claude
```

一時ディレクトリから実行するため、次の 2 点に注意してください。

- **`--output-dir` を必ず明示します。** 省略時の既定は `$PWD/<project-name>`、つまり一時ディレクトリの中になり、生成物が `trap` で消えます。
- **`sha256sum` は GNU coreutils のコマンドで、macOS には入っていません。** 上の手順は `command -v` で判定して `shasum -a 256` へ分岐します。`--ignore-missing` は実装と版によって有無が違うため使わず、`SHA256SUMS` から**取得したファイルの行だけを抜き出して**検証します。

検証を挟まない `curl | bash` 形式は採りません。`SHA256SUMS` は**取得の破損・途中切断**と、**公開物どうしの食い違い**を検出します。省くと、手元に落ちたものが公開されたものと同じかを確かめる経路が無くなります。

> **この手順が守る範囲。** 上の検証で分かるのは「公開されている資産を、壊れずに取得できたか」までです。
>
> `SHA256SUMS` はスクリプトと同じリリースから同じ経路で取得します。**リリースを書き換えられる立場なら、スクリプトと `SHA256SUMS` の両方を同時に差し替えられます。**
>
> **この手順だけでは、リリース自体の改ざんには対抗しません。** リリースには artifact attestation が付いており、任意で検証できます（[任意: 署名の検証](#任意-署名の検証artifact-attestation)。GitHub CLI が要ります）。これを検証しない場合は、リリースの書き換えを防げません。取得元のタグを固定し、公開リポジトリのリリース履歴を信頼できる範囲で使ってください。

AI 共通ルールも配置する場合は、ルールの取得元を指定します。一時ディレクトリから実行すると隣接チェックアウトが存在しないため、`--playbook-version` または `--playbook-from` が必要です（[AI 共通ルールの配置](#ai-共通ルールの配置)）。

```bash
# 上の手順の最後（検証と実行）を、規範の取得元を足した形へ置き換える。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
( cd "$d" && grep ' bootstrap.sh$' SHA256SUMS | $sha256c -c - ) &&
bash "$d/bootstrap.sh" --project-name myapp --output-dir "$PWD/myapp" \
  --languages node,go --with-claude --playbook-version v0.12.2
```

`--playbook-version` は既定ソース `ojos/ai-playbook` のタグ tarball への糖衣で、長い archive URL を打たずに済みます。ソースを指定した時点で配置されるため `--with-playbook` は不要です。別 owner・任意の URL・ローカルディレクトリから取得する場合は、従来どおり `--playbook-from` を使います（`--playbook-version` とは排他）。

**`--with-claude` と組み合わせるときは、ai-playbook v0.9.0 以降を指定します。** v0.19.0 から、`--with-claude` は規範パッケージの雛形 `templates/claude-skill-peers.md`（`/peers` スキル）を必須にします。それより前の版を指定すると、`template not found` で書き込む前に停止します。`--with-claude` を使わない場合は、v0.5.0 以降で動きます。**ただし、ゲートのワークフローから定期実行をなくした形（課金枠を減らし続けない形）と、実行先の変数 `ACTIONS_RUNS_ON` の形を雛形のワークフローにも反映するには、v0.10.0 以降を指定します**（それより前の版では、`bootstrap.sh` が書く `identity-guard.yml` / `verify.yml` だけが変数の形になり、規範の雛形のワークフローは 20 分ごとの定期実行と `ubuntu-latest` の固定のまま残ります）。**規範を配置する構成では、v0.11.0 以降を指定します。** v0.21.0 から、生成する `scripts/loop-gate.sh` は、ステージ済みの差分があるとき、規範の雛形の `second-opinion-review.sh` に `--base` を渡します。`--base` は ai-playbook v0.11.0 の雛形で足したもので、それより前の版の雛形は `unknown option` で終わるため、`loop-gate.sh` が `GATE_FAIL` になります。新しく生成するときと `--upgrade` では v0.12.2 を勧めます（v0.22.1 は v0.11.0 でも動きますが、v0.12.0 以降の雛形は、エンジンを指定せずに既定の gemini へ落ちたときに知らせます。v0.12.1 は、第二意見が issue 本文のコード例の中の `acceptance:` を本物として採る不具合を直しています。v0.12.2 は、別のリポジトリの番号を素の `#N` と書いたときに、第二意見が同じ番号の別物と取り違えうることを、規範と第二意見のプロンプトに書いています）。

> **破壊的変更（`--mode` 廃止）**: 従来の `--mode <minimal|standard|full>` は廃止しました。装備は
> `--with-*` フラグで明示選択します。移行対応表は [mode オプションからの移行](#mode-オプションからの移行) を参照してください。

### doctor.sh を後から取得する

上の手順は `bootstrap.sh` だけを取得します。生成後の自己診断（[Doctor 自己診断](#doctor-自己診断)）を実行するときに、同じ要領で `doctor.sh` を取得します。`doctor.sh` も診断対象を `--target-dir` で受け取るため、一時ディレクトリから実行できます。

```bash
TAG=v0.23.6
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"

d="$(mktemp -d "${TMPDIR:-/tmp}/dcb.XXXXXX")" || exit 1
trap 'rm -rf "$d"' EXIT
curl -sSL "${BASE}/doctor.sh"  -o "$d/doctor.sh"
curl -sSL "${BASE}/SHA256SUMS" -o "$d/SHA256SUMS"

if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
( cd "$d" && grep ' doctor.sh$' SHA256SUMS | $sha256c -c - ) &&
bash "$d/doctor.sh" --target-dir ./myapp
```

診断のたびに取得すれば、生成先のリポジトリへ `doctor.sh` を混入させずに済みます。手元へ置いて繰り返し使う場合は、`bootstrap.sh` と `doctor.sh` を同じディレクトリへ取得し、`SHA256SUMS` から両方の行を抜き出して検証してください（`SHA256SUMS` は `PACKAGE_ARCHIVE.tar.gz` の行も持つため、アーカイブを取得していなければ行を抜き出さない `$sha256c -c SHA256SUMS` は失敗します）。

```bash
grep -E ' (bootstrap|doctor)\.sh$' SHA256SUMS | $sha256c -c -
```

### リリース資産

各リリースには次の 5 つを添付します。通常の利用に必要なのは上の 3 つだけで、残りの 2 つは「配布物そのものを検証・保全したい」場合に使います。

| 資産 | 用途 |
|---|---|
| `bootstrap.sh` | 生成コマンド本体。単体で動作します |
| `doctor.sh` | 生成後の自己診断コマンド。単体で動作します |
| `SHA256SUMS` | `bootstrap.sh` / `doctor.sh` / `PACKAGE_ARCHIVE.tar.gz` のチェックサム。3 つすべてを取得したなら `sha256sum -c SHA256SUMS`（macOS では `shasum -a 256 -c SHA256SUMS`）で**取得の破損**を検出します（守る範囲は [公開リリースからの利用](#公開リリースからの利用) の但し書きを参照）。一部だけ取得した場合は、その行を `grep` で抜き出して `-c -` へ渡します |
| `PACKAGE_ARCHIVE.tar.gz` | そのリリース時点の公開リポジトリのツリー一式（`.git` と生成した 3 資産を除く。`bootstrap.sh` / `doctor.sh` / この README / `LICENSE` / `CHANGELOG.md`）。スクリプトと手順書を 1 つの塊として手元へ固定したい場合や、リリース間の差分を追いたい場合に使います |
| `RELEASE-MANIFEST.json` | パッケージ名・版・資産一覧・チェックサムを機械可読にまとめたもの。`assets` がそのリリースに添付された資産の一覧、`checksums` が `PACKAGE_ARCHIVE.tar.gz` と `SHA256SUMS` のハッシュです |

検証は 2 段構えです。`RELEASE-MANIFEST.json` が `SHA256SUMS` と `PACKAGE_ARCHIVE.tar.gz` のハッシュを持ち、`SHA256SUMS` が `bootstrap.sh` / `doctor.sh` / `PACKAGE_ARCHIVE.tar.gz` のハッシュを持ちます。
**どの検証が何を保証するか**は次のとおりです。

- この 2 段（マニフェスト → `SHA256SUMS` → 各ファイル）が検出するのは、取得の破損と、公開物どうしの食い違いです。マニフェストも `SHA256SUMS` と同じ経路で取得するため、リリースを書き換えられる立場なら両方を揃えて差し替えられます。
- 後述の attestation が保証するのは、`SHA256SUMS` 1 つです。`SHA256SUMS` が `bootstrap.sh` / `doctor.sh` / `PACKAGE_ARCHIVE.tar.gz` のハッシュを持つので、attestation の検証に続けて `SHA256SUMS` と取得物を照合すれば、この 3 つと、アーカイブの中身（`CHANGELOG.md` や README など）まで辿れます。**個別の資産として添付される `RELEASE-MANIFEST.json` は `SHA256SUMS` に載らないため、attestation の保証に入りません**（アーカイブの中の `CHANGELOG.md` は保証の範囲内で、アーカイブの外に個別に添付されたものがあれば範囲外です）。
- **`PACKAGE_ARCHIVE.tar.gz` が `SHA256SUMS` に載るのは、v0.18.0 からです。** それより前の版（v0.17.0 まで）の `SHA256SUMS` には、アーカイブの行がありません。その場合、`SHA256SUMS` の照合（下の 2 行目）はアーカイブを確かめず、attestation もアーカイブには及びません。アーカイブはマニフェストのハッシュ（1 行目）だけで確かめることになり、マニフェストも attestation の保証外です。古い版のアーカイブを attestation の保証つきで使うことはできないので、保証が要るときは、アーカイブの行がある版を使ってください（`grep PACKAGE_ARCHIVE.tar.gz SHA256SUMS` で行の有無を確かめられます）。

照合と展開は `&&` でつなぎ、照合に失敗したら展開しません（行を分けると、失敗しても次の行が走ります）。

```bash
TAG=v0.23.6
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"
curl -sSL "${BASE}/RELEASE-MANIFEST.json" -o RELEASE-MANIFEST.json
curl -sSL "${BASE}/PACKAGE_ARCHIVE.tar.gz" -o PACKAGE_ARCHIVE.tar.gz
curl -sSL "${BASE}/SHA256SUMS" -o SHA256SUMS
curl -sSL "${BASE}/bootstrap.sh" -o bootstrap.sh
curl -sSL "${BASE}/doctor.sh" -o doctor.sh

# sha256sum は GNU coreutils のコマンドで、macOS には無い。shasum へ分岐する。
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi

# 1. マニフェストが記録したハッシュと実物を突き合わせる
# 2. 検証したいスクリプトとアーカイブを SHA256SUMS で検証する
# 3. 展開する（1 と 2 の両方が通ったときだけ）。アーカイブの中身はリポジトリのルートそのものなので、専用のディレクトリへ展開する。
#    再実行できるよう mkdir -p を使う。前回の展開物が残っていれば上書きされるが、新しい版で消えたファイルは残るので、版を変えるときは dcb/ を消してから実行する
jq -r '.checksums | to_entries[] | "\(.value)  \(.key)"' RELEASE-MANIFEST.json | $sha256c -c - \
  && $sha256c -c SHA256SUMS \
  && mkdir -p dcb && tar -xzf PACKAGE_ARCHIVE.tar.gz -C dcb && ls dcb/
```

### devhost — devcontainer を外部の機械で常駐させる道具

devcontainer を、SSH で届く外部の機械（自宅のラップトップ、社内のサーバーなど）の上で起動したまま保ち、
スマホやほかの端末から入って AI コーディングを続けるための道具一式（コマンド `dev`）です。
`devcontainer.json` を持つプロジェクトなら、DCB の生成物でなくても使えます。DCB の生成物には、devhost が前提にする、または助かるもの（tmux、compose の `init: true` など）が入っているので、組み合わせると前提が最初から揃います。関係の全体は上の「3 パッケージの関係」を参照してください。
**DCB のリリースには同梱していません。** 独自の版を持つ公開リポジトリ `ojos/devcontainer-host` のリリースで配っています。
外部の機械への導入の手順（マニフェストのハッシュの照合を含む）と使い方は、そのリポジトリの README の「外部の機械への導入」を参照してください。

以前の DCB のリリース（v0.14.0〜v0.17.0）は `PACKAGE_ARCHIVE.tar.gz` の `devhost/` に同梱していました。
その `dev` の `dev self-update` は更新できなくなり、何も置き換えずに止まります。**手で 1 度だけ入れ直してください**
（手順は `ojos/devcontainer-host` の README の「DCB 同梱の古い版から移るとき」）。

### 任意: 署名の検証（artifact attestation）

**この手順は任意です。** 上の 2 段の検証は `curl` とチェックサム実装（`sha256sum` か `shasum -a 256`）だけで閉じていますが、こちらは [GitHub CLI](https://cli.github.com/) が要ります。

リリースの `SHA256SUMS` には、GitHub Actions が発行した **artifact attestation**（SLSA provenance）が付いています。attestation の対象は `SHA256SUMS` 1 つで、`SHA256SUMS` が `bootstrap.sh` / `doctor.sh` / `PACKAGE_ARCHIVE.tar.gz` のハッシュを持ちます（アーカイブの行は、v0.18.0 から。それより前の版では、attestation はスクリプトの 2 つまでしか及びません）。**attestation の検証に続けて、上の手順で `SHA256SUMS` と取得物を照合してください**（attestation だけでは取得物までは確かめられません）。

```bash
# 取得元の owner を BASE から取り出す（固有名を手で書かない）
OWNER="$(printf '%s' "$BASE" | sed -n 's#^https://github.com/\([^/]*\)/.*#\1#p')"

if gh attestation verify SHA256SUMS --owner "$OWNER"; then
  echo "attestation: ok"
else
  echo "attestation: 検証に失敗しました" >&2
  exit 1
fi
```

**成功しても何も表示されません。** 端末に繋がっていない環境では標準出力も標準エラーも空になります。**判定は終了コードで行ってください**（0 = 成功、非 0 = 失敗）。

**終了コードを表示するだけの書き方（`gh attestation verify …; echo "exit=$?"`）にしないでください。** そのブロック全体の終了コードは `echo` のものになり、**検証の失敗が成功として扱われます**（実測: `( false; echo "exit=$?" )` は 0 を返す）。上のように分岐で受けてください。

**`--owner` に渡すのは、配布リポジトリの owner です。** attestation を発行しているのは同じ owner の別リポジトリ（開発リポジトリ）ですが、`--owner` はその owner に属する attestation をまとめて引くため、これで解決します。**発行元が別の owner へ移った場合、この手順は通らなくなります。**

> **この検証が守る範囲。** 分かるのは「その `SHA256SUMS` が、この owner の GitHub Actions のワークフローによって作られた」ことまでです。
>
> **ワークフローを実行できる立場なら、正規の attestation を作れます。** つまりリリースを書き換えられる攻撃者が同時にリポジトリへの書き込み権限を持つ場合、この検証は通ってしまいます。**信頼の起点が「リリースの内容」から「リポジトリへの書き込みの完全性」へ移るだけで、脅威が消えるわけではありません。**
>
> それでも、リリース資産だけを差し替える経路（たとえばリリースへの書き込み権限だけを得た場合）には対抗できます。

> 同じタグの資産は差し替えません。`PACKAGE_ARCHIVE.tar.gz` は tar がタイムスタンプを埋めるため内容が同じでもハッシュが変わり、上書きは常に別物への差し替えになるためです。タグを固定すれば内容も固定されます。

### ライセンスと変更履歴

公開リポジトリのルートには次の 2 ファイルを配布します（`PACKAGE_ARCHIVE.tar.gz` にも含まれます）。

| ファイル | 内容 |
|---|---|
| `LICENSE` | MIT License |
| `CHANGELOG.md` | 版ごとの変更点。公開しなかった版がある場合も、その事実とともに記録しています |

### 貢献の受け付け

**公開リポジトリは配布専用です。** 開発は別リポジトリで行い、リリースのたびに公開リポジトリの内容を全置換します。公開リポジトリへ直接 Pull Request を出しても次のリリースで失われるため、受け付けていません。不具合や要望は公開リポジトリの issue でお知らせください。

## 入力仕様

### 必須入力
- `--project-name <name>`（文字列。必須）
- `--languages <csv>`（CSV 形式。`node`、`go`、`python`、`php`、`rust`、`ruby` を任意に組み合わせ。必須）

### 装備オプション（`--with-*`）

装備は `--mode` ではなく `--with-*` フラグで明示選択します（オプトイン）。未指定なら素の環境（docker + 選択言語のみ）を生成します。docker のリッチさ（buildx / compose-switch）は全生成物で標準装備です。

| フラグ | 導入する装備 |
|---|---|
| `--with-aws` | AWS CLI feature + `amazonwebservices.aws-toolkit-vscode` 拡張 + Terraform（下記） |
| `--with-gcp` | Google Cloud CLI feature（外部 `dhoeric`）+ `GoogleCloudTools.cloudcode` 拡張 + Terraform（下記） |
| `--with-claude` | Claude Code CLI（`@anthropic-ai/claude-code`）+ `anthropic.claude-code` 拡張 + `~/.claude` 永続化 + マージ確認フック（下記） |
| `--with-gemini` | Gemini CLI（`@google/gemini-cli`）+ `Google.gemini-cli-vscode-ide-companion` 拡張 + `~/.gemini` 永続化 |
| `--with-antigravity` | Antigravity CLI（`agy`）+ `~/.gemini` 永続化 + テレメトリ無効化。**VS Code 拡張は入りません**。**OAuth のみ**で初回に対話ログインが要ります（下記） |
| `--with-codex` | Codex CLI（`@openai/codex`）+ `~/.codex` 永続化。**VS Code 拡張は入りません**。**ChatGPT アカウントの OAuth または API キー**で初回に対話ログインが要ります（下記）。版の下限があり、下回っていれば入れ替えます |
| `--with-copilot` | GitHub Copilot CLI（`@github/copilot`）+ `github.copilot` / `github.copilot-chat` 拡張 + `~/.copilot` 永続化 |
| `--with-copilot-review` | リモート最終ゲートのワークフロー 2 本（`.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml`）と、確認側が判定に使うスクリプト 2 本（`scripts/review-usable.sh` / `scripts/check-review-usable.sh`）。**ローカルの装備は一切入りません。** 規範の配置が前提（下記） |

- **ローカル装備とリモート機構は別フラグ**: `--with-copilot` が配線するのは手元の開発ツール（CLI・拡張・永続 volume）だけで、リモートのレビュー機構は `--with-copilot-review` が担います。効く場所が違うものを 1 つのフラグで束ねると、「リモートのレビューゲートだけ欲しい」構成を機構で表現できないためです（[リモートレビュー分離への移行](#リモートレビュー分離への移行)）。
- **`--with-copilot-review` は規範の配置が前提**: 配置するワークフローの雛形は規範パッケージが持つため、規範を配置しない構成では供給元がありません。`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれも指定せずに（または `--without-playbook` と併せて）指定すると、**ファイルを 1 つも書かずに**エラー終了します。
- **Terraform は cloud 随伴**: `--with-aws` または `--with-gcp` のいずれかを指定すると、Terraform feature + `hashicorp.terraform` 拡張が **1 回だけ** 同梱されます（両指定でも 1 回、cloud 無指定なら入りません）。
- **AI ツールは明示 opt-in のみ**: `--with-<ai>` を指定したときだけ、CLI 導入・VS Code 拡張・設定ディレクトリの永続化（compose named volume）を行います。トークン有無による自動導入は行いません。
- **`--with-gemini` と `--with-antigravity` は永続 volume を共有**: `agy` は資格情報を `~/.gemini/antigravity-cli/` に置くため、両者は同じ `~/.gemini` を使います。**どちらか一方でも指定すれば `gemini-storage` が 1 つだけ**作られ、両方指定しても重複しません。認証手段が違う（API キー / OAuth）ので、フラグは束ねず独立にしてあります。片方だけ使う構成をそのまま表現できます。
- **`--with-codex` は専用の永続 volume**: Codex CLI は資格情報を `~/.codex/auth.json` に置くため、`gemini` / `antigravity` とは別の `codex-storage` を使います。認証手段（ChatGPT アカウントの OAuth または API キー）も設定ディレクトリも他の AI CLI と独立なので、既存のどの装備とも共有しません。
- **`--with-codex` はコンテナの AppArmor と seccomp の既定の制限を外します**: codex のサンドボックスがコンテナの中で動くように、生成物の `devcontainer.json` へ `"securityOpt": ["apparmor=unconfined", "seccomp=unconfined"]` を入れます（`compose.yaml` の `security_opt` ではありません。理由は下記）。`--with-codex` を選ばない構成には入りません（下記「[コンテナの中での codex のサンドボックス](#コンテナの中での-codex-のサンドボックス)」）。
- **資格情報はホストから注入しません**: `remoteEnv` が運ぶのは作業ディレクトリのパス（`LOCAL_WORKSPACE_FOLDER`）だけです。認証はコンテナ内で行い、その状態を named volume に残します。唯一の例外は GitHub CLI で、PAT を `.env` の `GH_TOKEN` へ置けます（下記「[資格情報の扱い](#資格情報の扱い)」）。

### オプション入力
- `--output-dir <path>`（既定: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（既定: Docker サーバーの `os/arch` から自動判定。この値で上書きして明示指定）
- `--dry-run`（既定: 無効。生成予定のパスを `plan:` 行として並べるだけで、**ファイルを 1 つも書きません**）
- `--force`（既定: 無効。既存ファイルの上書きを許可します。下記「再実行したときの挙動」参照）
- `--upgrade`（既定: 無効。記録した入力で生成し直し、手を入れていないファイルだけを新しい版へ更新します。振り分け・終了コード・`--dry-run`・注意は下記「再実行したときの挙動」参照。`--force` とは同時に指定できません）
- `--baseline-from <dir>`（既定: なし。`--upgrade` と一緒のときだけ指定できます。旧い版の `bootstrap.sh` で生成した結果のディレクトリを渡し、ORIGIN に `hash:` の記録が無いファイルを、`<dir>` の同じ相対パスの内容と照合します。一致した現物は手を入れていないものとして新しい版へ更新します。`<dir>` は読むだけで書き込まず、`<dir>` 側のリンクはたどりません（`<dir>` 自体がシンボリックリンクなら止まるので実体のパスを渡します。中のリンクは一致しない扱い）。出力先そのもの、空の文字列も止まります。`--upgrade` 以外と一緒に指定するか、`<dir>` が存在するディレクトリでなければ、何も書かずに止まります。ORIGIN には記録しません。下記「`--upgrade` の注意」の ORIGIN が無い出力先の項目参照）
- `--accept <path>...`（既定: 無効。手を入れて取り込みを済ませたファイルを、ORIGIN へ「取り込み済み」として記録します。生成・`--upgrade` とは別の 3 つ目の動作で、生成の引数や `--upgrade` とは同時に指定できません。`--output-dir`（既定: カレントディレクトリ）と `--dry-run` とは併用できます。下記「`--accept`: 手を入れたファイルを取り込み済みとして記録する」参照）
- `--no-gitignore`（既定: 無効＝`.gitignore` の managed セクションを更新する。指定すると `.gitignore` に一切触れません）
- `--gitignore-targets <csv>`（既定: 空。暗黙ターゲットに**追加で合成**する github/gitignore テンプレート名。下記「`.gitignore` と github/gitignore の連携」参照）
- `--absent <path>...`（既定: 無効。生成先が意図して置かない生成物を、ORIGIN へ `absent:` として記録します。`--upgrade` はそのファイルを作り直さず、`doctor.sh` は欠けていても FAIL にしません。`--accept` と並ぶ動作で、生成の引数や `--upgrade` とは同時に指定できません。`--output-dir`（既定: カレントディレクトリ）と `--dry-run` とは併用できます。下記「`--absent`: 生成物を意図して置かないと記録する」参照）
- `--no-absent <path>...`（既定: 無効。`absent:` の記録を外します。次の `--upgrade` でそのファイルが生成されます。`--absent` と同じく、生成の引数や `--upgrade` とは同時に指定できません）
- `--second-opinion-engine <gemini|antigravity|codex>`（既定: 指定なし。`.env.example` の `SECOND_OPINION_ENGINE` へ記入するエンジンを明示します。指定が無いときの決め方は変わりません。ORIGIN に `input:second-opinion-engine` として記録し、`--upgrade` が引き継ぎます。**生成の前に、次の場合は何も書かずに非 0 で止まります**: 未知の値、空の値、`--with-<そのエンジン>` で選んでいないエンジン、`--with-antigravity` も `--with-codex` も選んでいない構成。最後の構成は `.env.example` に `SECOND_OPINION_ENGINE` の記入欄を出さず、指定の行き先が無いためです。値が無いまま最後の引数になっている場合も、エラーで止まります。`--accept` とは同時に指定できません。**`--upgrade` の引き継ぎ**: 記録した値は、渡さなければそのまま使われ、渡せば上書きされます。引き継いだ値が、`--without-<エンジン>` で外した、または選んだ構成から消えたために使えなくなったときは、止めずに警告を出し、ORIGIN の記録を外して指定が無いときの決め方に戻します（明示した値の場合は止まります）。引き継いだ値が未知の値なら、ORIGIN の破損として止まります。下記「`SECOND_OPINION_ENGINE`」参照）
- `--claude-remote-control`（既定: 無効。オプトインです。コンテナを作るとき、生成される `scripts/install-ai-tools.sh` が `~/.claude/settings.json` に `remoteControlAtStartup: true` を足し、Claude Code の Remote Control を常に有効にします。**`--with-claude` が要ります**（無い構成では、生成の前に何も書かずに非 0 で止まります）。`--accept` とは同時に指定できません。ORIGIN に `input:claude-remote-control=true` として記録し、`--upgrade` が引き継ぎます（`--without-claude` で行き先が無くなったときは、止めずに警告を出して記録を外します。`--upgrade --dry-run` では書き込まず、「外すことになります」と警告します）。記録の値が `true` 以外のときは、ORIGIN の破損として止まります。**効く範囲と注意**:
  - この設定がユーザー設定（`~/.claude/settings.json`）に置かれるのは、拡張の判定が `true` を読むのをユーザー設定と管理ポリシーに限るためです（プロジェクトの `.claude/settings.json` の `true` は読まれず、`false` で止めるときにしか効きません）。コミットする形では有効にできません。
  - `~/.claude` は named volume なので、**同じ volume を使うすべてのワークスペースに効きます**。新しく起動するセッションから効き、すでに動いているセッションは変わりません。
  - Remote Control は、**外部からセッションを操作できる入口を開く**機能です。そのため既定にしていません。
  - マージは、キーが無いときだけ `true` を足します。既存のキーは保ち、利用者が書いた `false` は覆しません（冪等です）。ファイルが無ければ作ります。`jq` が無い、JSON として読めない、シンボリックリンクである、書き込めない、といったときは、警告を出して飛ばします（コンテナの作成は止めません）。既存のファイルを書き換えるときは元の権限を保ち、新規に作るときだけ 600 にします。
  - **オプションを外しても、足したキーは消えません。** `--upgrade --no-claude-remote-control` で ORIGIN の記録を外し、`install-ai-tools.sh` から処理を取り除きますが、すでに書いた `remoteControlAtStartup` は残ります。無効にするには `~/.claude/settings.json` を手で直します。）
- `--no-claude-remote-control`（既定: 無効。`--upgrade` と併用して、ORIGIN に記録した `--claude-remote-control` を引き継がず、外して生成します。生成時に単独で使っても、未指定と同じです。`--claude-remote-control` と同時に指定すると止まります。`--accept` とは同時に指定できません）
- `--no-update-check`（既定: 無効＝確認する。生成物の `scripts/update-check.sh`（新しい版の確認と追従。[新しい版の確認と追従](#新しい版の確認と追従update-check)）を動かさない記録を、ORIGIN に `input:update-check=off` として残します。`--upgrade` は引き継ぎます。`.env` の `UPDATE_CHECK=off` でも止められます。`--update-check` と同時に指定すると止まります。`--accept` とは同時に指定できません）
- `--update-check`（`--upgrade` と併用して、ORIGIN に記録した `--no-update-check` を外し、確認を有効に戻します。生成時に単独で使っても、未指定と同じです。ORIGIN の `input:update-check` の値が `off` 以外のときは破損として止まり、この指定で直せます）
- `--with-playbook` / `--without-playbook`（AI 共通ルールの配置。既定: 配置しない）
- `--without-aws` / `--without-gcp` / `--without-claude` / `--without-gemini` / `--without-antigravity` / `--without-codex` / `--without-copilot` / `--without-copilot-review`（`--with-<名前>` のそれぞれと対になる打ち消し。`--upgrade` では、記録した集合から外し、外したフラグでだけ生成していたファイルのうち手を入れていないものを削除します。`--upgrade` 以外では「付けない」と同じなので受け付けるだけで、既存のファイルには触れません。同じ名前の `--with-<名前>` と同時に指定するとエラーで止まり、何も書きません。下記「`--upgrade` の注意」参照）
- `--playbook-version <tag>`（既定: 空。既定ソース `ojos/ai-playbook` のタグ tarball への糖衣。`--playbook-from` とは排他。`<tag>` は GitHub の実タグ名をそのまま指定します。例: `v0.1.4`（先頭の `v` を含む）。存在しないタグを指定すると、**ファイルを 1 つも書かずに**明示エラーで終了します）
- `--playbook-from <path|url>`（既定: 空。ルールの取得元。ディレクトリまたはアーカイブ URL。別 owner・任意 URL・ローカル用）
- `--playbook-conflict-policy <skip|overwrite|prompt>`（既定: `skip`。**規範ファイル**に既存がある場合の扱い）
- `-h` / `--help`（使い方を表示して終了。何も生成しません）

### 廃止フラグ

次のフラグは廃止済みです。いずれも**黙って無視されるのではなくエラー終了**します（指定したのに効いていない、という曖昧な状態を作らないため）。

| 廃止フラグ | 移行先 |
|---|---|
| `--mode <minimal\|standard\|full>` | `--with-*` フラグで装備を明示選択（[mode オプションからの移行](#mode-オプションからの移行)）。未知のオプションとして拒否されます |
| `--github-profiles` | コンテナ内で `gh auth login`（ホストからの資格情報注入は廃止） |
| `--gemini-key-env` | 生成先の `.env` に `GEMINI_API_KEY` を置く（`scripts/load-project-env.sh` が読む） |

### 再実行したときの挙動

同じ出力先へ再実行したときの挙動は、指定したフラグで 3 通りに分かれます。

| | 従来の再実行（既定） | `--force` | `--upgrade` |
|---|---|---|---|
| 既存ファイル | そのまま温存（`skip (exists): <path>`） | 新しいテンプレートで上書き | ファイルごとに振り分ける（下記） |
| 手を入れたファイル | 温存 | **手元の改造ごと上書き** | 温存し、新しい版を `<path>.dcb-new` として隣へ置く |
| 手を入れていないファイル | 温存（古いまま） | 上書き | 新しい版へ更新 |
| 生成の入力 | 毎回、引数で渡す | 毎回、引数で渡す | `.devcontainer/ORIGIN` の記録から再現し、引数で渡したものだけ上書きする |
| 終了コード | 0 | 0 | 0 / 2 / 1（下記） |

- `--playbook-conflict-policy` が効くのは**規範ファイル**（`.ai-playbook/**` / 入口ファイル / `scripts/second-opinion-review.sh` など）の従来の再実行だけです。`.devcontainer/` や `scripts/` のテンプレート生成物には効きません。`--upgrade` では効かず、規範ファイルもテンプレートと同じ振り分けになります。
- `.gitignore` の managed セクションは、どの場合も毎回差し替えます（セクション外の行は保持）。`--upgrade` もこの挙動を変えません。
- **生成先がシンボリックリンクのとき**（`--upgrade` を付けない再実行・`--force`・規範の配置）は、切れたリンクも含めて「既存のファイルがある」として扱い、リンク先（出力先の外）へは書きません。既定（skip）は温存して `skip (exists)` と報告します。`--force`（DCB のテンプレート）/ `--playbook-conflict-policy overwrite`（規範経由のファイル）ではリンク自体を通常ファイルで置き換え、リンク先には触れません。`.gitignore` がリンクのときも同じで、`--force` のときだけ置き換えます。生成先の親ディレクトリの実体が出力先の外にあれば、何も書かずにエラー（終了コード 1）で止めます。`--output-dir` そのものがリンクの場合は、利用者が明示した場所なのでたどります。出力先を同時に書き換える相手がいる場合の競合（検査と書き込みのあいだに、生成先や親ディレクトリを外へのリンクへ差し替えられる）は防げません（生成先を自分で管理していれば起きません）。
- 何が書かれるかを先に確かめたい場合は `--dry-run` を使います。

#### `--upgrade` の振り分け

`--upgrade` はファイルごとに、現物・記録したハッシュ（ORIGIN の `hash:`）・新しい版の生成結果を比べて次の 8 通りに振り分けます。対象は DCB 自身のテンプレートと、規範経由で置くファイル（規範本体・入口ファイル・`.ai-playbook/VERSION`・第二意見のスクリプトなど）の両方です。

| 状態 | 動作 | 出力 |
|---|---|---|
| 手を入れていない（現物 = 記録したハッシュ） | 新しい版で更新する | `write: <path> (upgraded)` |
| 記録が無い（`hash:` が無い）が、`--baseline-from <dir>` の同じ相対パスが通常ファイルで、現物と一致する | 記録 = 現物として扱い、手を入れていないものとして新しい版で更新する（`hash:` の記録があるファイルには使わない） | `write: <path> (upgraded, baseline match)` |
| 手を入れた（現物 ≠ 記録）が、雛形は変わっていない（新しい版 = 記録）。取り込み待ち（`pending:` や残っている `.dcb-new`）が無い | 取り込むべき差分が無いので、現物を温存して報告するだけ。`.dcb-new` は置かない。表示は現物の由来で分ける: 取り込み済み（現物 = `accepted:`）、プロジェクト所有（`owned:`）、それ以外 | `accepted (template unchanged)` / `owned (template unchanged)` / `modified (template unchanged)` |
| 手を入れた（現物 ≠ 記録）うえで、雛形が変わった、または取り込み待ち（`pending:` や残っている `.dcb-new`）がある、または記録が無く新しい版と違う | 上書きせず `<path>.dcb-new` を隣へ置き（取り込む前に失った分も同じ版の `--upgrade` で置き直す）、差分の要約を出す。`.dcb-new` のモードは元のファイルに揃える。ORIGIN へ `pending:` を記録する | `keep (modified)` / `keep (no record)` |
| 新しい版で増えた（現物が無い） | 生成する | `write: <path> (new)` |
| 現物が無く、ORIGIN に `absent:` の記録がある（外せない一覧のパスを除く） | 生成しない。`absent:` の記録と `hash:` の値を引き継ぐ（`--no-absent` で記録を外すと、次の `--upgrade` で上の行になる） | `absent (recorded as intentionally absent)` |
| 手を入れたが新しい版と同じ内容 | 更新済みとして扱い、古い `.dcb-new` があれば消す | `up-to-date` |
| 新しい版で生成されなくなった | **報告するだけで削除しない**。記録からは外す | `no longer generated (not deleted)` |

- **`keep` で始まる行は、取り込み待ち（`.dcb-new` を置いた）か、手を入れたため残したファイル**です。`(template unchanged)` が付く行は雛形が変わっていないので `.dcb-new` を置いておらず、取り込む差分はありません。
- 現物がシンボリックリンクなら、たどらず手を入れた扱いにして `.dcb-new` を置きます。親ディレクトリが出力先の外を指すリンクなら、何も書かずに止めます（終了コード 1）。
- 手を入れたファイルにも、ORIGIN には**新しい版のハッシュ**を記録します。次回の `--upgrade` で、その `.dcb-new` を取り込まないまま現物が新しい版と同じになれば、更新済みとして扱います。
- ORIGIN の `accepted:` 行（下記 `--accept`）は、`--upgrade` が引き継ぎます。ただし、その回に `.dcb-new` を置いた（雛形が変わった）ファイル、または新しい版で更新したファイルの分は落とします。雛形が変わったあとの現物は、取り込み済みの記録と照らす前提が変わっているためです（`doctor.sh` は FAIL を出します）。
- ORIGIN の `owned:` 行（プロジェクトが所有・編集するファイルの印）は、`--upgrade` が今回の生成対象から作り直します。`pending:` 行（`.dcb-new` の取り込み待ちの印）は、その回に `.dcb-new` を置いた（置き直した）ファイルだけに書きます。現物が新しい版と同じになった（`up-to-date` / `upgraded`）ファイルや、`--without-*` で生成対象から外れたファイルの分は残りません。`owned:` / `pending:` の無い既存の ORIGIN も読めます。次の `--upgrade` で `owned:` が書き足され、既に `.dcb-new` が残っているファイルには `pending:` が書き足されます。
- `pending:` が無いのに `.dcb-new` が残っているファイル（`pending:` を導入する前の版が置いたもの）は、雛形が変わっていなければ `.dcb-new` を置き直さず、`keep (modified, .dcb-new left)` と報告して `pending:` を書き足します。
- この版へ上げる前に、取り込まずに `.dcb-new` を失っていたファイルは、`pending:` が無いので作り直されません。
- 手を入れたファイルは**自動では混ぜません**（3 方向マージはしません）。`.dcb-new` と現物を見比べ、必要な差分を手で混ぜてから `.dcb-new` を消してください。`.dcb-new` の残りは `doctor.sh` が WARN で報告します（[Doctor 自己診断](#doctor-自己診断)）。

終了コード:

| 終了コード | 意味 |
|---|---|
| `0` | 全件を適用できた（`.dcb-new` が残っていない） |
| `2` | `.dcb-new` が残った（今回置いたもの、または以前から残っているもの）。残りの一覧を標準エラーへ出す |
| `1` | 失敗（入力の記録が無く引数の明示が要る、規範の取得元を再現できない、親ディレクトリが出力先の外を指す、`--force` との同時指定 など） |

失敗の検出のタイミング: 引数・記録の不足、規範の取得元を再現できない場合、`--force` との同時指定、生成先の親ディレクトリが出力先の外を指すシンボリックリンクであることは、**書き込みの前に**（今回書く予定のすべての生成先を検査して）検出して止まります。1 つでも外を指していれば、何も書かず終了コード 1 です（`--dry-run` も同じ）。止まったら、リンクを直してから `--upgrade` を再実行してください。

`--upgrade --dry-run` は振り分けの計画（`plan: ...`）だけを出し、**生成先には何も書きません**（出力先がまだ無ければ作りません）。規範を URL から取得する場合だけ、取得のために一時ディレクトリを使います。

`--upgrade` は `--force` と同時に指定できません（エラーで止まり、何も書きません）。出力先の既定は現在のディレクトリです（生成先の中で実行する想定）。

#### `--accept`: 手を入れたファイルを取り込み済みとして記録する

パッケージの指示どおりに手を入れ、`.dcb-new` の差分の取り込みを済ませたファイルは、ORIGIN の `hash:`（雛形のハッシュ）とは一致しないままです。`doctor.sh` はこれを「生成時から変化しています」と報告し続けます。`--accept` は、その現物のハッシュを `accepted:<path>=<sha256>` として ORIGIN へ記録し、取り込み済みの印を残します。ORIGIN を書くのは `bootstrap.sh` だけ、という分担を保つため、`doctor.sh` には書き込みを持たせていません。

```bash
bash bootstrap.sh --accept .devcontainer/devcontainer.json scripts/verify.sh
bash bootstrap.sh --accept scripts/verify.sh --output-dir <生成先> --dry-run   # 予定だけを出す
```

- 受け付けるのは、ORIGIN に `hash:` の記録があり、現物が通常ファイルで、`<path>.dcb-new` が残っていないパスだけです。**1 つでも満たさなければ、何も書かずに終了コード 1 で止まります**（有効なパスだけを先に書くことはしません）。
- `version=` と `hash:` は書き換えません。`hash:` は、`--upgrade` が「雛形が変わったか」を判定する基準として残します。
- 現物が `hash:` と一致するパスは、`accepted:` を外して「変更なし」（`unchanged:`）と報告します。同じパスを再度渡すと、行を差し替えます（行は 1 行のまま）。
- 生成の引数（`--project-name` / `--languages` / `--with-*` / `--without-*` / `--base-image` / `--force` / `--no-gitignore` / `--gitignore-targets` / 規範の取得元など）や `--upgrade` と一緒に渡すと、何も書かずに止まります。`--output-dir` と `--dry-run` は併用できます（`--dry-run` は `plan:` 行だけを出し、ORIGIN を変えません）。パスは出力先からの相対パスで指定します。
- 取り込み済みの記録は、**その内容の現物だけ**を許します。記録したあとでさらに手を入れると、`doctor.sh` は再び FAIL を出します（本当の乖離は引き続き検知します）。
- `--accept` は `pending:`（取り込み待ちの印）も外します。`.dcb-new` が残っているパスは受け付けないので、先に差分を取り込んで `.dcb-new` を消してから渡します。
- 雛形が変わっていない版への `--upgrade` では、手を入れたファイルに `.dcb-new` を置きません。取り込み済みにしたファイル（現物 = `accepted:`）は `accepted:` も引き継ぎます。したがって、取り込みを済ませて `--accept` したファイルは、`--upgrade` を繰り返しても `doctor.sh --strict` が 0 で終わる状態を保てます。
- 取り込み待ち（`pending:`）のファイルだけは、`.dcb-new` を取り込む前に失っても、同じ版で `--upgrade` をやり直せば作り直されます。
- **プロジェクトが所有・編集するファイル**（`scripts/acceptance.sh` と `scripts/acceptance-remote.sh`）には、ORIGIN に `owned:` が記録されます。これらは日常的に編集するものなので、`--accept` しなくても、取り込み待ちが無い限り `doctor.sh` は FAIL にしません（編集した件数は `[OK]` で報告します）。`.dcb-new` を置いた（`pending:` がある）あいだは FAIL で、取り込んで `--accept` すると戻ります。一覧は `bootstrap.sh` の `project_owned_rel_paths` が持ち、`tests/test-owned-list.sh` がこの README の記述との一致を機械照合します。

#### `--absent`: 生成物を意図して置かないと記録する

プロジェクトが、ある生成物を意図して置かない場合（たとえば compose をプロジェクト独自のファイル名にしている生成先の `.devcontainer/compose.yaml`）、そのファイルを消すだけでは、`--upgrade` が「新しい版で増えた」として作り直し、`doctor.sh --strict` は「記録にあるのに無い」で FAIL にします。別名で置くなら改名して `--accept` する手もありますが、改名できない生成先のために、`--absent` は「このファイルは意図して置かない」を ORIGIN の `absent:<path>=1` として記録します。

```bash
rm .devcontainer/compose.yaml   # devcontainer.json がプロジェクト独自の compose を指し、--accept 済みであることが前提
bash bootstrap.sh --absent .devcontainer/compose.yaml
bash bootstrap.sh --no-absent .devcontainer/compose.yaml   # 記録を外す（次の --upgrade で生成される）
```

- **次のどれかに当てはまるパスがあると、何も書かずに終了コード 1 で止まります**（`--accept` と同じく、全件を検査してから書きます）。(1) ORIGIN に `hash:` の記録が無い（今回の構成の生成物ではない。生成物かどうかは、記録済みの `hash:` で判定します）。(2) 下の外せない一覧に入っている。(3) 現物がまだある（先に消してから記録します。記録と現物を食い違わせないためです）。
- **上の例は、`devcontainer.json` の `dockerComposeFile` がプロジェクト独自の compose ファイルを指していて、その手直しを `--accept` 済みであることが前提です。** `dockerComposeFile` が `compose.yaml` を指したまま消すのは、`absent:` の記録があっても本当の壊れなので、`doctor.sh` は `dockerComposeFile missing` 相当で `[FAIL]` にします（参照の検査は `absent:` を見ません）。
- `--no-absent` は、`absent:` の記録が無いパスを渡すと止まります（書き間違いに気づくためです）。
- `--absent` / `--no-absent` は、`--accept` と同じ流儀で、生成の引数・`--upgrade`・`--accept`・互いのいずれとも同時に指定できません。`--output-dir` と `--dry-run` は併用できます。
- `--absent` は同じパスの `accepted:` / `pending:` も外します。`hash:` は書き換えず、記録した値のまま残します。`<path>.dcb-new` が残っていても止まりませんが、`--upgrade` の取り込み待ちの報告に残り続けるので、不要なら消します。
- **`--force` の生成し直しは `absent:` を引き継ぎません。** `absent:` のファイルも作り直され、ORIGIN が書き直されたときは `absent:` は残りません（規範の既存ファイルを温存して ORIGIN を書き直さない構成では `absent:` が残り、現物があるので `doctor.sh` が `--no-absent` を案内して `[FAIL]` にします）。置かない状態を保ちたいときは、`--force` ではなく `--upgrade` を使います。
- `--upgrade` は、`absent:` があって現物が無いファイルを作らず、`absent:` を引き継ぎます。新しい版で生成されなくなったファイルの `absent:` は外れます。対応する `hash:` が無い `absent:`（生成物でないパスの記録）は、警告を出して引き継がずに捨てます。`absent:` があるのに現物があれば、記録は食い違いなので引き継がず、通常どおり扱います。
- `doctor.sh` は、`absent:` があって現物が無いファイルを FAIL にせず、件数を `[OK]` で報告します。`absent:` があるのに現物があれば `[FAIL]`（`--no-absent` を案内）、外せない一覧のパスに `absent:` があれば ORIGIN の破損として `[FAIL]` です。`absent:` の無い ORIGIN の結果は変わりません。
- **外せない一覧**は、ゲート・検証・承認の機構を担うファイルです。`verify.yml` を消せないのと同じ理由で、外す入口を持ちません。一覧は `bootstrap.sh` の `absent_forbidden_rel_paths` が持ち、`doctor.sh` も同じ一覧を持ちます。`tests/test-absent.sh` がこの表との一致を機械照合します。

| パス | 外せない一覧の理由 |
|---|---|
| `.github/workflows/verify.yml` | 外せない一覧: `verify.sh` を CI で必ず回すための入口 |
| `.github/workflows/identity-guard.yml` | 外せない一覧: コミット identity の検証を CI で必ず回すための入口 |
| `scripts/verify.sh` | 外せない一覧: 受け入れ検証の単一入口 |
| `scripts/acceptance.sh` | 外せない一覧: 受け入れ条件の実体（無いと `verify.sh` が未定義で落ちる） |
| `scripts/loop-gate.sh` | 外せない一覧: push 前のローカルゲートの単一入口 |
| `scripts/verify-commit-identity.sh` | 外せない一覧: コミット identity の判定そのもの |
| `scripts/verify-commit-identity-selftest.sh` | 外せない一覧: 上の判定の自己試験 |
| `scripts/confirm-merge-hook.sh` | 外せない一覧: マージ直前の承認を機構で保証するフック |
| `.claude/settings.json` | 外せない一覧: `confirm-merge-hook.sh` を PreToolUse フックとして配線する設定（`--with-claude` の構成にだけある） |
| `.github/workflows/second-opinion-gate.yml` | 外せない一覧: 第二意見の記録を確認するワークフロー（規範を置く構成にだけある） |
| `.devcontainer/devcontainer.json` | 外せない一覧: 開発コンテナの定義そのもの |

`--upgrade` の注意:

- **`--second-opinion-engine` の記録は引き継がれます。** 規則（止まる条件、引き継ぎ、使えなくなったときに警告して記録を外すこと）は、上のオプション一覧の項が正本です。これにより `.env.example` を手で直して `--accept` する回避を、`--upgrade` のたびに繰り返す必要がなくなります。既存の `.env` は書き換えません。
- **`--claude-remote-control` の記録は引き継がれます。** 規則は、上のオプション一覧の項が正本です。
- **`--no-update-check` の記録（`input:update-check=off`）は引き継がれます。** 規則は、上のオプション一覧の項が正本です。
- **`--with-*` は足せます。外すには `--without-<名前>` を使います。** 引数で渡した `--with-*` は記録した集合へ足されます。`--upgrade --without-<名前>` は記録した集合から外し、ORIGIN の `flags=` からも消えます。生成し直す必要はありません。同じ名前の `--with-` と `--without-` を同時に渡すとエラーで止まります。
- **外すときは、外したフラグでだけ生成していたファイルを、手を入れていないものに限って削除します。** ORIGIN に記録したハッシュと現物が一致するものを削除し（`remove: <path> (flag removed, unmodified)`）、手を入れたものは残して `keep (modified, no longer generated): <path>` と報告します。`--dry-run` では `plan: remove <path>` と出すだけで、何も消しません。ORIGIN は外した結果で書き直すため、残したファイルは記録から外れ、次の `--upgrade` の対象にも出ません（不要なら手で消してください）。外していないフラグで生成されるファイルは対象外です。`--upgrade` 以外で `--without-<名前>` を渡した場合は、新規生成なら付けないのと同じで、既存のファイルは削除しません。
- **リモート最終ゲート（`--without-copilot-review`）を外すときは、生成物以外の作業が残ります。** DCB は次を変えません。(1) `.github/project-ai-rules.md` の「リモート最終ゲート」の記述を、置かない構成に合わせて直す。(2) リポジトリの required check（ブランチ保護・ruleset）に `review-gate` を入れていれば外す（ワークフローが無くなると、その check は永久に待ち状態になりマージが止まります）。(3) GitHub 側の Copilot の自動レビュー（ruleset の「Automatically request Copilot code review」など）の設定を止める。
- **ほかの理由で生成されなくなったファイルは報告するだけで、削除しません。** 不要なら手で消してください（`--without-<名前>` で外したフラグのファイルだけが例外です）。
- **規範の取得元が `local` の場合は、`--playbook-from` の明示が要ります。** ローカルのパスは記録しないため再現できません（`@` `?` `#` を含む URL も同じです。取得元の種類が `tag` / `adjacent` なら引数なしで再現します）。
- **記録に入力が無い古い ORIGIN、または ORIGIN が無い出力先では、引数を明示しないと止まります。** `--project-name` / `--languages`（必須）と、使っていた `--with-*` や規範の取得元を明示した初回の `--upgrade` で、記録が書き直されます。
- **ORIGIN が無い出力先（記録が無いファイル）では、手を入れていない DCB のテンプレートと規範ファイルも、新しい版と違えばすべて `keep (no record)` になり、`.dcb-new` が置かれます。** 由来の分からない現物を上書きしない設計のためです。移行の手順は次のとおりです。
  1. 生成に使った旧い版の `bootstrap.sh` を、同じ引数（規範も同じ版。版は `.ai-playbook/VERSION` で分かります）で、出力先の外の空の一時ディレクトリ（例: `mktemp -d`）へ生成します。
  2. 出力先で `bootstrap.sh --upgrade --baseline-from <そのディレクトリ>` を、入力を明示して実行します。一致したファイルは `write: <path> (upgraded, baseline match)` で更新され、`.dcb-new` は置かれません。
  3. 一致しなかったファイル（`keep (no record)`）は、現物と `.dcb-new` の差分を取り込んで `.dcb-new` を消し、`bootstrap.sh --accept <path>` します。最後に `doctor.sh` で確かめます。
  - 旧い版が分からないときの手作業の手順: `--upgrade` のあと、現物と `.dcb-new` の差分を 1 件ずつ見て判断し、取り込んで `.dcb-new` を消し `--accept` します。
- 追従先は、実行した `bootstrap.sh` の版です。ネットワークへ最新版を問い合わせません。

### AI 共通ルールの配置

共通ルールと入口ファイルを生成先へ配置します。**既定では配置しません**（オプトイン）。次のいずれかで配置を有効化します。

- `--playbook-version <tag>` または `--playbook-from <path|url>` で**ソースを指定する**（指定した時点で配置意図が明確なため、`--with-playbook` は不要）
- `--with-playbook`（ソースを指定せず、**隣接する ai-playbook チェックアウト**から入れたい場合の明示スイッチ）

`--without-playbook` を指定すると、ソース指定があっても配置しません（明示オプトアウトが最優先）。

配置されるもの:

| 配置先 | 内容 |
|---|---|
| `.ai-playbook/**` | 共通規範、ロール契約、タスクプレイブック、レビュー運用、intake 規律 |
| `.ai-playbook/VERSION` | 規範の**取得元**（`version=` / `source=`）を on-disk に残す記録。どの取得元から取り込んだかを生成後の環境から照合できる。生成の入力と現物のハッシュは `.devcontainer/ORIGIN` が記録する（下記「生成物の由来の記録」） |
| `.github/project-ai-rules.md` | プロジェクト共通ルールの雛形 |
| `CLAUDE.md` / `AGENTS.md` / `.github/copilot-instructions.md` | 実行環境の入口ファイル（3 層の優先順位を配線）。`CLAUDE.md` だけは、末尾に規範 2 つ（`.ai-playbook/shared-ai-rules.md` / `.github/project-ai-rules.md`）を `@` で取り込む節を足す。Claude Code は、これで規範の全文を毎セッションの文脈へ載せる（生成物で約 53KB） |
| `scripts/second-opinion-review.sh` | 第二意見レビューの実行体。`scripts/loop-gate.sh` が存在すれば自動で直列化する。既定は `gemini` CLI（Antigravity CLI への切り替えにも対応するが、`agy` の導入はこの生成器の対象外）。エンジンの指定（引数または `SECOND_OPINION_ENGINE`）が無いまま既定の gemini で回り、`agy` か `codex` が PATH にあるときは、stderr に `[second-opinion] notice:` で知らせる（判定は変えない。gemini だけの構成では出さない） |
| `.claude/skills/intake/SKILL.md` | Claude Code 向け intake 起点スキル（`--with-claude` 指定時のみ）。規範を複製せず `.ai-playbook/intake/` を参照するだけの薄いスキル |
| `.claude/skills/peers/SKILL.md` | Claude Code 向けの、ほかのセッションの一覧・宛先の解決・送信・一斉送信の呼び出し口（`--with-claude` 指定時のみ）。実体は `scripts/session-peers.sh`。一斉送信も承認の根拠にならない（`.ai-playbook/shared-ai-rules.md` 16 章） |
| `.claude/skills/land/SKILL.md` | Claude Code 向け PR 確認・マージ起点スキル（`--with-claude` 指定時のみ）。判定基準を複製せず `.ai-playbook/review-workflow.md` と `.ai-playbook/task-playbooks/pr-review.md` を参照する。マージ直前の確認そのものは `scripts/confirm-merge-hook.sh`（下記）が機構として保証する |
| `.claude/agents/explorer.md` / `.claude/agents/implementer.md` | Claude Code 向け委譲先エージェント定義（`--with-claude` 指定時のみ）。`model` と `tools` を frontmatter で固定する。判定の導線は規範側（`shared-ai-rules.md` の「実装委譲パターン」）が持ち、ここでは再定義しない |

取得元は次の順で解決します。

1. `--playbook-version <tag>`（既定ソース `ojos/ai-playbook` のタグ tarball へ展開）
2. `--playbook-from` に指定したディレクトリまたはアーカイブ URL
3. 隣接する ai-playbook チェックアウト（`bootstrap.sh` から見て `../../.ai-playbook` または `../../../.ai-playbook`）

`curl` で `bootstrap.sh` を単体取得して実行する場合は隣接チェックアウトが存在しないため、`--playbook-version` または `--playbook-from` の指定が必要です。
取得元が解決できない場合は、**ファイルを 1 つも書き込まずに終了します**。

### AI CLI 導入挙動

`scripts/install-ai-tools.sh` は常に生成され、`postCreateCommand` で実行されます。生成される `postCreateCommand` の実値は次のとおりで、永続 volume の所有者を戻してから AI CLI を導入します。

```
bash scripts/fix-mount-owner.sh && bash scripts/install-ai-tools.sh
```

導入するのは `--with-claude` / `--with-gemini` / `--with-antigravity` / `--with-codex` / `--with-copilot` で**明示選択した AI CLI のみ**です。トークン有無での自動導入は行いません（明示 opt-in）。何も選択しなければ AI CLI は導入されません。

`--with-antigravity` だけは npm 配布ではないため、配布元のインストーラを取得して `~/.local/bin/agy` へ置きます。あわせて**テレメトリを無効化**します（下記）。

`--with-codex` は npm 配布（`@openai/codex`）ですが、**版の下限を検査します**。第二意見レビューの既定モデルを引ける版より古い CLI が既に入っている場合は、「在るから飛ばす」ではなく入れ替えます。認証は ChatGPT アカウントの OAuth または API キーで、導入だけでは使えません。初回は対話で `codex login` を通してください。

## ループコーディング支援

AI エージェントの反復（実装 → 検証 → 修正 → …）を、**機械が緑判定できる決定的な信号**の上で収束させるための実行体を生成します。装備の選択によらず常に生成し、**外部パッケージの導入を前提にせず単体で動作**します。

> この節は DCB 環境での**操作手順**（各スクリプトをどう回すか）を扱います。ループコーディングという**ワークフロー自体の考え方**（従来との違い・収束規律・受け入れ検証の機械ゲート化）は、規範パッケージ ai-playbook の解説ガイド `loop-coding-guide.md`（規範の正本は `loop-workflow.md`）を参照してください。規範を配置する（`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれか）と、これらの規範も生成先へ配置されます。

| スクリプト | 役割 |
|---|---|
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（プロジェクトが所有・編集）。選択言語のうち、ルート直下にマニフェストが存在する対象だけを慣習的テストで検証する |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS` / 終了コード 0）を返す接地信号。手前で `check-no-secrets.sh` を実行する |
| `scripts/check-no-secrets.sh` | 機密混入の検知ゲート（`SECRETS_PASS` / 終了コード 0）。判定の正本で、`verify.sh` と CI が共用する。下記「[機密混入検査](#機密混入検査)」参照 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。commit identity の検証・`verify.sh`・任意の第二意見レビューを直列で通す単一入口（`GATE_PASS` / 終了コード 0） |
| `scripts/acceptance-remote.sh` | **外部層**の受け入れ条件（プロジェクトが所有・編集）。`--with-aws` / `--with-gcp` を選んだときだけ配置する骨格のみの雛形。下記「受け入れ条件の二層」参照 |

- `acceptance.sh` は生成時、選択言語ごとに**ルート直下のマニフェストの実在を確認してから**慣習的コマンド（`node`/`package.json`→`npm test`、`go`/`go.mod`→`go test ./...`、`python`/`pyproject.toml`・`requirements.txt`→`python -m pytest`、`php`/`composer.json`→`composer test`、`rust`/`Cargo.toml`→`cargo test`、`ruby`/`Gemfile`→`bundle exec rake`）を実行します。マニフェストが無い言語は理由を出して**スキップ**し（失敗させない）、マニフェストはあるがツールが無い場合は導入手順を添えて**失敗**させます（スキップと混同しない）。1 つも検証を実行できなければ「受け入れ条件が未定義」として**非 0 で終了**します（全スキップで誤って緑になる事故を防ぐ）。スクリプト位置からルートを解決するため、起動時の作業ディレクトリに依存しません。プロジェクトの実態に合わせて編集してください。受け入れ条件が検証可能であるほど、反復が収束しやすくなります。
  - **雛形は、言語ごとの検証の後ろ（「検証を 1 つでも実行したか」の判定の手前）で、配布した衛生検査 4 本（`check-control-chars.sh` / `check-table-breaks.sh` / `check-doc-links.sh` / `check-shell-portability.sh`）を呼びます。** この 4 本は「検証を 1 つでも実行したか」に**数えません**（マニフェストの無い構成が、検査だけで合格にならないようにするため。4 本が通っても、マニフェストが無ければ「受け入れ条件が未定義」で失敗します）。
  - **既存の出力先には、雛形の変更は届き方が違います。** `acceptance.sh` はプロジェクトが所有するため、手を入れていなければ `--upgrade` で新しい版（4 本を呼ぶ版）に置き換わり、4 本が動き始めます（既存のコードで赤になりうる）。手を入れていれば `.dcb-new` が置かれ、`pending:` が付くので、取り込むまで `doctor.sh` は FAIL です。どちらの場合も、`acceptance.sh` が 4 本のファイル名を参照していなければ、`--upgrade` の終わりに配線を促す案内が出ます（終了コードは変わりません）。
  - **意図して呼ばない検査は、`acceptance.sh` にファイル名と理由をコメントで書いてください。** ファイル名が現れていれば、未配線とは見なしません（`doctor.sh` の WARN も `--upgrade` の案内も出ません）。
  - monorepo など、各言語がルート直下ではなくサブディレクトリ（例 `apps/*`）に配置される構成では、生成直後は対象が見つからず「未定義」で失敗します。これは**意図した既定**であり、実配置のマニフェストを見るよう `acceptance.sh` を編集して受け入れ条件を確定させてください。
- `verify.sh` の受け入れ定義は `VERIFY_ACCEPTANCE` 環境変数で差し替えできます（既定は `scripts/acceptance.sh`）。層を増やすときも同じランナーを使い、受け入れ定義だけを差し替えます（下記「受け入れ条件の二層」）。
- `verify.sh` は受け入れ条件の**手前**で `scripts/check-no-secrets.sh` を実行します。`acceptance.sh` 側へ置かないのは、あちらがプロジェクトの所有物で受け入れ条件を書き足すたびに触られ、規範由来の検査が消える経路ができるためです。`check-no-secrets.sh` が不在なら `VERIFY_FAIL` で止まります（検査が成立していないことを合格にしないため）。**この検査は git を前提にします**（下記「[機密混入検査](#機密混入検査)」参照）。
- `loop-gate.sh` は push / PR 前に **3 段を直列**で通します。**1. commit identity の検証**（`scripts/verify-commit-identity.sh`）→ **2. verify**（受け入れ検証。手前で機密混入検査を含む）→ **3. 任意の第二意見レビュー**の順です。identity を最初に置くのは、判定が最も安く（実測数 ms）、許可外の identity が混じったコミットを他の段の結果を待たずに検知するためです（許可外 identity の検知が CI＝push 後まで遅れていた穴を塞ぐ。詳細は下記「Git identity ガード」参照）。判定ロジックは `loop-gate.sh` へ書き写さず `verify-commit-identity.sh` 側に置きます（判定を二重管理しない）。
  - **移行時の注意:** `verify-commit-identity.sh` は fail-closed です。環境変数 `ALLOWED_AUTHOR_EMAILS` も `.env` の `GIT_IDENTITY_EMAIL` も設定していないプロジェクトでは、`loop-gate.sh` を再生成した時点で**ローカルゲートが緑から赤に変わります**。これは検査が成立しない状態を合格にしない、意図した挙動です。`bash scripts/setup-git-identity.sh` で `.env` の `GIT_IDENTITY_EMAIL` を適用するか、`ALLOWED_AUTHOR_EMAILS` を設定してください（下記「[利用側の設定手順（許可 author email）](#利用側の設定手順許可-author-email)」参照）。
- `loop-gate.sh` の第二意見は、`scripts/second-opinion-review.sh` が存在すれば直列化し、無ければ優雅にスキップします。`LOOP_GATE_REVIEW_CMD` で任意のレビューコマンドへ差し替え、空文字で無効化できます。
- 差し替えたコマンド（`LOOP_GATE_REVIEW_CMD`）へは、解決した範囲を環境変数 `LOOP_GATE_REVIEW_RANGE` で渡します（ステージ済み差分があるとき・対象が無いときは空）。範囲を受けない差し替えコマンドは、commit 済みのブランチで空のステージ済み差分を見て「対象なし」で終わるため、`loop-gate.sh` は、レビュー対象が実在するのにその出力（`[second-opinion] no diff to review`）を見たときは `GATE_FAIL` にし、記録も残しません。レビュー対象が本当に無いと解決したときは、差し替えたコマンドを実行せず、記録なしで通過します。**限界として、loop-gate が「レビューしていない」と判定できるのは、差し替えたコマンドが `[second-opinion] no diff to review` を出力したときだけです。** 範囲を使わず、この文言も出さない任意のコマンド（例: `true`）は、何もレビューしていなくても `GATE_PASS` と記録が出ます。差し替えるコマンドは、範囲を `LOOP_GATE_REVIEW_RANGE` で受け取るか、自分で範囲を決めて自分で記録を残してください。同梱の reviewer のエンジンだけを変えるなら `LOOP_GATE_REVIEW_CMD='bash scripts/second-opinion-review.sh --engine <名前> ${LOOP_GATE_REVIEW_RANGE:+--range "$LOOP_GATE_REVIEW_RANGE"}'` と書きます。`SECOND_OPINION_ENGINE` の前置は、`.env` が環境変数を上書きするため使えません。
- 第二意見へ渡す**差分の範囲**は、既定の対象を **PR 全体**にして決めます。第二意見のエンジンは差分をプロンプトへ埋め込み、差分の外を読まない形を基本にします。修正を重ねた後の小さな差分（ステージ済みだけ、上流からだけ）を渡すと、差分に現れない既存のコードについて誤った前提を立てて落ちるためです。起点は**既定ブランチとの分岐点（merge-base）**にします。既定ブランチは `origin/HEAD` → `origin/main` → `origin/master` の順で解決します。
  - **ステージ済み差分があるとき**: `--base <起点>` を渡し、起点から索引までを対象にします（コミット済みの分とステージ済みの分の両方が入ります）。記録の scope は `base:<起点>+staged` です。
  - **ステージ済み差分が空のとき**: `--range <起点>..HEAD` を渡します。上流があっても、上流からではなく起点からです。記録の scope は `range:<起点>..HEAD` です。
  - 分岐点を起点にするのは、`<既定ブランチ>..HEAD` のような 2 点間の比較が、既定ブランチ側に進んだコミットを「打ち消し」として差分へ混ぜるためです。既定ブランチを取り込んでいれば（merge / fast-forward / rebase）分岐点が取り込み地点まで進むので、取り込んだ他ブランチの成果は範囲から外れます。なお squash / cherry-pick での取り込みは履歴上の繋がりを残さないため、どの起点を選んでも差分から外れません（範囲の選び方だけでは解けない制約です）。
  - 起点と HEAD に差分が無いときは、`no reviewable diff` を出力したうえで `GATE_PASS` とします（空ツリーまで広げて、リポジトリ全体を対象にはしません）。
  - **起点をどう決めたかは 1 行出力します**（黙って範囲を変えると、なぜその差分が対象なのかを読み手が追えないため）。
  - **既定ブランチの追跡枝を解決できない環境でだけ、従来の決め方に戻ります。** ステージ済みがあれば範囲を渡さず（レビュー実行体の既定のステージ済み差分に委ねます）、空なら上流と HEAD の分岐点から HEAD まで、上流も無い、または上流との差分が空（push 済み）なら空ツリーからの全体です（対象なしとして通すと、第二意見が一度も差分を見ない偽の緑になるため）。
  - **入力が大きくなり、トークンの消費が増えます。** 大きな PR では、モデルの文脈の上限に近づきます（上限を超えたときの分割は、実行体が持つ入力の分割に従います）。
  - **起点は手元の追跡枝から決めます。`loop-gate.sh` は fetch しません。** 追跡枝が古ければ、古い起点になります（例: 新しい既定ブランチを取り込んでも、手元の追跡枝がそこまで進んでいなければ、取り込んだ他ブランチの成果が範囲に残ります）。今の起点の決め方と同じ性質です。気になるときは、先に `git fetch` します。
  - `second-opinion-review.sh` 自体は、`--base <rev>`（索引と `<rev>` の差）、`--range <A>..<B>`、何も渡さない（ステージ済み差分）の 3 通りを受けます。`--base` と `--range` は併用できません。
- `loop-gate.sh` は source ガードを持ち、`source`（`.`）で読み込んだだけではゲート本体を実行せず、範囲解決の関数だけを提供します。範囲の決め方を単体で検証できるようにするためで、ルートへの `cd` もゲート本体側に置いてあり、読み込んだ側の作業ディレクトリを動かしません。
- これらは純粋な機構であり、規範（受け入れ検証の機械ゲート化・収束規則・verify ランナー契約）は ai-playbook の `loop-workflow.md` が正本です。規範を配置した場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、第二意見の `second-opinion-review.sh` も配置され、`loop-gate.sh` が自動で直列化します。
- 上の 3 本は**手元から起動する入口**で、実行するかどうかは人に委ねられています。**回し忘れれば何も起きません。** `verify.sh` は `verify.yml` が CI で再実行して回し忘れを塞ぎますが（下記「受け入れ検証の CI ワークフロー」参照）、**第二意見は手元でしか走らないため、CI が再実行して確かめることができません。** そのため回したことの記録と、記録が無いことを別の契機（PR 更新・手動実行）から検出する確認側を、規範を配置したときにあわせて配置します。定期実行は置きません（PR が無いあいだも走り続け、private リポジトリの Actions の課金枠を減らし続けるため）。`second-opinion-record.sh post` が投稿の直後に確認側を既定ブランチで手動実行し、`/land` がマージの直前に再判定します。
  - `loop-gate.sh` は第二意見の出力を捕まえ、`scripts/second-opinion-record.sh save` へ渡します。レビュー対象が無い（`REVIEW_NO_TARGET`）、または明示的にスキップした（`LOOP_GATE_REVIEW_CMD=''`）場合は記録しません——回していないものを「回した」と記録すると、確認側が偽の緑を出すためです。
  - 記録は `git rev-parse --git-path second-opinion` が返す worktree ごとのパスへ置き、レビューした対象（ステージ済み差分、または起点から索引までの差の場合は索引のツリー、あるいはコミット範囲の終端）を HEAD と突き合わせてから PR へ投稿します（`scripts/second-opinion-record.sh post`）。中身が変わっていれば投稿しません。
  - `.github/workflows/second-opinion-gate.yml` が、投稿された記録の head SHA がいまの head と一致するかを確認します。要求はしません（第二意見を回すかどうかは利用者側の判断のままです）。Dependabot のように回す著者が最初からいない PR は、`scripts/second-opinion-gate-exempt.sh` の判定で対象外にします。
  - これらも第二意見そのものと同じ「外部パッケージの導入を前提にしない」機構です。偽造（記録を作らずレビューを回したことにする）までは防げず、検出できるのは失念だけです。
- `verify.sh` の回し忘れは、CI でも回す `.github/workflows/verify.yml` を**常に**配置して塞ぎます（下記「受け入れ検証の CI ワークフロー」参照）。

```bash
# 反復のたびに接地信号を確認する（ローカル層）
bash scripts/verify.sh

# push / PR 前のローカル事前ゲート（受け入れ検証 + 任意の第二意見）
bash scripts/loop-gate.sh
```

### 受け入れ条件の二層（ローカル層 / 外部層）

受け入れ条件を 1 種類として扱うと、**外部認証やネットワークを要する検査が接地信号へ混ざります。** 認証の失効やオフラインで赤くなり、**実装が正しいのにループが止まります。** そのため 2 層に分けます（規範の正本は ai-playbook の `loop-workflow.md`「受け入れ条件の二層」）。

| 層 | 実行体 | 対象 |
|---|---|---|
| ローカル層 | `scripts/acceptance.sh`（常に配置） | ネットワークも外部認証も要さない検査。**ループの接地信号** |
| 外部層 | `scripts/acceptance-remote.sh`（`--with-aws` / `--with-gcp` のいずれかを選んだ場合のみ配置） | 宣言と実際の外部状態が一致しているかの検査。外部認証とネットワークを要する |

```bash
# ローカル層（既定。scripts/acceptance.sh を実行する）
bash scripts/verify.sh

# 外部層（受け入れ定義を差し替えて起動する）
VERIFY_ACCEPTANCE=scripts/acceptance-remote.sh bash scripts/verify.sh
```

- **`loop-gate.sh` は外部層を実行しません。** 含めると外部認証の失効やオフラインでゲート全体が止まり、実装が正しいのに push できなくなります。単一入口の目的は複数の段を別々に思い出す運用を機構で塞ぐことであって、外部の可用性を push の前提条件にすることではありません。外部層は**外部状態の宣言（IaC 等）を変更したときに別途通します。**
- 外部層の雛形が持つのは骨格だけです（ラベル付きで実行し失敗時だけ出力を見せる `run` ヘルパー、`mktemp` で作る一時ログと `EXIT` トラップ、失敗件数の集計、前提を書く位置）。**具体的な検査は持ちません**（何が外部状態かはプロジェクトごとに違うため）。
- **検査を足すまで、外部層は失敗します。** 1 件も実行していない状態を合格として報告しません（`acceptance.sh` の「受け入れ条件が未定義」と同じ扱いです）。
- 前提として、対象サービスへ**認証済みであること**を要求します。雛形は認証を行いません（資格情報をスクリプトへ書き写す経路を作らないため）。未認証やオフラインでの失敗は、宣言と外部状態の乖離ではありません。
- `--with-aws` / `--with-gcp` を選んでいない構成へは配置しません。外部状態を持たない構成へ空の雛形を配ると、消す作業をさせることになるためです。

### 受け入れ検証の CI ワークフロー

`.github/workflows/verify.yml` は `scripts/verify.sh` を CI で回します。**ローカル事前ゲートを回し忘れた PR は、受け入れ条件を満たさないままレビューへ届きます。** ゲートを整備しても実行を忘れられるなら、守られている外観だけが残るため、実行そのものを機構へ移す層です。装備の選択によらず常に配置します（`verify.sh` / `acceptance.sh` が常に置かれるのに、それを回す側だけが選択制なのは不整合だからです）。

- **判定ロジックはワークフローへ書き写しません。** `bash scripts/verify.sh` を呼ぶだけで、手元と CI が同じコードで判定します（`identity-guard.yml` と同じ方針）。
- **2 系統を張ります。** `pull_request`（`opened` / `synchronize` / `reopened`）でマージ前に落とし、`push`（`main`）で PR を経由しない直接 push とマージ後の統合状態を検査します。並列に進む PR は互いの変更を見ないまま緑になるため、統合して初めて壊れる組み合わせがあり、後者を省略しません。
- **`fetch-depth: 0`** で全履歴・全 ref を取ります。既定（`fetch-depth: 1`）では既定ブランチの追跡枝（`origin/main`）が作られず、`acceptance.sh` へ履歴を見る検査（コミット identity の検証など）を足したときに**範囲が HEAD の全履歴へ落ち、その全履歴が 1 コミットしかない状態で通過します。** 落ちるなら気づけますが、これは偽の緑です（許可外 author を 1 件含む 2 コミットの PR で実測: 深さ 1 では検査対象 1 件・exit 0、全履歴では検査対象 2 件・exit 1）。
- **`ALLOWED_AUTHOR_EMAILS` をリポジトリ変数から渡します。** CI には `.env` が無いため、これが唯一の供給元です（設定手順は「[利用側の設定手順（許可 author email）](#利用側の設定手順許可-author-email)」と同じ）。`acceptance.sh` がこの値を要する検査を持たない構成では、空のまま渡って何も起きません。
- **`permissions: contents: read`** と、`pull_request` のみ取り消す `concurrency` を持ちます。`main` では取り消しません（統合状態を見ているため、続く push で前の実行を消すと「どのコミットから壊れたか」を追えなくなります）。
- **言語ランタイムの用意・ツール（静的解析器など）の導入・依存のインストールは持ちません。** 何が必要かは `acceptance.sh` が何を検査するかに従属し、プロジェクトごとに違います。雛形が中途半端に決め打つと、使わない手順を毎回消す作業をさせることになるため、**足す位置をコメントで示すだけ**にしてあります。

> **fork からの PR はスキップしません。** `verify.sh` は Secrets を必要とせず、`permissions: contents: read` は fork からの PR に既に与えられている権限なので、走らせられない理由がありません。スキップすると、最も検証が要る外部からの変更にだけゲートが掛からなくなります。スキップの根拠は「その権限では実行できない」ことに限ります（`copilot-review.yml` が fork をスキップするのは `pull-requests` の書き込み権限を要するためで、こちらとは理由が異なります）。
>
> ただし **fork からの PR には Secrets もリポジトリ変数も渡りません。** `acceptance.sh` へリポジトリ変数や Secrets に依存する検査を足すと、その検査は fork からの PR でだけ供給元を失い、fail-closed な検査であれば常に赤くなります。恒常的な赤は「赤を無視する習慣」を生むため、足す側で次のどちらかを選んでください。(1) 供給元を要する検査は `acceptance.sh` へ入れず専用のワークフローに置く（許可 author email を要するコミット identity の検査は `identity-guard.yml` が持っています）。(2) fork からの PR を受け付けないリポジトリなら、ワークフロー内にコメントアウトで置いてある `if:` の 1 行を有効にする。

**`scripts/verify.sh` を回す CI を自前で持っている場合**（前提ツールを入れてから `verify.sh` を回す独自のワークフローなど）は、`verify.yml` を消さずに、自前の CI の中身を `verify.yml` へ移して `--accept` します。

- **`verify.yml` を消すと、`doctor.sh --strict` が「記録にあるのに無い」で FAIL になります。`--accept` でも消せません。** 意図した設計です。`verify.sh` が CI で必ず回ることを保証するため、外す入口を持ちません（`--without-*` でも外せません）。`verify.yml` はプロジェクトが所有するファイル（`owned:`）ではないため、手を入れたら `--accept` で取り込み済みにする、という通常の流れに乗せます。
- 手順:
  1. 自前の CI が入れている前提ツール（静的解析器など）の導入を、`verify.yml` の「プロジェクトの前提はここへ足す」の位置へ移します。
  2. 自前のワークフロー（重複して `verify.sh` を回している側）を消します。
  3. `bash bootstrap.sh --accept .github/workflows/verify.yml` で、手を入れた現物を取り込み済みにします。
- **required check の名前が変わる場合**（自前の job 名から `verify.yml` の job 名へ）は、ブランチ保護・ruleset の側も直します。直さないと、存在しない check を待ち続けてマージできなくなります。
- 雛形が変わった版へ `--upgrade` すると、手を入れた `verify.yml` は上書きされず `verify.yml.dcb-new` が隣に置かれます。差分を `verify.yml` へ取り込んでから、`--accept` し直します。

> **この開発リポジトリ自身には `verify.yml` を置きません。** 既に `.github/workflows/ci.yml` が同じ役割を持ち、`scripts/acceptance.sh` がその 6 ジョブ + `identity-guard.yml` を完全ミラーしているため、`verify.yml` を置くと役割が重複し、`tests/test-ci-mirror.sh` のミラー対象が 2 本になります。**雛形を配りながら自分では使わない状態を、無自覚ではなく明示の判断として残します。**

### 配るワークフローの実行先（`ACTIONS_RUNS_ON`）

DCB が配置するワークフロー 5 本（`identity-guard.yml` / `verify.yml` / `second-opinion-gate.yml` / `copilot-review.yml` / `review-gate.yml`）は、実行先を次の形で書きます。

```yaml
runs-on: ${{ vars.ACTIONS_RUNS_ON || 'ubuntu-latest' }}
```

| 項目 | 内容 |
|---|---|
| 変数名 | `ACTIONS_RUNS_ON`（利用側リポジトリの Settings > Secrets and variables > Actions > Variables） |
| 既定値 | 未設定または空文字なら `ubuntu-latest`。設定しなければ従来と同じ挙動です |
| 値 | ラベル 1 つ（例: 自前のランナーに付けたラベル）。複数ラベルの配列は受け付けません。**値に空白を含めないでください** |
| 使いどころ | private リポジトリで、GitHub のランナーが使う Actions の課金枠を避けたいとき。public リポジトリは何もしなくてかまいません |

**空白だけの値や、末尾に空白のある値は、既定値へ落ちず、そのままラベルになります。** `||` が既定値へ落とすのは空文字のときだけだからです。そのラベルを持つランナーは存在しないので、ジョブは `queued` のまま進みません。変数を設定したのにジョブが始まらないときは、まず値の前後の空白を疑ってください。

**5 本すべてを変数の形にするには、この変更を含む ai-playbook と組み合わせてください。** `identity-guard.yml` / `verify.yml` は `bootstrap.sh` が書きますが、残り 3 本は規範の雛形から写します。`--playbook-version` に古い版を指定すると、前者 2 本だけが変数の形になり、後者 3 本は `ubuntu-latest` のまま残ります。版の検査は機構では行いません。

手でワークフローの `runs-on` を書き換えると、`.devcontainer/ORIGIN` の記録とずれて、`--upgrade` が手を入れたファイルとして扱います。変数で切り替えれば、ワークフローには手を入れずに済みます。

> **自前のランナーでは、PR 側のコードがそのマシンで動きます。外部からの PR を受け付けるリポジトリでは、使わないでください。**
>
> 外部からの PR だけの話ではありません。同じリポジトリの PR では、`identity-guard.yml` / `verify.yml` / `review-gate.yml` / `second-opinion-gate.yml` の `pull_request` 契機は、**PR 側の版のワークフロー定義**で動きます。したがって、書き込み権限を持つ共同作業者なら誰でも、PR でワークフローの `run:` を書き換え、自前のランナーのマシンで任意のコードを動かせます（フォークからの PR は `copilot-review.yml` / `review-gate.yml` / `second-opinion-gate.yml` の対象外ですが、`identity-guard.yml` と `verify.yml` は動きます）。
>
> - ランナーは、使い捨てのコンテナで動かしてください（devhost が用意する自前のランナーを使えます）。実行のたびに捨てれば、書き換えられたコードが残す状態を次の実行へ持ち越しません。
> - ホストの資格情報（ホームのトークン、SSH 鍵、Docker ソケットなど）やネットワーク（社内の別のサービス）に届く場所で、ランナーを動かさないでください。

#### 自前のランナーに要る道具

`ubuntu-latest` には最初から入っているが、最小の Linux には無いものです。5 本のワークフローと、そこから呼ばれる `scripts/*.sh`、`actions/checkout` が実際に使うコマンドから洗い出しました。ランナー本体（actions/runner）の導入に要るもの（.NET の実行時依存など）は、ランナーの導入手順の側の話なので含めません。

| 道具 | 使う箇所 |
|---|---|
| bash | 全ワークフローの `run:`、全スクリプト（`#!/usr/bin/env bash`） |
| git | `actions/checkout`（無いと REST 経由の取得に落ち、`.git` が無い木になる）、`scripts/verify-commit-identity.sh`（`git log` / `git rev-parse`）、`scripts/verify-commit-identity-selftest.sh`（`git init` / `git commit`）、`scripts/check-no-secrets.sh`（`git status` / `git ls-files`。`verify.yml` が `verify.sh` 経由で呼ぶ） |
| gh（GitHub CLI） | `copilot-review.yml` / `review-gate.yml` / `second-opinion-gate.yml` の `run:`（`gh api`）。`--jq` は gh に内蔵されているので、jq は要りません |
| GNU coreutils 相当 | `date -u -d`（`review-gate.yml` / `second-opinion-gate.yml` の掃き寄せ。GNU の `-d` を使う）、`base64 -d`（`review-gate.yml` の判定スクリプトのフォールバック取得）、`tr`（`copilot-review.yml` / `review-gate.yml` の `is_copilot`）、`mktemp`・`sort`・`comm`・`cp`・`rm`・`mkdir`・`sleep`・`dirname`・`cat`・`env`（`verify-commit-identity-selftest.sh` / `check-no-secrets.sh` / 各ワークフロー） |
| sed・grep | `verify-commit-identity-selftest.sh`（`sed`）、`check-no-secrets.sh`（`sed` / `grep`） |

- `curl` / `jq` / `python3` / `awk` は、この 5 本と呼ばれるスクリプトからは使いません。要りません。
- Node.js は、`actions/checkout`（JavaScript のアクション）の実行にランナー自身の同梱版が使われるため、別に入れる必要はありません。
- `verify.yml` が呼ぶ `scripts/acceptance.sh` は**プロジェクトが所有する**ので、その検査が使うもの（言語ランタイム・`npm` など。配布版の `acceptance.sh` は `package.json` があると `npm` を使います）は、この一覧に含みません。プロジェクトの実態に合わせて足してください。
- `ubuntu-latest` 相当の GNU 版が入った Linux（Debian / Ubuntu 系）を前提にします。BusyBox の `date` は GNU の `-d` と同じ書式を受け付けない場合があります。

## 言語サポート
対応ランタイム（任意の組み合わせ）:
- `node`（Node.js / JavaScript / TypeScript）
- `go`（Go）
- `python`（Python 3。パッケージ/仮想環境マネージャの [uv](https://github.com/astral-sh/uv) を同梱）
- `php`（PHP）
- `rust`（Rust）
- `ruby`（Ruby）

選択した言語は devcontainer feature（`ghcr.io/devcontainers/features/<lang>:1`）として導入され、`scripts/post-rebuild-check.sh` の検査対象にもなります。`rust` は feature 名（`rust`）と実行コマンド（`cargo`）が異なるため、検査・診断は `cargo` の有無で判定します。`ruby` は feature 名と実行コマンドが一致するため、この写像は不要です。

`python` を選ぶと、uv も併せて導入されます。uv には公式の devcontainer feature が無いため、python feature の `toolsToInstall`（pipx 導入のツール列）へ `uv` を追記する形で同梱します。既定の Lint/テストツール群は維持したまま `uv` を足すため、既存の導入内容は変わりません。`python` を選ばない場合、uv は導入されません。

### VS Code language server 拡張

選択言語に応じて language server 拡張を条件付きで配線します（インフラ系拡張とは別に、選択時のみ追加）。

| 言語 | 配線する拡張 |
|---|---|
| `rust` | `rust-lang.rust-analyzer` |
| `go` | `golang.go` |
| `python` | `ms-python.python` |
| `ruby` | `Shopify.ruby-lsp` |
| `node` | （なし。JS/TS は VS Code 組み込み） |
| `php` | （サードパーティは配線しない。有料ティアのある拡張を既定に含めないため） |

### 使用例:
```bash
# 素の環境（cloud も AI ツールも無し。docker + node のみ）
./bootstrap.sh --project-name myapp --languages node

# 複数言語
./bootstrap.sh --project-name myapp --languages node,go,python,php,rust,ruby

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

生成後、コンテナ内で 1 度だけ認証します（状態は named volume に残り、リビルドを跨ぎます）:

```bash
gh auth login                 # GitHub（gh-storage）
aws sso login                 # --with-aws のとき（aws-storage）
gcloud auth login             # --with-gcp のとき（gcloud-storage）
```

## Feature フラグ

常に導入する feature（既定）:
- `common-utils` / `docker-outside-of-docker`（buildx + compose-switch を標準装備）/ `ripgrep` / `shellcheck` / `tmux` / `github-cli`

`shellcheck` は `--with-*` ではなく常時導入です。生成物が配る `scripts/*` は選択言語や装備フラグに依らず必ずシェルスクリプトであるため、`scripts/acceptance.sh` を編集して受け入れ条件に `shellcheck scripts/*.sh` を加える判断を、各プロジェクトが導入手順から始めずに済むようにしています。配布するスクリプトは素の状態で `shellcheck -S warning` を通ります（`tests/test-generated-shellcheck.sh` が生成物に対して検査しています）。

条件付き feature:
- `node` / `go` / `python` / `php` / `rust` / `ruby`（`--languages` に含む場合。`python` は uv を `toolsToInstall` に同梱）
- `aws-cli`（`--with-aws` の場合）
- `google-cloud-cli`（`--with-gcp` の場合、外部 `dhoeric` feature を利用）
- `terraform`（`--with-aws` または `--with-gcp` の場合、1 回）

## VS Code 拡張（Remote）
- `ms-azuretools.vscode-containers` は常に配線します。
- 言語 language server 拡張は選択言語に応じて配線します（上記「言語サポート」参照）。
- `--with-aws`: `amazonwebservices.aws-toolkit-vscode`。`--with-gcp`: `GoogleCloudTools.cloudcode`。いずれかの cloud 指定で `hashicorp.terraform`。
- `--with-claude`: `anthropic.claude-code`。`--with-gemini`: `Google.gemini-cli-vscode-ide-companion`。`--with-copilot`: `github.copilot` / `github.copilot-chat`。`--with-antigravity` は拡張を追加しません（CLI のみ）。

## ネイティブ Linux の Docker でのワークスペースの所有者
コンテナの利用者は、ベースイメージの `vscode`（UID/GID 1000）です。ネイティブ Linux の Docker Engine は、bind mount の所有者を数値の UID のままコンテナへ通します。そのため、ホストの利用者の UID/GID が 1000 でないと、ワークスペースへ書き込めないように見えます（Docker Desktop for Mac はファイル共有層が所有者を写すので、この問題は起きません）。

**生成物は何もしなくても、この食い違いを吸収します。** Dev Containers（devcontainer CLI。VS Code の Dev Containers 拡張も同じ CLI を使います）は、CLI が Linux の上で動くとき、コンテナを作る時点で `remoteUser` の UID/GID をホストの利用者に合わせたイメージ（名前の末尾が `-uid`）を作ります。これが `devcontainer.json` の `updateRemoteUserUID` で、既定で有効です。**生成物の `dockerComposeFile` 方式でも同じように働きます**（devcontainer CLI 0.89.0 で、UID 1001 の利用者が `devcontainer up` すると、コンテナの `vscode` が `uid=1001 gid=1001` になり、`/home/vscode` の所有者も揃うことを実測）。

- 生成物の `devcontainer.json` は `updateRemoteUserUID` を書きません（既定に任せます）。**`false` にしないでください。** 上の付け替えが止まり、ネイティブ Linux のホストで書き込めなくなります（`tests/test-update-remote-user-uid.sh` が、生成物が無効にしていないことを確かめます）。
- **効かない構成があります。** CLI が macOS や Windows の上で動き、Docker だけが別の Linux にある場合（`DOCKER_HOST` で遠くの Docker Engine を使う場合など）は、CLI が付け替えを行いません。その Linux へ Remote - SSH で入り、そこでコンテナを開いてください。CLI がその Linux の上で動くので、付け替えが働きます。
- 付け替えはコンテナを作るときだけ行われます。ホストの利用者を変えた場合は、コンテナを作り直してください（Rebuild Container）。

## コンテナの中での codex のサンドボックス
codex は、コマンドを読み取り専用などのサンドボックスの中で動かすために bubblewrap（bwrap）を使います。bwrap は namespace を作り、その中で mount します。Docker はコンテナに既定で次の制限を当てていて、どちらもこれを止めます。

| 制限 | 当たる環境 | 止めるもの | 外さないときの失敗 |
|---|---|---|---|
| seccomp（Docker の既定のプロファイル） | ネイティブ Linux の Docker Engine と Docker Desktop（macOS）の両方 | `CAP_SYS_ADMIN` を持たないプロセスの namespace の作成 | `bwrap: No permissions to create new namespace` |
| AppArmor（`docker-default`） | ネイティブ Linux の Docker Engine（AppArmor が有効なとき） | mount | `bwrap: Failed to make / slave: Permission denied` |

先に止めるのは seccomp なので、**AppArmor だけを外しても動きません。** そのため `--with-codex` の生成物は、`devcontainer.json` に次を入れます。

```jsonc
  // （理由の説明のコメントが付きます）
  "securityOpt": ["apparmor=unconfined", "seccomp=unconfined"],
```

- **`compose.yaml` の `security_opt` には置きません**（v0.20.0 までは置いていました）。go などの feature は、自分の metadata で `seccomp=unconfined` を足します。`compose.yaml` にも同じ値があると、Compose が `security_opt items ... are equal` で重複を拒否し、コンテナが起動しません。`devcontainer.json` の `securityOpt` は、feature の値と重複が除かれて合成されます。
- **`devcontainer.json` は JSONC（コメント付きの JSON）になります**。VS Code も devcontainer CLI も、コメントを許します。`jq` など厳密な JSON の読み手に渡すときは、コメントを除いてから渡してください（文字列の中の `//` を壊さないよう、`perl -0777 -pe 's{("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' .devcontainer/devcontainer.json | jq ...` のように文字列を先に拾う形にします。`sed 's://.*::'` は URL を壊します）。
- **既存の生成先**は、`--upgrade` で `compose.yaml` と `devcontainer.json` の両方が変わります。手を入れていなければ自動で移ります。手を入れていれば `.dcb-new` が置かれるので、`compose.yaml` の `security_opt`（`apparmor=unconfined` / `seccomp=unconfined`）を消し、`devcontainer.json` へ `securityOpt` を足してください。

- **実測した環境**: Ubuntu 26.04.1（カーネル 7.0.0-38、AppArmor 有効、`kernel.apparmor_restrict_unprivileged_userns = 1`）のネイティブの Docker Engine と、codex 0.160.0。既定と AppArmor だけ外した場合は `codex sandbox -- git status` が上の表の 1 行目で失敗し、2 つとも外すと通りました。ホストの `apparmor_restrict_unprivileged_userns` は、この失敗に関わっていませんでした。Docker Desktop（macOS）でも、既定のままでは同じ 1 行目で失敗し、2 つを外すと user namespace の作成と mount が通ることを確かめています。
- **代償**: コンテナの中のプロセスが namespace を作り、mount できるようになります。Docker がコンテナに既定で掛けている隔離の 2 層を外すことになるので、`--with-codex` を選んだ構成に限っています。codex を使わなくなったら、`devcontainer.json` から `securityOpt`（とその説明のコメント）を消してください。
- **第二意見（`scripts/second-opinion-review.sh --engine codex`）だけでも要るか**: 外せると言えないため、残しています。第二意見は codex を `env -i` で、ツールを `--disable` し、`--sandbox read-only` で起動するので、モデルのコマンドは走りません。それでも codex は起動のたびに、サンドボックスが使えるかの確認として `bwrap --unshare-user --unshare-net --ro-bind / / /bin/true` を起動します（codex 0.162.1 の第二意見 1 回を `strace -f -e trace=execve` で記録し、3 回の実行で bwrap が 3 回起動されることを確認）。この確認は namespace の作成を伴い、既定の seccomp が止める操作そのものです。緩和を外したコンテナでの実測は行っていないため、その場合に確認が失敗して第二意見が止まるのか、警告だけで動くのかは分かっていません。
- **緩和を外してよいのは**、そのコンテナで codex を使わないときだけです（`--with-codex` を選ばない、または `devcontainer.json` から `securityOpt` を消す）。
- **`systempaths=unconfined` は入れていません。** bwrap は `/proc` を新しく mount しようとして、Docker が `/proc` の一部を隠していることで拒まれますが、codex はこの失敗を自分で避けて動きます。外す範囲を広げずに済むので入れていません。
- **Docker Desktop（macOS）** には AppArmor がなく、`apparmor=unconfined` は効き目がないだけで害はありません。止めているのは seccomp なので、Mac でもこの設定が要ります。

## 資格情報の扱い

**ホスト OS の資格情報をコンテナへ注入しません。** 生成される `remoteEnv` が運ぶのは作業ディレクトリのパス（`LOCAL_WORKSPACE_FOLDER`）だけです。

この方針は事故の反省から来ています。`${localEnv:...}` でトークンを注入する構造では、コンテナ内のツールが「どの資格情報を使っているか」を利用者が意識できません。ホスト側と `.env` に別の値が入っていると、`.env` を読まない文脈でだけ黙ってホスト側が使われ、別アカウントの PAT が `git credential fill` から警告なく返る、別アカウントの API キーでクォータと課金が消費される、といった形で表面化します。

代わりに、次の 2 経路に限定します。

| 種類 | 供給元 | 永続化 |
|---|---|---|
| 認証（GitHub / cloud / AI CLI） | **コンテナ内でのログイン**（`gh auth login` / `aws sso login` / `gcloud auth login` / `claude /login`）。GitHub だけは `.env` の `GH_TOKEN` で PAT に固定する経路もあります（[理由](#github-認証だけが例外である理由)）。`GITHUB_TOKEN` は[供給元にしません](#github_token-は設定しない) | named volume（`gh-storage` / `aws-storage` / `gcloud-storage` / `<ai>-storage`）。リビルドを跨いで残る |
| プロジェクト固有値（API キー・コミット identity） | **プロジェクトの `.env`**（雛形: 生成される `.env.example`） | ファイルとして目に見える。`scripts/load-project-env.sh` が読む |

`.env.example` が持つキー:

- `GEMINI_API_KEY` — 第二意見レビュー（`scripts/second-opinion-review.sh`）が読みます。**記入するエンジン（下の `SECOND_OPINION_ENGINE`）が `codex` / `antigravity` に決まっていて、かつ `--with-gemini` を選んでいないときだけ出しません**（gemini の CLI が入らず、どのエンジンも使わないため）。`--with-gemini` を選んだ構成は、エンジンを固定しても gemini の CLI が入るので出します。エンジンが gemini、空（既定の gemini で回る）、またはエンジンの欄自体が出ない構成でも出します。
- `SECOND_OPINION_ENGINE` — 第二意見のエンジン（`--with-antigravity` / `--with-codex` を選んだときだけ出ます）。**選んだエンジンから一意に決まるときは、記入済みで出します。** `--with-gemini` も選んだ構成では `gemini`（明示しておけば、`.env` を持つ作業ツリーでは下の通知が出ず、`.env` を写し忘れた作業ツリーでだけ出ます）、`--with-gemini` を選ばず antigravity か codex の片方だけを選んだ構成ではそのエンジンです（既定の gemini は CLI もキーも無く、設定するまで使えないため）。gemini を選ばず antigravity と codex の両方を選んだ構成は、どれを選ぶかが一意に決まらないので空のままです（空なら gemini）。**実際に使うエンジンが、これらの決め方と違うとき（例: gemini の CLI を入れたまま第二意見を codex で回す）は、`--second-opinion-engine <gemini|antigravity|codex>` で明示します。** 指定した値が最優先で記入されます。止まる条件と `--upgrade` の引き継ぎは、オプション一覧の `--second-opinion-engine` の項に従います。**既存の `.env` は書き換えません。** `--upgrade` で変わるのは `.env.example` だけなので、すでに `.env` を持つ構成には効きません。
- `GH_TOKEN` — GitHub の PAT。**上表の「コンテナ内でのログイン」に対する唯一の例外**です（下記「[GitHub 認証だけが例外である理由](#github-認証だけが例外である理由)」）。空にすれば従来どおり `gh auth login` の保存済み認証で動きます（**`GITHUB_TOKEN` も未設定であることが条件**。下記「[`GITHUB_TOKEN` は設定しない](#github_token-は設定しない)」）。
- `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` — コミット identity。`scripts/setup-git-identity.sh` が local へ適用します。
  - `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` という名前を使わないのは、それが **git 自身の読む環境変数**だからです。環境に置くと local 設定を持たないリポジトリでも identity が解決でき、`user.useConfigOnly` による保護（未設定なら commit を止める）が無効になります。

### GitHub 認証だけが例外である理由

トークンをファイルへ書き写さず、ツール自身のログイン状態に持たせるのがこのパッケージの原則です。**GitHub CLI だけはこの原則の例外**として、PAT を `.env` の `GH_TOKEN` へ置く経路を用意します。

gh の OAuth App には「ユーザー × アプリ × scope あたり 10 トークン」の上限があります。上限に達した状態でどこかの環境が認証すると、GitHub が既存のトークンを 1 本破棄します（理由コード `max_for_app`）。溜まる単位は環境ではなく**認証の回数**で、`gh auth login` も `gh auth refresh` も自分の古い枠を返しません。失効に気づいた環境が再認証し、それがまた別の環境を失効させる連鎖になるため、**運用ルールでは回避できません**。作業中に `HTTP 401: Bad credentials` が繰り返し出る体感の正体がこれです。PAT は OAuth App の認可ではないため、この枠の外にあります。

| `GH_TOKEN` | 使われる資格情報 | `gh auth login` | 上限枠の消費 |
|---|---|---|---|
| 空（かつ `GITHUB_TOKEN` も空） | `hosts.yml` の OAuth トークン | できる | する |
| PAT | PAT に固定 | 使えない（env が優先） | しない |

- **名前は gh 自身が読む `GH_TOKEN` をそのまま使います。** `GIT_IDENTITY_*` を別名にしているのと方針が逆に見えますが、理由が違います。git は自身が読む名前を環境へ置くと `user.useConfigOnly` の保護が無効になるため別名にします。gh には、環境変数を置くことで無効化される保護がありません。別名にすると受け渡しの仕掛けを足すだけになります。
- **PAT を設定しているあいだ `gh auth login` は使えません。これは制約ではなく安全装置です。** うっかり再認証して他環境のトークンを殺す事故が構造的に起きなくなります。gh 2.96.0 で実測したところ、値が設定されているあいだ gh はログインを拒否します（`--with-token` / `--web` のいずれでも `The value of the GH_TOKEN environment variable is being used for authentication.` で終了し、通信もしません）。危ないのはその先で、拒否メッセージ（`first clear the value from the environment`）に従って値を空にしてログインすると、上限枠を 1 つ消費します。
- **fine-grained PAT で必要になる権限の例と、選べない権限があること:** `/land` の雛形（`.claude/skills/land/SKILL.md`）が行う操作は、次の権限で足ります。必要な権限は行う操作で変わるため、最小の組はプロジェクトごとに決めてください。

  | 行う操作 | repository permission |
  |---|---|
  | clone / push | Contents: Read and write |
  | PR の作成・コメント・マージ | Pull requests: Read and write |
  | issue の起票・コメント | Issues: Read and write |
  | `.github/workflows/` を含む push | Workflows: Read and write |
  | CI の実行の確認（`gh run list` / `actions/runs`）、ゲートの手動実行（`gh workflow run`。`second-opinion-record.sh post` と `/land` のマージ直前の再判定） | Actions: Read and write |
  | commit status（`second-opinion-gate` など）の確認 | Commit statuses: Read |
  | （必須・自動付与） | Metadata: Read |

  **手動実行の権限（Actions: Read and write）は、実測で確かめています**。この表の権限だけを持つ fine-grained PAT で、Actions を Read and write にすると `gh workflow run` が通り、Read-only に下げると `HTTP 403: Resource not accessible by personal access token` で拒否されました（実行の一覧などの読み取りは、どちらでも通ります）。GitHub の公式ドキュメント（「Permissions required for fine-grained personal access tokens」の Actions の節。`POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches` は write）とも一致します。権限が足りないと `second-opinion-record.sh post` は、記録の投稿後に手動実行できなかったとして非 0 で終わり、手で起こすコマンドを示します。

  **Checks は fine-grained PAT では選べません。** そのため、**非公開リポジトリでは** `commits/<sha>/check-runs` と `gh pr checks` が 403 になります（公開リポジトリでは読めます）。`/land` の雛形はこの 2 つを使わず、Actions と Commit statuses の権限だけで CI を待ちます。プロジェクト側でスクリプトを足すときも、この 2 つに頼らないでください。
- **`GH_TOKEN` が空の環境は従来どおり**保存済み認証で動きます（`GITHUB_TOKEN` も未設定である場合。下記）。PAT を持たない利用者を壊しません。
- 発行手順と必要権限は、対象リポジトリと行う操作で変わるため、このパッケージは決め打ちしません。プロジェクト層（`.ai-playbook/templates/project-ai-rules.md` の「機密の具体化」）に記述してください。

### `GITHUB_TOKEN` は設定しない

**`GITHUB_TOKEN` を恒久的に設定しないでください。** gh に登録済みのアカウントより優先され、コンテナ内のログイン状態が無視されます。`GH_TOKEN` と違い、この経路はこのパッケージが供給元として想定していません。

**`GH_TOKEN` を空にすることは `GITHUB_TOKEN` に対する盾になりません。** gh は `GH_TOKEN` → `GITHUB_TOKEN` の順に環境変数を読み、**空文字だけを読み飛ばして次へ落ちます**。gh 2.96.0 で実測した結果は次のとおりです（`hosts.yml` にログイン済みの状態）。

| `GH_TOKEN` | `GITHUB_TOKEN` | `gh api user` の結果 |
|---|---|---|
| 未設定 | 未設定 | 成功（`hosts.yml` の保存済み認証） |
| 空 | 未設定 | 成功（保存済み認証へフォールバック） |
| 未設定 | 空 | 成功（保存済み認証へフォールバック） |
| 未設定 | 非空（無効値） | **失敗** `Bad credentials` |
| 空 | 非空（無効値） | **失敗** `Bad credentials` |
| 非空（無効値） | 非空 | **失敗**（`gh auth status` は `GH_TOKEN` 側を報告する） |

境界は「未設定かどうか」ではなく「**空でない値かどうか**」です。生成される `scripts/on-attach.sh` の判定もこの境界に合わせており、`GITHUB_TOKEN` が効いている場合は「保存済み認証を使用」とは報告せず、優先されている旨を WARN で知らせます。認証を確認できないときも `gh auth login` を案内しません（案内すると、値を空にして再ログインする手順へ誘導することになるためです）。

### 接続時の gh 認証チェック

`scripts/on-attach.sh` は接続のたびに `gh auth status --active` を実行します。

- **`--active` を付けます。** 環境変数のトークンと `hosts.yml` の保存済み認証は共存しうるため、付けないと gh は両方を並べて報告し、**使っていない側が無効なだけで exit=1** になります。判定したいのは「いま使われている資格情報が有効か」だけです。
- **「到達できない」とも「認証が無効」とも断定しません。** gh の出力では両者を区別できないことを実測しています（到達できないときも `The token in GH_TOKEN is invalid.` と言います）。到達性を `/dev/tcp` で自前に測る案は採っていません。測れるのは直接経路だけで、gh が使うのはプロキシ経路です。プロキシ経由でしか外へ出られない環境では直接接続が塞がれ、疎通しているのに「到達できません」と誤判定します。断定できるのは打ち切り（`timeout` の exit 124）だけなので、そこだけを分けて報告します。
- **環境変数で認証しているあいだ（`GH_TOKEN` / `GITHUB_TOKEN` のいずれかが非空）は `gh auth login` を案内しません。** gh 自身が値の設定中はログインを拒否するため案内が空振りするうえ、拒否メッセージに従って値を空にしてログインすると上限枠を 1 つ消費し、上限に達していれば他環境のトークンが 1 本失効します。
- `on-attach.sh` は自分自身でも `scripts/load-project-env.sh` を読みます。rc への注入は「これから開く対話シェル」にしか効かず、`bash` で実行される `on-attach.sh` 自身には届かないためです。読まないと `GH_TOKEN` が常に空に見え、PAT モードの利用者へ `gh auth login` を案内してしまいます。

### ホスト側 VS Code に必要な設定

コンテナ側だけでは塞ぎきれない経路が 1 つあります。**ホスト側の VS Code 設定で塞いでください。**

```jsonc
// settings.json（ホスト側）
{
  "dev.containers.dockerCredentialHelper": false
}
```

VS Code は接続のたびにコンテナの `~/.docker/config.json` へ `credsStore` を書き込みます。これが残っていると、コンテナ内の `docker login` / `docker pull` がホスト OS のキーチェーンへ問い合わせ、ホスト側の資格情報を黙って使います。

生成される `scripts/on-attach.sh` は接続ごとにこの `credsStore` / `credHelpers` を除去しますが、**これは多層防御の 1 枚にすぎません**。VS Code の書き込みと `postAttachCommand` の実行順序によっては打ち消しが間に合わないことを実測で確認しています。確実に塞ぐのはホスト側の設定です。

### プロジェクト `.env` の優先読み込み

`scripts/load-project-env.sh` がプロジェクトルートの `.env` を読み、**既存の環境変数より後勝ちで上書き**します。`.env` が唯一の供給元であることを保つため、値が既に環境にある場合も読み飛ばしません。

- **`source` しません。** `KEY=VALUE` のみを安全にパースして `export` するため、`.env` の内容は任意コードとして実行されません（`FOO=$(...)` や単独の `echo` 行があっても実行されない）。壊れた `.env` がシェルの初期化ごと落とす事故を防ぎます。
- **CWD 非依存。** スクリプト自身の位置（`scripts/` の 1 階層上）から `.env` を解決するため、サブディレクトリから呼んでも正しく読み込みます。`PROJECT_ENV_FILE` で対象ファイルを明示指定できます。
- **bash / zsh 双方**で動作し、CRLF・`export KEY=VALUE`・`KEY = VALUE`・クォート囲みの各形式を吸収します。複数回読み込んでも安全（冪等）。`.env` が無ければ何もしません。
- 対話シェルへは `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へマーカー付きで**冪等に**注入するため、ターミナルから起動する CLI（`gemini` 等）にも `.env` の値が効きます。非対話実行（`scripts/second-opinion-review.sh` 等）は各スクリプトが冒頭で明示的に読み込みます。
- **コンテナを作り直した直後は、VS Code の拡張から起動するプロセス（Claude Code など）に `.env` の値が届きません。** VS Code の拡張ホストは、`postAttachCommand` の `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へ注入するより前に起動し、注入前のシェルから環境を取り込むためです。拡張から起動するプロセスはこの環境を受け継ぐので、会話を開き直しても直りません（ターミナルで新しく開いたシェルは `~/.bashrc` を読むので、こちらには値が効きます）。作り直した直後に 1 度、コマンドパレットから `Developer: Reload Window` を実行してください。拡張ホストが作り直され、注入後のシェルから環境を取り直します。

## Git identity ガード

**local 設定を持たないリポジトリは、git が黙って global へフォールバックしてコミットを通します。** 新規リポジトリを作った直後がまさにその状態で、別アカウント名義のコミットが `main` に混入する事故が起き得ます。この穴を、適用・検証・CI の 3 層で塞ぎます。

- `scripts/setup-git-identity.sh`（適用。`scripts/on-attach.sh` が毎接続で再適用）
  - global の `user.name` / `user.email` を削除し、`user.useConfigOnly=true` を立てます。これにより **local 設定を持たないリポジトリでは `git commit` が exit 128 で停止**します（黙って別名義になるより止まって気づく）。
  - 当リポジトリの local へ、`.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` を適用します。未設定なら local 適用はスキップし WARN に留めます。
  - global の `credential.helper` を「空 → `!gh auth git-credential`」の順に固定します。git はヘルパーを定義順に試し、**空文字は一覧をリセットする**ため、この順序だと `/etc/gitconfig` 側やエディタが注入したヘルパーが応答しなくなります。資格情報の供給元がコンテナ内の `gh` だけに絞られます。
  - 冪等です（2 回実行しても git config は不変）。`bash scripts/setup-git-identity.sh --check` で状態を検証できます。`gh` を呼ばないためオフラインでも動きます。`--check` が出力する項目は次のとおりです。
    - global の `user.name` / `user.email` が未設定であること、`user.useConfigOnly=true` であること。
    - 当リポジトリの local identity が `.env` の値と一致し、author identity を解決できること。
    - local 設定を持たない一時リポジトリで author identity の解決が**失敗する**こと。
    - global の `credential.helper` が「空 → `gh`」の順に固定されていること。
    - local 設定を持たない一時リポジトリでの実効ヘルパーが `gh` のみであること。
    - **system スコープ（`/etc/gitconfig` 等）の `credential.helper` の検出結果**。あれば `INFO` として列挙し、無ければ `OK` を出します。上の 2 項目は global と実効値しか見ないため、system に何が置かれていても出力に現れないので別に出します。**判定には影響させません**（`INFO` が出ても `--check` は成功します）。実効値からは外れており遮断は成立していること、置く側が接続のたびに書き戻す構成では常時検出され続けること、そして**誰がいつ置いたかはこの検査からは判定できない**ことが理由です。恒常的な赤は「赤を無視する習慣」を生むため、事実の提示に留めます。
    - 冪等性（再適用で global 設定ファイルが 1 バイトも変わらないこと）。先行する検査が失敗している場合は実行しません。
  - `on-attach.sh` からの呼び出しは、失敗しても **on-attach 全体を落としません**（WARN と `--check` の案内に留める）。
- `scripts/verify-commit-identity.sh`（検証。CI と手元で共用）
  - コミット履歴の author / committer / Co-Authored-By を **email のみ**で判定します（name は表記揺れで判定に使わない）。許可外の author email を含む範囲で exit 1。
  - 許可する author email は、環境変数 `ALLOWED_AUTHOR_EMAILS`（カンマ/空白区切り）を最優先し、無ければ `.env` の `GIT_IDENTITY_EMAIL` にフォールバックします。どちらでも解決できなければ fail-closed（exit 1）で止まります。
  - committer には `noreply@github.com`（GitHub の squash merge / web UI）、Co-Authored-By には加えて `noreply@anthropic.com`（AI コーディング規約の trailer）を許可します。
  - 許可エントリには `@example.com` / `*@example.com` の形でドメイン一括指定を書けます。**この 2 形だけ**をドメイン指定として解釈し、それ以外は完全一致です（任意の glob を許すと、設定ミスの `*` 1 文字で全 email が通り検知層が無効化されるため）。`*` 単体は何も許可しません。ローカル部が 1 文字以上あり、かつ `@` を含まないことを要求します（`@example.com` という email そのものや、`attacker@untrusted.com@example.com` の形を通さないため）。
  - committer が `noreply@github.com` のコミットに限り、author が `<login>@users.noreply.github.com` の形であれば許可します。GitHub 側で「メールアドレスを非公開にする」を有効にしている利用者の PR マージ・web UI 編集に対応するためで、許可を committer に縛るのは、適用漏れが通る範囲を狭めるためです。committer / author の email はローカルで自由に設定できるため、**この許可は偽装を防ぎません**（ローカルで作ったコミットでも、この 2 つを GitHub の形に設定すれば通ります）。この検査の目的は identity の適用漏れ（別アカウントの email の混入）の検出で、意図的な偽装への対策は書き込み権限の管理と、必要なら署名の検証（GitHub の verified な web-flow の署名）が担います。書き込み権限を持つ人を信頼するという既存のトレードオフと同じ側の判断です。
  - 同じ条件（`is_github_authored`）を `Co-Authored-By` にも適用します。マージした人と PR の作者が違う squash merge では、GitHub がマージの瞬間に作者を `Co-authored-by` として足します。PR の検査（マージ前）では見えず、`push(main)` の全履歴検査で初めて現れる形です。
  - 使い方: 既定は `origin/main..HEAD`、範囲指定可、`--full` で HEAD の全履歴（`git rev-list --all` にはしない）。
- `scripts/verify-commit-identity-selftest.sh`（判定の自己試験。CI と手元で共用）
  - `verify-commit-identity.sh` の判定そのものが壊れていないかを、1 コミットだけの仕込みのリポジトリで確かめます。**本物の履歴だけでは、落ちるべき形（squash merge で足される `Co-authored-by` 等）がほとんど現れず、許可を広げすぎて「何でも通る」になっても気づけません。** `.github/workflows/identity-guard.yml` は `verify-commit-identity.sh` の検証より前にこれを呼びます。
- `.github/workflows/identity-guard.yml`（CI）
  - `pull_request`（PR の全コミット）と `push`（`main` の全履歴）の 2 系統で、自己試験 → `verify-commit-identity.sh` の順に呼びます。直接 push こそが混入の原因なので `push(main)` を省略しません。判定はスクリプト側にあり、ワークフローは呼ぶだけです。

### 利用側の設定手順（許可 author email）

CI に固有の email を焼き込まないため、**利用側リポジトリでリポジトリ変数を設定します**。

1. GitHub リポジトリの **Settings → Secrets and variables → Actions → Variables** を開く。
2. `ALLOWED_AUTHOR_EMAILS` という **Repository variable** を作成し、許可する author email を設定する（複数はカンマまたは空白区切り。例: `you@example.com`）。

未設定のまま CI が走ると、`verify-commit-identity.sh` は許可 email を解決できず fail-closed で失敗します（検査を素通りさせないため）。

**新しいリポジトリでは、最初の push より前に変数を設定します。** リポジトリ変数はリポジトリを作ってからでないと設定できないため、生成物をそのまま最初に push すると、その push の identity-guard は必ず失敗します（失敗の理由は、ジョブのログに「リポジトリ変数 `ALLOWED_AUTHOR_EMAILS` を設定してください」と出ます）。順番は次のとおりです。

1. GitHub でリポジトリを作る（まだ push しない）
2. 上の手順で `ALLOWED_AUTHOR_EMAILS` を設定する
3. push する

先に push してしまった場合は、変数を設定してから、失敗した identity-guard の実行を再実行してください（`gh run rerun <実行 ID> --failed`、または Actions の画面の「Re-run failed jobs」）。fail-closed の動作としては正しく、設定すれば緑になります。コンテナ内・手元では `.env` の `GIT_IDENTITY_EMAIL` が自動でフォールバックとして使われるため、通常は追加設定なしで `bash scripts/verify-commit-identity.sh` を実行できます。

## 機密混入検査

共通規範「機密をコミットしない」を機械化した検知ゲートを `scripts/check-no-secrets.sh` として常に配置します。**判定はスクリプト側が持ち、`scripts/verify.sh` と CI は呼ぶだけ**という形は `verify-commit-identity.sh` と同じです。`acceptance.sh` 雛形へ書かないのは、あちらがプロジェクトの所有物で、受け入れ条件を書き足すたびに触られ、規範由来の検査が消える経路ができるためです。

```bash
bash scripts/check-no-secrets.sh   # 終了コード 0 / 標準出力 SECRETS_PASS
```

検査は 4 つあります。

| 検査 | 見るもの | 落とす場所 |
|---|---|---|
| 追跡前 | `git add --all --dry-run` が「追加する」と言うパス | 手元。追跡対象へ入る**前**に落とす |
| 追跡済み | `git ls-files` が返すパス | CI。機密を含んだままの PR を落とす |
| 雛形の値 | `.env.example` の機密キーに値が入っていないこと | 手元と CI |
| キー整合 | `.env` にあるキーが `.env.example` にもあること | 手元（`.env` が無い環境ではスキップ） |

- **2 経路あって初めて成立します。** checkout 直後の作業ツリーはクリーンなので dry-run の出力は空になり、追跡前の検査だけでは CI が「何も検査していない状態」で合格します。CI が本来捕まえたいのは機密を含んだままの PR、すなわち追跡済みの状態です。逆に追跡済みの検査だけでは、手元で追加しようとしている段階を止められません（誤ってコミットしてからでは、削除コミットでは漏洩は解消せず、履歴からの除去と資格情報の失効・再発行が必要になります）。
- **検知対象は 2 経路で同じパターンです。** `.env` 系 / `.netrc` / `.pgpass` / `.git-credentials` / SSH 秘密鍵（`id_rsa` 等）/ `credentials.json` / `client_secret*` / `service-account*` / `*.pem` `*.key` `*.p12` `*.pfx` `*.jks` `*.keystore` `*.kdbx` `*.tfstate` `*.tfvars` を対象とし、いずれも直後に `.` `-` `_` `~` で始まる接尾が付く形（`credentials.json.bak` / `terraform.tfstate-backup`）まで拾います。片方だけ末尾一致に絞ると、こうした改名・退避ファイルが片側だけすり抜けます。
- **値のない雛形と公開鍵は除外します**（`*.example` / `*.sample` / `*.template` / `*.dist` / `*.pub`）。名前で判定するため、機密を `.example` という名前で置けばこの層はすり抜けます。配布する唯一の雛形である `.env.example` については、キー名で機密を判定して**値が空であること**を別に検査し、第 2 層にしています。
- **`.env.example` の機密値検査は、機密を示す語を含むキーと identity キーだけを対象にします。** 機密でない設定既定値（回数・モデル名など）は雛形で共有する意味があるためです。判定は部分一致で、語尾一致にすると `AWS_SECRET_ACCESS_KEY_ID` のような修飾付きがすり抜けます（`PAT` だけは `PATH` との衝突を避けて語境界を要求します）。**検出時に出すのはキー名だけで、値は決して出力しません。**
- **キーの抽出は `scripts/load-project-env.sh` 自身に読ませます。** 別に書くと「実際には読まれるのに検査からは見えないキー」が生まれ、機密値の検査に穴が開きます。呼び出し元のシェルが既に `.env` を読み込んでいても結果が変わらないよう、`env -i` を通した最小環境で読み込みます。
- **キー整合は `.env` 側にしか無いキーだけを落とします。** 雛形にあって `.env` に無い向きは `NOTICE` に留めます。雛形へキーが増えた直後は各環境の `.env` が追いつくまで必ずその状態を通るため、ここで落とすと配布物の更新のたびに全利用者のローカルゲートが赤くなり、直す先が追跡ファイルではなく各人の手元になります。値が解決できないことが実害になる経路は、それを必要とする検査がそれぞれ fail-closed で落とします（例: `verify-commit-identity.sh` の許可 email）。
- **検査が成立していないことを合格にしません。** git の作業ツリーでない、`git add` / `git ls-files` が失敗した、追跡ファイルが 1 件も無い、`.env.example` が無い、のいずれも `SECRETS_FAIL` です。空の出力を「該当なし」と読むと、検査していないのに合格になります。**したがって生成直後のプロジェクトでは、`git init` して追跡対象を 1 件以上コミットするまで `verify.sh` / `loop-gate.sh` は通りません。**
- **ロケールを `LC_ALL=C` に固定します。** 追跡前の検査は `git add --dry-run` の人間向け出力（`add '<path>'`）を解析するため、その文字列が翻訳されると「該当なし」として通り、失敗の仕方がサイレントな合格になります（実測では git 2.53.0 の翻訳カタログに当該 msgid は無く、現時点では翻訳されません。それでも人間向け出力への依存は残るため固定します）。キー整合の `sort` / `comm` も同じ理由です。GNU `sort` の照合順はロケールで変わり、両辺が別の照合順で並ぶと `comm` は警告を出しつつ終了コード 0 で誤った差集合を返します。
- **`git ls-files` には `-c core.quotePath=false` を渡します。** 既定（`true`）では非 ASCII やスペースを含むパスが `"..."` で囲まれ、非 ASCII 部分が `\NNN` の 8 進エスケープへ置き換わります。閉じ引用符が付くことで名前の末尾を見る判定が阻まれ、追跡済みの「非 ASCII ディレクトリ/`.env`」がすり抜けるうえ、`.env.example` の除外判定も末尾が `example"` になって成立せず逆に誤検知します。1 行で両方を塞げます。

## AI エンジン導入マトリックス

このパッケージが生成する環境における、AI CLI の導入・認証要件のマトリックスです。

| エンジン | コマンド | 認証環境変数 | 導入経路 | 未導入・未認証時の挙動 |
|----------|----------|--------------|-------------------|------------------------|
| Claude | `claude` | `/login`（既定。トークン注入は任意） | `--with-claude` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時は `/login` プロンプト表示（トークン運用は下記「Claude の認証」参照） |
| Gemini | `gemini` | `.env` の `GEMINI_API_KEY`（`.env.example` の欄は、エンジンが codex / antigravity に決まり `--with-gemini` を選ばない構成では出ません） | `--with-gemini` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | API キー不足または API/認証エラーで失敗 |
| Antigravity | `agy` | Google アカウントの **OAuth のみ**（API キー非対応） | `--with-antigravity` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時は応答を返さず終了（非対話ではツール実行許可を自動拒否し、診断は標準エラーへ出る） |
| Copilot | `copilot` | GitHub 認証（`gh` / OAuth） | `--with-copilot` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時はログインプロンプト表示またはエラー終了 |
| Codex  | `codex` | `.env` の `OPENAI_API_KEY` | 未対応（`--with-codex` は将来対応予定。現状は手動導入のみ） | バイナリ未導入または API キー未設定で失敗 |

各 AI ツールを `--with-<ai>` で選ぶと、CLI に加えて対応 VS Code 拡張が入り、設定ディレクトリ（`~/.claude` / `~/.gemini` / `~/.copilot`）が compose の named volume でリビルド間に保持されます。**Antigravity だけは VS Code 拡張を持たず**、永続先は Gemini と同じ `~/.gemini` です。

### Antigravity の認証とテレメトリ

`--with-antigravity` は CLI（`agy`）を導入するだけで、**導入しただけでは使えません**。認証は Google アカウントの OAuth のみで、API キーには対応しません。コンテナ内で対話的に `agy` を起動し、初回のログインを済ませてください。

資格情報は `~/.gemini/antigravity-cli/` に置かれます。この階層は `gemini-storage` volume に載るため、**リビルドしてもログイン状態は消えません**。OS のキーリングは使いません。

テレメトリ（利用統計・クラッシュログ・対話ログの送信）は、生成物の `scripts/install-ai-tools.sh` が `~/.gemini/antigravity-cli/settings.json` の `enableTelemetry` を `false` へ**マージ**して無効化します。環境変数によるオプトアウトは存在せず、設定ファイルが唯一の手段です。

- 冪等です（既に `false` なら書き込みません）。`agy` 自身が書く他のキー（`colorScheme` / `trustedWorkspaces` 等）は保持します
- `jq` が無い場合と JSON が壊れている場合は**非 0 で停止**します。オプトアウトが黙って未適用のまま「プロビジョニング成功」に見える状態を作らないためです
- **無効化されるのは CLI のみです。** Antigravity IDE を使う場合は、IDE 側で別途設定してください（このパッケージの対象外です）

### Claude の認証（コンテナ内で `/login`）

`--with-claude` では、コンテナ内で作業前に `/login` して認証します。`~/.claude` は named volume で永続するため、一度 `/login` すればリビルドをまたいで有効です。

OAuth トークン（`CLAUDE_CODE_OAUTH_TOKEN`）を `remoteEnv` へ注入する経路は**用意しません**。権限スコープが限定されてフルスペックの操作が許可されないうえ、opt-in で穴を残せる構造そのものが「黙って別アカウントの資格情報が使われる」事故を生んだ形だからです。

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python|php|rust|ruby）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `remoteEnv` は `LOCAL_WORKSPACE_FOLDER` のみを持つこと（ホスト資格情報の注入経路を作らない）
4. ベースイメージは Docker サーバーの `os/arch` から自動判定（候補は版の名前で固定、既定: `mcr.microsoft.com/devcontainers/base:noble`、必要に応じて `--base-image` で上書き可能）

## 期待される出力

装備の選択によらず常に生成するもの（`--dry-run` を付けると、この一覧が `plan:` 行としてそのまま確認できます）:

- `.devcontainer/devcontainer.json`（言語別 feature を反映。docker-compose ベースで `.devcontainer/compose.yaml` の `app` サービスを参照。`--with-codex` のときだけ、説明のコメント付きで `securityOpt` を持つ JSONC になる）
- `.devcontainer/compose.yaml`（単一サービス `app` の compose 定義。compose 利用時は feature や devcontainer.json の mounts が適用されないため、docker socket を常に明示。認証用の永続 volume は `gh` を常時、cloud / AI CLI を `--with-*` 随伴で配置。`init: true` で PID 1 を Docker の組み込みの init にし、孤児になったプロセスを回収させる。PID 1 の `sleep infinity` は子を回収しないため、これが無いとゾンビが溜まり、数日でプロセス数の上限に達して `docker exec` もコンテナ内のセッションも止まる。既存の生成先は `--upgrade` で取り込んだあと、コンテナの作り直し（Rebuild）で効く）
- `.env.example`（プロジェクト固有値の雛形。`GEMINI_API_KEY`（条件付き。上記）/ `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL`）
- `scripts/fix-mount-owner.sh`（永続 volume のマウント先を remoteUser 所有へ戻す。`postCreateCommand` の先頭で実行）
- `scripts/install-ai-tools.sh`（`postCreateCommand` の後段で実行。`--with-<ai>` で選んだ AI CLI だけを導入する。上記「AI CLI 導入挙動」参照）
- `scripts/load-project-env.sh`（プロジェクト `.env` の優先読み込み。下記参照）
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`（永続 volume の実マウント検査を含む）
- `scripts/setup-git-identity.sh` / `scripts/verify-commit-identity.sh` / `scripts/verify-commit-identity-selftest.sh`（git identity ガード。下記参照）
- `.github/workflows/identity-guard.yml`（コミット identity の検証 CI。下記参照）
- `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh`（ループコーディング支援。下記参照）
- `scripts/update-check.sh`（DCB と ai-playbook の新しい安定版の確認と追従。`on-attach.sh` が通知を、対話のシェルの rc が問いかけを呼ぶ。[新しい版の確認と追従](#新しい版の確認と追従update-check)）
- `scripts/session-ledger.sh`（同じホストで並行して動く AI セッションの共有台帳。`claim` / `release` / `list` / `check` / `refresh` を持つ。置き場所は `git rev-parse --git-common-dir` の配下で、セッションごとに別ファイルへ追記する。規範は `.ai-playbook/shared-ai-rules.md`「セッション間の協調」。実行環境に依存しないので、装備フラグに関わらず常に生成する）
- `scripts/check-no-secrets.sh`（機密混入の検知ゲート。`verify.sh` が受け入れ条件の手前で呼ぶ。下記参照）
- `scripts/check-control-chars.sh`（追跡ファイルへの表示されない制御文字混入の検知ゲート。作業ツリーの内容に加え、索引（ステージ済み）と作業ツリーで内容が違うファイルは索引の blob も読み、索引側の検出は `<パス> (staged)` と示す。git の clean フィルターが、作業ツリーに無い禁止バイトを索引へ書き込む場合は見逃す（限界。`git diff` がフィルターを通した後の内容を比べるため）。単体で `bash scripts/check-control-chars.sh` として実行する。生成時の `acceptance.sh` の雛形は呼ぶ。既存の出力先ではプロジェクト側で配線する（[Doctor 自己診断](#doctor-自己診断)））
- `scripts/check-table-breaks.sh`（Markdown の表の途中へ段落が差し込まれ、続く行が表として描画されなくなっていないかの検知ゲート。単体で `bash scripts/check-table-breaks.sh` として実行する。生成時の `acceptance.sh` の雛形は呼ぶ。既存の出力先ではプロジェクト側で配線する（[Doctor 自己診断](#doctor-自己診断)）。**先頭行（ヘッダー行）が `|` を持たない表**（`a | b` / `--- | ---` の形。GFM としては有効）**は対象外**。判定を広げると本文中の `|` を含む段落を誤検知し始めるため、意図して見ない。この対象外の挙動はテストで固定している）
- `scripts/check-doc-links.sh`（追跡している Markdown の相対リンクが、追跡対象として実在することの検知ゲート。実在判定は作業ツリーではなく `git ls-files` の集合から `git ls-files --deleted`（作業ツリーで消してまだステージしていないもの）を除いたもので行う（除いたものは走査からもリンク先の集合からも外し、件数を報告する。sparse-checkout / skip-worktree で置いていないだけのファイルは追跡対象として実在する扱いのまま。追跡していないファイルは数えない）。単体で `bash scripts/check-doc-links.sh` として実行する。生成時の `acceptance.sh` の雛形は呼ぶ。既存の出力先ではプロジェクト側で配線する（[Doctor 自己診断](#doctor-自己診断)）。スキャンしたくない文書があれば、環境変数 `DOC_LINKS_EXCLUDE` へリポジトリルートからの相対パスのプレフィックスをコロン区切りで渡す（既定は空））
- `scripts/check-shell-portability.sh`（「この環境では通るが BSD 系（macOS）では落ちる」綴りの検知ゲート。単体で `bash scripts/check-shell-portability.sh` として実行する。生成時の `acceptance.sh` の雛形は呼ぶ。既存の出力先ではプロジェクト側で配線する（[Doctor 自己診断](#doctor-自己診断)）。追跡している `*.sh` と `*.md`（**フェンスで囲まれたコード部分だけ**）を走査し、この検査自身とテストも対象に含める。**移植性の保証ではなく、規則表に載っている綴りが無いことしか言わない**——新しく踏んだら規則表へ 1 行足す運用が前提。**代替を用意した上で意図的に使う場合は、その行へ `# bsd-ok: 理由` を書く**（理由は必須で、空の印は認めない）。印は差分に残るのでレビューで見える）
- `.github/workflows/verify.yml`（受け入れ検証を CI で回すゲート。上記「受け入れ検証の CI ワークフロー」参照）
- `.devcontainer/ORIGIN`（生成物の由来の記録。DCB の版・使った `--with-*` フラグ・生成の入力・各生成物のハッシュを持つ機械可読な key=value 形式。`doctor.sh` が乖離の診断に、`--upgrade` が入力の再現と手を入れたかの判定に使います。下記「生成物の由来の記録」参照）
- `.gitignore` の managed セクション（言語構成に応じて自動更新。`--no-gitignore` で無効化）

`--languages` に `node` を含めた場合は、次を出力します。

- `scripts/check-deps-installed.sh`（`node_modules` が `package-lock.json` と一致しているかの照合。生成される `scripts/acceptance.sh` が、`npm test` の**手前**で呼びます。ずれたまま走らせるとテストが `Cannot find package` で全滅し、**自分の変更と無関係な赤**になって原因が読み取れなくなるためです。**直しません。落とすだけです**——判定と修復を混ぜると、何が起きたのかが見えないまま結果だけが変わります。対処は `npm ci` です。`package.json` が無い場合は `DEPS_SKIP` を出して飛ばし、**通過（`DEPS_PASS`）とは別の信号にします**。npm 専用で、pnpm / yarn / bun の記録形式は見ません）

`--with-claude` を選んだ場合は、規範の配置とは独立に次を出力します（下記「[マージ確認フック](#マージ確認フックclaude-code)」参照）。

- `scripts/confirm-merge-hook.sh`（マージ実行の前に確認を挟む PreToolUse フックの本体）
- `scripts/session-coord-hook.sh`（並行セッションの共有台帳を操作の直前に確かめるフックの本体。下記「[セッション協調フック](#セッション協調フックclaude-code)」参照）
- `scripts/claude-session-wrapper.sh`（セッションの宛先名に場所と作業ツリーを自動で含める起動ラッパー。`.devcontainer/devcontainer.json` が VS Code の設定 `claudeCode.claudeProcessWrapper` へ、作業ツリーの外の固定パス（`/home/vscode/.local/bin/claude-session-launcher`）で配線します。このラッパーを直接指すと、ファイルが無いブランチへ切り替えただけで Claude Code が起動しなくなるため、極小の起動役（ラッパーが実行可能ならそれを、無ければ引数をそのまま exec する）を挟みます。起動役は、`devcontainer.json` の `onCreateCommand` が `scripts/on-attach.sh` を呼ばずに直接書き出し（一時ファイルへ書いて置き換える冪等な設置。失敗しても作成は止めず警告する）、`scripts/on-attach.sh` も接続のたびに冪等に設置します（既存のコンテナへの後追い）。2 つの経路が置く起動役の中身は同じですが、動きは同じではありません（`onCreateCommand` は無条件に設置し、`on-attach.sh` はラッパーが無ければ設置しません）。配線と設置が同じファイルにあるので、`--upgrade` で `on-attach.sh` だけが古いまま残っても、起動役は置かれます。拡張は設定値をそのまま実行ファイルのパスにし、`${workspaceFolder}` や `~` を展開しないため、絶対パスで書きます。`.env` の `SESSION_HOST_LABEL` が空なら宛先名を変えず、どんな失敗でも本体の起動まで進みます。宛先名の末尾は通常、起動ごとに変わる PID の 16 進です。ただし起動の引数に `--resume=<会話の識別子>` または `--resume <会話の識別子>`（UUID の形）があれば、識別子の先頭 8 桁（最初のハイフンの前）を使います。会話を再開しても宛先名が変わらず、ほかのセッションが覚えた宛先名へ再起動の後も送れます。`--resume` の直後が UUID の形でないとき（例: `--resume --verbose`）は PID の 16 進です。新しい会話の最初の起動の引数に識別子が含まれない場合は、その最初の起動だけ PID の名前になり、最初の再開のときに 1 回だけ名前が変わります。識別子の先頭 8 桁は、同じ作業ツリーの別の会話と重なる確率は小さいもののゼロではありません。重なると同じ宛先名のセッションが並び、宛先名だけでは送り分けられません（`/peers` の `resolve` は複数件として候補を出しますが、どれを選んでも宛先名は同じです）。そのときは、片方の会話を開き直して新しい会話にしてください）
- `scripts/session-peers.sh`（同じプロジェクトで動くほかのセッションの一覧・宛先の解決・送信元の署名。`.claude/skills/peers/SKILL.md` の `/peers` が呼びます。`~/.claude/sessions/*.json` は公開された仕様ではないため、読めなければ警告して `ListAgents` を案内します）
- `.claude/settings.json`（上記 2 つのフックの配線。既存ファイルは既定ポリシー `skip` で温存します）
- `.claude/.gitignore`（`settings.local.json` を追跡しない）

規範を配置する場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、加えて次を出力します。

- `.ai-playbook/**`（AI 共通ルール一式。内容の正本は ai-playbook 側にあり、DCB は木ごと配置するだけです）
- `.ai-playbook/VERSION`（DCB が記録する規範の**取得元**の記録。`version=`（`--playbook-version` のタグ。未指定なら `(unspecified)`）と `source=`（解決したディレクトリまたは URL）の 2 行を持つ機械可読な key=value 形式。生成の入力と現物のハッシュは持たず、それは `.devcontainer/ORIGIN` の役割です。規範ファイルと同じ振り分けに従います（従来の再実行では `--playbook-conflict-policy`、`--upgrade` では手を入れていなければ更新）。「[再実行したときの挙動](#再実行したときの挙動)」参照）
- `.github/project-ai-rules.md`
- `CLAUDE.md` / `AGENTS.md` / `.github/copilot-instructions.md`
- `scripts/second-opinion-review.sh`（第二意見レビュー。`scripts/loop-gate.sh` が存在を検出して自動で直列化します。上記「ループコーディング支援」参照）
- `scripts/second-opinion-schema.json`（JSON スキーマ方式で判定するエンジン（antigravity / codex）が読む回答の形。`second-opinion-review.sh` と対で配置します）
- `scripts/second-opinion-record.sh` / `scripts/second-opinion-gate-exempt.sh` / `.github/workflows/second-opinion-gate.yml`（第二意見が回されたことの記録と確認側。`--with-copilot-review` の有無に関わらず配置します。上記「ループコーディング支援」参照）
- `.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml` / `scripts/review-usable.sh` / `scripts/check-review-usable.sh`（`--with-copilot-review` を併せて選択した場合のみ。4 本で 1 組。下記参照）
- `.claude/skills/intake/SKILL.md`（`--with-claude` を併せて指定した場合のみ。intake 起点スキル）
- `.claude/skills/land/SKILL.md`（`--with-claude` を併せて指定した場合のみ。PR 確認・マージ起点スキル）
- `.claude/skills/peers/SKILL.md`（`--with-claude` を併せて指定した場合のみ。ほかのセッションの一覧・送信・一斉送信の呼び出し口。実体は `scripts/session-peers.sh`）
- `.claude/agents/explorer.md` / `.claude/agents/implementer.md`（`--with-claude` を併せて指定した場合のみ。委譲先エージェント定義）

`--with-aws` / `--with-gcp` のいずれかを選択した場合は、加えて次を出力します（規範の配置は前提としません）。

- `scripts/acceptance-remote.sh`（**外部層**の受け入れ条件の雛形。宣言と実際の外部状態の一致を検証する骨格のみ。上記「受け入れ条件の二層」参照）

なお bootstrap.sh は生成先の README.md を読み書きしません。セットアップ手順を README へ追記する処理は持たないため、生成後の README への反映は利用者側の作業です。

#### 生成物の由来の記録（`.devcontainer/ORIGIN`）

装備の選択によらず常に、`.devcontainer/ORIGIN` へ生成物の由来を記録します。目的は 2 つです。

- 生成先で**意図的に改造した**箇所と、**単に古い写し**（上流が直したのに追随できていない箇所）を区別する（`doctor.sh` が使います）。
- 生成の入力と現物のハッシュを残し、`--upgrade` が同じ入力で生成し直して、手を入れていないファイルだけを更新できるようにする（[再実行したときの挙動](#再実行したときの挙動)）。

```
# devcontainer-bootstrap が記録した生成物の由来。
# doctor.sh はこの記録と現物を突き合わせて乖離を診断する。手で編集しないこと。
version=v0.23.6
flags=aws,claude
inputs-format=1
input:project-name=myapp
input:languages=node,python
input:base-image-mode=auto
input:base-image=<生成時に選ばれたイメージ>
input:manage-gitignore=true
input:gitignore-targets=
input:playbook=installed
input:playbook-source=tag
input:playbook-ref=v0.9.1
hash:.devcontainer/compose.yaml=<sha256>
hash:.devcontainer/devcontainer.json=<sha256>
hash:.env.example=<sha256>
...
accepted:.devcontainer/devcontainer.json=<sha256>   # 取り込み済みにしたファイルがあるときだけ
owned:scripts/acceptance.sh=1                        # プロジェクトが所有・編集するファイル
pending:scripts/verify.sh=1                          # .dcb-new が取り込み待ちのときだけ
absent:.devcontainer/compose.yaml=1                  # --absent で意図して置かないと記録したときだけ
```

| キー | 意味 |
|---|---|
| `version` | 生成に使った DCB 自身の版。新しい形式（`inputs-format=1`）では必須 |
| `flags` | 指定した `--with-*` フラグの昇順カンマ区切り一覧（指定順によらず同じ集合なら同じ値。空でも行は書く）。新しい形式では必須。フラグを含めるのは、「`--with-aws` を付け忘れた」と「意図的に外した」を区別するためです |
| `inputs-format` | 入力の記録の書式の版（現在は `1`）。この行があるときだけ `input:` の行を読みます |
| `input:<名前>` | 生成結果を左右する入力（下記）。同じ名前は 1 回だけ。値の `%` `改行` は `%25` `%0A` `%0D` で符号化します |
| `hash:<相対パス>` | その生成物の sha256（`sha256sum` が無い環境では `shasum -a 256`、それも無ければ `openssl dgst -sha256` を使います） |
| `accepted:<相対パス>` | `bootstrap.sh --accept` が記録する、取り込み済みの現物の sha256。取り込み済みにしたファイルがあるときだけ書く（無い ORIGIN も有効）。`doctor.sh` は現物がこの値と一致すれば変化として扱わない。`--upgrade` は引き継ぎ、その回に `.dcb-new` を置いたファイルの分は落とす |
| `owned:<相対パス>` | プロジェクト所有のファイルの印（値は `1`）。生成時と `--upgrade` が、今回の生成対象にあるものへ書く。`doctor.sh` は、`pending:` が無ければ現物が `hash:` と違っても乖離として扱わない |
| `absent:<相対パス>` | `bootstrap.sh --absent` が記録する、意図して置かない生成物の印（値は `1`）。あるときだけ書く（無い ORIGIN も有効）。`--upgrade` は、現物が無く作らなかったパスの分を引き継ぐ。`doctor.sh` は、現物が無ければ欠けていても FAIL にせず、現物があれば FAIL にする。外せない一覧のパスに書かれていれば破損として FAIL にする。この行のパスにも `hash:` は残す |
| `pending:<相対パス>` | `--upgrade` が `.dcb-new` を置いた（取り込み待ち）ファイルの印（値は `1`）。`--accept` か、現物が新しい版と同じになると外れる。あるあいだ `doctor.sh` は FAIL にする。`--upgrade` は、取り込む前に失った `.dcb-new` をこの印で作り直す |

記録する入力と、記録しない入力:

| 入力 | 扱い | 理由 |
|---|---|---|
| `--project-name` / `--languages` | 記録する（`input:project-name` / `input:languages`） | 生成結果を決める必須の入力 |
| `--with-*` | `flags=` に記録する | 同上。`--upgrade` は記録した集合へ、引数で渡した分を足し、`--without-<名前>` で渡した分を外す |
| `--base-image` | 指定の有無（`input:base-image-mode=override` / `auto`）と、そのとき使った値（`input:base-image`）を記録する | `auto` のときの値は、生成時の環境（docker の有無・アーキテクチャ・レジストリの応答）で決まった観測記録で、再現すべき入力ではない。`override` のときだけ `--upgrade` が再現する |
| `--no-gitignore` / `--gitignore-targets` | 記録する（`input:manage-gitignore` / `input:gitignore-targets`） | 生成結果（`.gitignore`）を決める |
| `--second-opinion-engine` | 指定したときだけ記録する（`input:second-opinion-engine`） | 生成結果（`.env.example`）を決める。未指定の ORIGIN には行を足さず、古い ORIGIN にこの行が無くても `--upgrade` は止まらない。値は gemini / antigravity / codex のいずれか（`doctor.sh` が検査する） |
| `--claude-remote-control` | 指定したときだけ `input:claude-remote-control=true` を記録する | 生成結果（`install-ai-tools.sh`）を決める。未指定の ORIGIN には行を足さず、古い ORIGIN にこの行が無くても `--upgrade` は止まらない。値は `true` だけ（`doctor.sh` が検査する） |
| `--no-update-check` | 指定したとき（`--upgrade` で引き継いだときを含む）だけ `input:update-check=off` を記録する | 生成物 `scripts/update-check.sh` が実行時に読む。未指定の ORIGIN には行を足さず、古い ORIGIN にこの行が無くても `--upgrade` は止まらない。値は `off` だけを認め、それ以外は破損として止まる（`--update-check` で外せる） |
| 規範の取得元（`--playbook-version` / `--playbook-from` / `--with-playbook`） | 種類（`input:playbook-source` = `tag` / `url` / `local` / `adjacent`）と、記録できる場合の値（`input:playbook-ref`）を記録する。配置しないときは `input:playbook=none` | `tag` と、`@` `?` `#` を含まない URL だけ値を記録する。ローカルのパスは、絶対パスがコミットされると困り、相対パスは実行した場所で意味が変わるため記録しない。`@` `?` `#` を含む URL は資格情報や署名を含みうるため記録しない（これらは `--upgrade` で `--playbook-from` の明示が要る） |
| `--playbook-conflict-policy` | 記録しない | 既存ファイルへの対処であって、生成結果を決める入力ではない（`--upgrade` は自分の振り分けで決める） |
| `--force` / `--dry-run` / `--upgrade` / `--output-dir` | 記録しない | 実行の仕方であって生成結果を決める入力ではない。出力先の絶対パスも残さない |

- ハッシュの対象は、この実行で生成した DCB 自身のテンプレート一覧（常時生成ぶん・`--with-*` 条件付きぶん）と、規範経由で置くファイル（`.ai-playbook/**` の規範本体と `.ai-playbook/VERSION`、入口ファイル、第二意見のスクリプトなど）です。
- **`.ai-playbook/VERSION` と ORIGIN の役割の分担**: `VERSION` は**規範の取得元**（どのタグ・どのディレクトリから取り込んだか）の記録です。ORIGIN は**生成の入力と現物のハッシュ**の記録です。`VERSION` 自身も、ほかの生成物と同じく ORIGIN にハッシュを記録します（`--upgrade` が手を入れていないかを判定するため）。
- 従来の再実行（`--upgrade` なし）の衝突ポリシーは他の生成物と同じです。**`--force` を付けない再実行では、既存の記録をそのまま温存します。** `--force` を付けた再実行でのみ書き直します。生成物を意図的に直して `--force` で作り直したときは記録も更新され、それ自体が「直した」証跡になります。
- `--upgrade` は ORIGIN を、新しい版の生成結果を基準として書き直します。手を入れたファイルにも新しい版のハッシュを記録し、既存の ORIGIN のモードは変えません。入力の記録が無い古い ORIGIN は、引数を明示した初回の `--upgrade` で新しい形式になります。
- **既知の限界**: 従来の再実行（`--force` なし）では、既に記録がある生成先へ `--with-*` を追加で指定しても、新しく増えた生成物のハッシュは記録に追加されません（ORIGIN 自体が衝突ポリシーに従い温存されるため）。記録に無いファイルを doctor.sh が誤って「変化した」と報告することはありませんが、**診断の対象にも入りません**。構成を足して追従したいときは、`--upgrade --with-*` を使ってください（`--upgrade` は記録した集合へ足して記録し直します）。

由来をどう診断するかは「[Doctor 自己診断](#doctor-自己診断)」を参照してください。

#### マージ確認フック（Claude Code）

`--with-claude` を選ぶと、**マージを実行しようとしたときに確認を挟む** PreToolUse フックを配置します。規範 `.ai-playbook/role-contracts/closer.md` の「既定の merge 方針は手動承認とする」に対応する機構で、規範を配置しない構成でも配線されます（規範パッケージの雛形ではなく DCB 自身のテンプレートです）。

| ファイル | 役割 |
|---|---|
| `scripts/confirm-merge-hook.sh` | フック本体。標準入力の JSON を読み、マージ実行にあたるコマンドなら `permissionDecision: ask` を返します |
| `.claude/settings.json` | 配線。`PreToolUse` の `matcher: "Bash"` から上記を呼びます |

**保証するのは「黙ってマージしない」ことであって、「マージさせない」ことではありません。** 判定は `deny` ではなく `ask` で、承認すればマージは実行されます。指示に従うマージまで塞ぐと「PR を作り、指示を待ち、指示されたらマージする」という運用が成り立たないためです。

検査するのは次の 3 つで、いずれも「文字列に含まれるか」ではなく**実行しようとしているか**で判定します。

| 検査対象 | 条件 |
|---|---|
| `gh pr merge` | **コマンド位置**にあるもの |
| `pulls/<n>/merge` | **かつ `--method PUT` / `-X PUT` を同じコマンド節で指定しているもの。** `--method=PUT`（= 連結）・`-XPUT`（連結形）・`--method put`（小文字）も拾います。GET はマージ済みか調べるだけで状態を変えないため対象外です。「同じコマンド節」は引用符を認識したうえで `;` `&` `\|` `(` `)` で区切った単位です。`echo repos/o/r/pulls/1/merge; gh api --method PUT repos/o/r/issues/1/labels` のように無関係な 2 コマンドが 1 行に連結されただけの形とは区別し、逆に `gh api 'repos/o/r/pulls/1/merge?a=1&b=2' -X PUT` のように URL のクエリ文字列や引用符の中に `;` `&` があっても、そこで分断はしません |
| `mergePullRequest` | **かつ `gh api graphql` から呼ばれているもの** |

単純な部分一致にしていないのは、`grep -rn 'mergePullRequest' .` や `git log -S 'gh pr merge'` まで確認を求めると、**内容を読まずに承認する習慣ができて機構が形だけになる**ためです。

**「コマンド位置」の判定は、クォートを認識するコマンド境界解析 1 つに集約しています。** `;` `&` `\|` `(` `)` と改行を区切り文字として、引用符（`'...'` と `"..."`、二重引用符内のエスケープ）を認識しながら文字単位で単純コマンドへ分解し、期待する語列（`gh pr merge` 等）と完全一致するかを見ます。変数展開・コマンド置換・here-document・サブシェルの深さは解析しません。bash の文法を完全に実装すると雛形として重くなりすぎるため、範囲を絞っています。

**シェルの制御語（`if` / `elif` / `while` / `until` / `then` / `do` / `else`、否定の `!`）と環境変数代入（`FOO=bar`）の直後もコマンド位置として扱います。** 区切り文字の直後という条件だけでは、`if gh pr merge 1; then :; fi` のように制御語を 1 つ前置くだけで素通りしていました（実測。`else` も同様に漏れていました）。

**制御語と環境変数代入は、クォートの扱いが違うため判定条件も分けています。** 制御語の判定は、その語がクォートやバックスラッシュエスケープを 1 文字も含まないときだけ行います。`'if' gh pr merge 1` は「`if` という名前のコマンドを実行する入力」であり `gh` は実行されないため、クォートを剥がした語で予約語判定をすると誤って確認を求めてしまいます（実測）。**環境変数代入の判定は逆に、`name=` の部分にクォートが挟まっていないことだけを見て、値側のクォートは問いません。** `VAR="foo" gh pr merge 1` や `KEY='bar' gh pr merge 1` は値側だけがクォートされた代入で、実際に `gh` がコマンド位置に来ます（実測: `env` で代入として効くことを確認）。制御語と同じ「語にクォートが 1 文字でもあれば読み飛ばさない」を代入にも適用すると、この 2 例を取りこぼして素通りしてしまいます（実測。解析をクォート認識の走査 1 つへ一本化した際に、クォートを見ない `grep` 側のフォールバックが失われたことで露見した退行です）。逆に `"VAR"=foo gh pr merge 1` のように `name` 側にクォートが挟まっている形は、bash 上そもそも代入にならず `"VAR"=foo` という名前のコマンドを探しにいくため（実測）、代入としては読み飛ばしません。

**かつては、この判定を「制御語などを前置きとして列挙した、クォートを認識しない正規表現」と「クォート認識の解析」の 2 つの独立した経路の OR で行っていました。** OR で結ぶ限り、クォートを見ない側だけが起こす誤検知は構造として避けられませんでした。`'if' gh pr merge 1` を予約語 `if` の直後と誤認し、`echo "x; gh pr merge 1"`（二重引用符の中の `;`）を区切り文字と誤認して、どちらも確認を求めていました（実測）。走査をクォート認識の解析 1 つへ集約し、この種の食い違いを構造として作れないようにしています。制御語の列挙自体は消しておらず、解析の中（節の語から制御語・代入の繰り返しを読み飛ばす処理）が唯一の置き場所です。

**節の切り出し（コマンド節・上記の単純コマンド分解）は 1 つの走査に集約しています。** かつては REST 判定側の節分割だけを別に実装しており、そちらはクォートを見ずに `;` `&` `\|` を機械的に区切りへ変えていました。結果、引用符の中身や URL のクエリ文字列に現れる `;` `&` `\|` まで区切りとして扱ってしまい、PUT の指定と `merge` エンドポイントが別々の節へ分断されて検知できなくなっていました（実測）。**誤検知を直すために入れた処理そのものが新しい迂回を作っていた形です。** 修正では、節を切り出す走査そのものを 1 つの関数へ集約し、語の完全一致判定と PUT / エンドポイントの正規表現判定の両方がそこから同じ節を受け取るようにしています。

**`{`（グループコマンド）は、その節が「環境変数代入と制御語だけ」で説明できる（＝実コマンドの語をまだ 1 つも集めていない）ときだけ、グループコマンドの開始として読み飛ばします。** `echo hi { gh pr merge 1`（`{` 以降も直前のコマンドの引数でしかなく、実際には実行されない）のような無害な文字列までは拾いません（実測）。かつては「節でまだ語を 1 つも集めていない」だけを条件にしていたため、`if { gh pr merge 1; }; then :; fi` のように制御語を 1 つ前置くだけで `{` が語として残り、解析が `gh pr merge` へ到達できずに素通りしていました（実測）。`case` / `esac` / `fi` / `done` / `}` は追加していません。これらは必ず直後に区切り文字（`;` か改行）を要求する構文で、既存の区切り文字判定がそのまま効くためです。`in`（`for` / `case` で使う語）も追加していません。`for x in gh pr merge 1; do ...; done` の `gh pr merge 1` は `for` が変数へ順に代入する値であって実行されるコマンドではなく、この節の先頭の語は `for` のままなので `gh pr merge` との一致は生じません（実測）。

**解析は bash の文法を全部実装したものではなく部分実装であり、取りこぼしえます。** 「迂回できない」とは書きません。JSON から `tool_input.command` を取り出せなかった場合（ペイロード全体を検査対象にしているとき）は、この解析を使いません。ペイロード全体はシェルの行ではなく JSON テキストであり、位置を解析する土台が無いためです。この場合は位置を問わない語の並び照合へ落とし、確認を増やす側へ振ります。

**この解析（`for_each_clause` 以下）は、bash の字句解析（トークナイザ）を部分的に再現したものです。** ここまでに、少なくとも次の境界事例が、いずれも実際にこの解析へ入力してから見つかっています。（1）コマンド位置の判定を列挙とクォート認識の解析の二重化にしていたことに起因する誤検知、（2）環境変数代入の判定に予約語と同じクォート条件を適用していたことによる迂回、（3）空クォート（`''` / `""`）を語として数え損ねていたことによる迂回・誤検知。いずれも「新しく入れた処理が別の経路で穴を作っていないか」という観点の変異テストをかけて初めて見つかりました。**bash の字句規則を部分的に再実装する以上、境界事例は今後も見つかりうるという意味です。「境界事例を網羅した」とは書きません。** 見つかった形はそのつど実測し、塞いで、テストへ固定する運用を前提にしています。

**`.claude/settings.json` の `permissions.ask` では代替できません。** `allow` / `ask` / `deny` はコマンド名と引数文字列の**前方一致**で判定するため、次を表現できません（実測値は無害な `echo` で確認しています）。

- **同じ操作の別経路**: `gh pr merge` を対象にした規則は `gh api --method PUT .../pulls/1/merge` にも `gh api graphql` の `mergePullRequest` にも一致しません。`gh api` ごと対象にすると、状態を変えない GET まで確認を求めます。
- **引数の位置に依らない判定**: `--method PUT` が引数の途中や末尾へ来る綴りは捕捉できません（実測: `deny` 規則 `Bash(echo --method PUT:*)` は `echo --method PUT repos/o/r/pulls/1/merge` を止めますが、`echo repos/o/r/pulls/1/merge --method PUT` は素通りします）。

> **既知の限界**: これは「うっかり実行」に確認を挟む guardrail であり、**意図的な迂回を防ぐ security boundary ではありません。** 文字列照合である以上、書き方を変えれば抜けられます。`gh -R owner/repo pr merge`（`gh` とサブコマンドの間にオプションが挟まる形）/ `/usr/bin/gh pr merge`（絶対パス起動）/ `env gh pr merge`（プレフィックス）/ `bash -c "gh pr merge 1"`（引用符の内側）/ `gh api .../pulls/$N/merge`（URL の変数展開）/ `gh api graphql -F query=@q.gql`（クエリを外部ファイルから読む形）はいずれも通ります。**塞ぐたびに新しい書き方が見つかるため完全性は達成できません。** 完全であるかのように書くと実態より強い保証があると誤認させるため、限界をそのまま記録しています。なお `gh api -XPUT` / `--method=PUT` / 小文字 `put` は、意図的な迂回ではなく普通の綴りにあたるため既知の限界には含めず、上の判定が拾います。

> **副作用**: マージコマンドに見える文字列を**行頭に含む**コミットメッセージやテストは、そのままでは実行できず確認を求められます。`git commit -F <file>` のようにファイル経由で渡すか、テストスクリプトへ書き出して実行すれば回避できます。引用符の内側（`grep 'gh pr merge'`）は元から通ります。

> **`main` への直接 push は扱いません。** ブランチ保護がサーバ側で拒否するほうが確実で、ブランチ名に `main` を含む feature ブランチへの push を誤って止める副作用も避けられるためです。

> **`jq` が無くても検査を飛ばしません。** コマンドを取り出せない場合（`jq` 不在・壊れた JSON・将来のペイロード変更）はペイロード全体を検査対象にします。「取れなければ通す」にすると検査が黙って無効化され、**このフックが防ごうとしている「気づかないまま実行できる」状態そのものを再現する**ためです。出力側も同じ理由で `printf` のフォールバックを持ちます。

**`gh pr merge` をコマンド位置で検知したときは、squash マージの本文になるテキストに CI 抑止の綴りが無いかも見て、見つかれば理由へ添えます。** deny にはしません（上と同じく「黙ってマージしない」ことだけを保証する guardrail です）。ある事例では、この綴りは指示として書かれたのではなく「この検査がコミットメッセージしか見ていないこと」を説明する文章の中にありました。GitHub は見出しでなく本文のどこにあっても従うため、検知は行の先頭や見出しの形には絞りません。

squash 本文の組み立て方（PR の説明文だけを使うか、各コミットのメッセージを連ねるか）はリポジトリの設定（`squash_merge_commit_message`）によります。配布物なので特定の設定を前提にせず、**設定を読んで検査対象を切り替えることもしません。** 判定を 2 経路に分けるほど、どちらかの経路だけが古くなる余地が増えるためです。代わりに、**設定によらず両方（PR 本文と全コミットメッセージ）を常に見ます。** 綴りの一覧は、squash 前に人手でも同じ判定を行う `land` スキルの対応する手順と同じものを使い、このフックだけの独自の一覧は持ちません（一致は配布物側のテストで検査します）。

**`--body` / `--subject` に明示された文字列も見ます。** これらは最終的な squash 本文を CLI 側で直接差し替えるものであり、リモートの PR 本文が綺麗でも、渡された文面に綴りがあれば CI は飛びます。squash 前の人手の回復手順（`land` スキル）は「該当行が出たら、その指示を除いた本文をファイルに書き、`--body-file` で差し替えてマージする」と定めており、`--body` 系を見ないと**この回復手順そのものが検査をすり抜ける経路になります。** `--body` / `--subject` の値を見た上でも、リモートの PR 本文・コミットメッセージは別途見ます（`--body` 等がどこまで上書きするかを完全には前提にしないため。安全側にしか働きません）。

> **`--body-file` の中身は読みません。** このフックはコマンドの実行前に走るため、同じコマンド内で（`echo ... > file && gh pr merge ... --body-file file` のように）これから書かれるファイルを正しく読める保証が無く、cwd の想定もフック側とコマンド側で揃うとは限りません。読まないと決めた以上、その対象は**「綴りが無い」とは扱わず、確認できていない（`unavailable`）扱いにします。**

**1 つのコマンド文字列に `gh pr merge` が複数回現れる場合（例: `gh pr merge 1 && gh pr merge 2`）は、全対象を集約して見ます。** 片方だけを見て判定を確定させると、確認 1 回で残りの対象が未検査のまま実行されてしまうためです。複数の対象・複数の情報源（`--body` / `--subject` / リモートの本文・コミット）を見た結果は、`found`（綴りあり）＞ `unavailable`（確認できていない）＞ `clean`（綴りなし）の優先順位で 1 つに集約します。

> **判定できなかったときは「綴りが無い」と扱いません。** `gh` コマンドが無い・PR 情報を取得できない・コマンド文字列を取り出せていない（`jq` 不在や壊れた JSON でペイロード全体を検査対象にしているとき）・`--body-file` の中身を読んでいない、のいずれでも、確認できていないことをそのまま理由へ書きます。読めなかったことを合格にはしない、という上の「`jq` が無くても検査を飛ばしません」と同じ方針です。

> **`gh pr merge` 以外（REST の `PUT` / `gh api graphql` の `mergePullRequest`）には、この検査を広げていません。** REST 経由の URL は変数展開を含む形が普通にあり（上の「既知の限界」参照）、PR 番号やリポジトリをそこから安全に取り出せる保証が無いためです。誤って別の PR の本文を見にいくほうが、確認しないより悪いと判断しました。これらの経路でも既存の `ask` 自体は変わらず働きます。

> **他の実行環境へ一般化できるか**: 現時点ではできません。`.claude/settings.json` の `PreToolUse` は Claude Code 固有の機構で、`--with-gemini` / `--with-copilot` に同等の「ツール実行前に判定を差し込む」配線がありません。フック本体（`scripts/confirm-merge-hook.sh`）は標準入力の JSON を読んで標準出力へ判定を返すだけなので、同種の機構を持つ実行環境が現れたら**配線だけを足せば再利用できます。** 判定ロジックを実行環境ごとに複製しない形にしてあります。

#### セッション協調フック（Claude Code）

`--with-claude` を選ぶと、**並行して動く別のセッションとの衝突を、操作の直前に確かめる**フックを配置します（規範は `.ai-playbook/shared-ai-rules.md`「セッション間の協調」。規範を配置しない構成でも配線されます）。台帳の読み書きと衝突の判定は、装備フラグに関わらず生成する `scripts/session-ledger.sh` が担い、このフックは「いつ確かめるか」と「Claude Code へどう返すか」だけを持ちます。

| ファイル | 役割 |
|---|---|
| `scripts/session-coord-hook.sh` | フック本体。標準入力の JSON を読み、台帳へ登録・確認して、標準出力の JSON で拒否（`deny`）や警告（`additionalContext` と `systemMessage`）を返します |
| `.claude/settings.json` | 配線。下表のイベントから上記を呼びます |

| イベント | 対象 | 判定 |
|---|---|---|
| `SessionStart` | — | 他のセッションの登録を要約して表示する（他に登録が無ければ何も出さない） |
| `PreToolUse` | `Bash` | `gh pr merge` / `gh release create`・`edit`・`delete`・`upload` / REST の merge への `PUT` / `mergePullRequest`、同じ作業ツリーでの `git checkout`・`switch`・`rebase`・`reset`・`fetch`・`pull`・`merge` や、index を変える `add`・`commit`・`rm`・`mv` など、`verify.sh` / `loop-gate.sh` の起動を、他のセッションの登録と衝突するなら**拒否**する。ブランチ作成（`git checkout -b feat/395-…` など）で、他のセッションが着手している issue なら**警告**する |
| `PreToolUse` | `Edit\|Write` | 他のセッションが登録している文書なら**警告**する（通す） |
| `PostToolUse` / `PostToolUseFailure` | `Bash` | `PreToolUse` で登録した「実行のあいだだけの登録」（マージ・作業ツリー・ゲート）を解放する。終了コードが 0 以外の呼び出しや中断は `PostToolUse` ではなく `PostToolUseFailure` が来るため、両方へ配線する |
| `SessionEnd` | — | 自分の登録をすべて解放する |

- **拒否と警告の出力に、相手のセッションの識別子・登録の種類・作業ツリー・調整の手順が含まれます。** 調整は、Claude Code では `ListAgents` で相手を確かめて `SendMessage` で連絡します（他の実行環境では利用者を経由します）。
- **フックが自分で登録する時点:** マージ・作業ツリーの git 操作・重いゲートは、実行の直前に登録し、終わったら解放します（登録と解放には、その呼び出しの `tool_use_id` を呼び出しの識別子として渡し、解放はその識別子の登録だけを外します。同じセッションで同じ種類の Bash 呼び出しが並行しても、先に終わった方が他方の登録を外さず、複合コマンドが拒否されたときも、同じセッションの先行する登録は残ります。`tool_use_id` が入力に無いときは、識別子なしで種類と対象の単位で扱います）。issue はブランチ作成の時点で登録し、`SessionEnd` まで持ちます。文書は、フックは確かめるだけで登録しません（長く触る文書は、セッション自身が `session-ledger.sh claim doc <パス>` で登録します）。拒否したときは、その呼び出しで登録したものを解放してから拒否します（issue は、拒否しないと決まってから登録します）。**限界:** 確認（`ask`）を利用者が断った場合は `PostToolUse` も `PostToolUseFailure` も来ないため、セッションが終わるか、持ち主のプロセスが消えるか、その登録の時刻から失効する（既定 8 時間。`refresh` では延びません）まで登録が残ります。バックグラウンドで起動したゲートは、起動の呼び出しが返った時点で解放されます。**限界:** 台帳はタブ区切り、登録の対象と解放の一覧は改行区切りなので、タブか改行を含むパスは 1 つの値として持てません。守るのは「危険なパスを台帳の欄に書かない」ことだけで、作業ディレクトリが危険だからといってフックが何もしなくなることはありません。パスを持たない種類（merge・gate・issue）は、作業ディレクトリが危険でも従来どおり確かめて登録し、拒否も効きます（台帳は作業ツリーの欄に `-` を書きます）。危険かどうかは、台帳の欄へ書く値（解決した作業ツリーのルート・文書のパス）で判定します。安全なリポジトリの中の危険なサブディレクトリにいるだけでは止めません。フックは、`git` の操作の作業ツリー（`cd` 先・`git -C` 先を含む。絶対パスの `-C` は基準のディレクトリに依存せず、その先だけで判定します）と、作るブランチの控えの値を、解決した結果（末尾の改行を削らずに取り出した値。シンボリックリンクの先を含む）で判定し、危険なものは登録せず、警告を 1 行出して通します（作るブランチの控えは番号だけの印になります）。文書の確認は `file_path` 自体で判定します。解放の経路（`PostToolUse` / `PostToolUseFailure` / `SessionEnd`）は、作業ディレクトリが危険でも続けます。登録した台帳の控え（フックの一時ファイルの印）は、危険な作業ディレクトリも符号化して持つため、コマンドの `cd` で `PostToolUse` の作業ディレクトリが変わっても、登録した台帳から解放します。`session-ledger.sh` は、対象の欄へ来るパス（`git` の作業ツリー・文書のパス・`release '*' <対象>` の対象）が正規化の前後（シンボリックリンクの先を含む）で危険なとき、書き込まずに `LEDGER_SKIP`（警告を出し、終了コード 0。2 行目に理由の印 `reason: unsafe-path` を出します）で通します。危険なパスを持つ作業ツリーそのものや、危険なパスの文書では協調が働きません（台帳の欄にはパスを符号化して書くことはしません。符号化するのは、フックの一時ファイルの印だけです）。
- **セッションの識別子は台帳の既定に任せます。** フックも `Bash` ツールのコマンドも Claude Code 本体のプロセスの子として動くため、「祖先で最初のシェル以外のプロセス」が同じ本体になり、識別子が揃います（実機で確認済み）。`SESSION_LEDGER_ID` / `SESSION_LEDGER_PID` を渡せば、それが優先されます。
- **長いセッションの失効を避けるため、`PreToolUse` のたびに `session-ledger.sh refresh` を呼びます**（前回の更新から 5 分以上たっていなければ何もしません）。延ばすのは issue と文書の登録の失効だけで、マージ・git 操作・重いゲートの登録は延ばしません。実行のあいだだけ持つはずの登録を、解放し損ねたまま生かし続けないためです。
- **台帳そのものの読み書きに失敗したときは、警告（`systemMessage`）を出して通します（fail-open）。** 台帳が見つからない・置き場所を作れない・git リポジトリの外・出力を読めない場合です。台帳の不具合ですべての操作が止まるのを避けるためで、空のペイロードを `ask` にする確認フックとは逆です（あちらは承認の記録が目的で、こちらは合図だからです）。
- コマンドの見分け方は確認フックと同じ考え方（クォートを認識して節に分け、節の先頭のコマンドで判定する）の縮小版です。`bash -c "..."` の中身や変数展開の結果などは取りこぼします。**うっかりの衝突へ合図を出す機構であって、意図的な迂回を防ぐ境界ではありません。**
- 台帳は排他制御ではなく合図です。2 つのセッションがほぼ同時に登録すると、両方が通ることがあります。

**既存の `.claude/settings.json` がある場合**は、衝突ポリシー（既定 `skip`）で温存されるため配線は足されません。次の `hooks` を手で足してください（`confirm-merge-hook.sh` の配線がある場合は、`PreToolUse` の `Bash` の `hooks` へ 2 つ目のコマンドとして足します）。追跡している設定を書き換えることになるため、足してよいかは先に確かめてください（この開発リポジトリは、確認のうえで配線済みです）。

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }] }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/confirm-merge-hook.sh\"" },
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }]
      }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }] }
    ],
    "PostToolUseFailure": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/session-coord-hook.sh\"" }] }
    ]
  }
}
```

同梱の `/intake` と `/land` のスキル雛形は、着手のとき（`session-ledger.sh claim issue <番号>`）、マージの前（`check merge`）、作業の終わり（`release`）に台帳を使う手順を持ちます。

#### リモート最終ゲート（Copilot）ワークフロー
規範を配置し、かつ `--with-copilot-review` を選択した場合のみ、**要求側・確認側・確認側が使う判定スクリプト 2 本**を配置します（規範 `.ai-playbook/review-workflow.md`「リモート最終ゲート」に対応）。

このフラグはリモート側だけを担い、ローカルの装備（CLI・拡張・`~/.copilot` の永続化）は入れません。ローカルの装備が必要なら `--with-copilot` を併せて指定します。逆に `--with-copilot` だけを指定した構成では、これらのワークフローは配置されません。

| ファイル | 役割 |
|---|---|
| `.github/workflows/copilot-review.yml` | **要求側。** PR 作成時（`pull_request: types: [opened]`）に一度だけ Copilot へコードレビューを要求します。`synchronize`（push 更新）では再要求しないため「1 回だけ」を機構で保証します |
| `.github/workflows/review-gate.yml` | **確認側。** 要求されたこと、および要求・投稿されたレビューが実際に読まれたことを、別の契機から確認します。要求はしません |
| `scripts/review-usable.sh` | 確認側が使う判定本体。「投稿されたレビューが実際に読めたか」を標準入力で受け、終了コードと合図で返します |
| `scripts/check-review-usable.sh` | 上記の判定を表で確かめる自己検査。GitHub 上でしか動かない `review-gate.yml` に判定を埋めず、手元と CI の両方で機械的に確かめられるようにするための対です |

要求側は、フォークからの PR をスキップします。既定の `GITHUB_TOKEN` で要求できない構成では、リポジトリ Secrets に `COPILOT_REVIEW_TOKEN`（`pull-requests` 書き込み権限を持つ PAT）を設定すると自動で切り替わります。**要求は間欠的に空レスポンスで失敗することがあり**、同じジョブの中で 5→10→20 秒の指数バックオフにより計 4 回まで再試行します（再試行はこの 1 ジョブの中で閉じており、別のイベントから要求し直す形にはしません。「1 回だけ要求する」の対象は要求が別の契機から重ねて出ることです）。再試行を尽くしても失敗した場合は、切り分け手順を `::error::` で出力して実行を落とします（握り潰してスキップにはしません。リモート最終ゲートが実行されていないのに緑を出すと、偽の緑と通過の区別が付かなくなるためです）。

確認側を別に置くのは、**要求側の契機が届かないことがある**ためです。届かなければ要求側は起動せず、エラーも出ず、他のチェックは緑なので、最終ゲートだけが黙って抜けます。同じ契機を見る 2 本目では塞げないため、確認側は `opened` / `synchronize` / `reopened` / `ready_for_review` に加えて**手動実行（`workflow_dispatch`）**を持ち、`/land` がマージの直前に既定ブランチで起こして再判定します（定期実行は置きません。PR が無いあいだも走り続け、private リポジトリの課金枠を減らし続けるため）。判定は head SHA への commit status（`review-gate`）として出します。手動実行から見た PR にはジョブの成否が紐づかず、status でなければ PR 上に何も現れないためです。`opened` の契機だけは、要求が届くまで 120 秒待ってから判定します（要求側と同時に走るため）。

**「要求されたか」と「読まれたか」は別です。** GitHub は 1 ファイルの差分が大きすぎると、レビュー対象の差分（`patch`）を API から落とします。この状態でも Copilot は要求どおりレビューを投稿しますが、中身は「1 行も読めなかった」という定型文だけになり、要求も投稿も記録として残るため、「要求されたか」しか見ない判定は緑を出し続けます。確認側はこれを塞ぐため、変更ファイルに読める差分があるか（原因そのもの）と、投稿されたレビューが定型文だけでないか（最後の砦）の 2 段で見ます。この判定は `review-gate.yml` へ埋め込まず `scripts/review-usable.sh` へ切り出してあります。確認側は `actions/checkout@v7` で**既定ブランチ**（PR の変更ブランチではありません）からこのスクリプトを取得してから呼び出します。PR 側から取得すると、PR の投稿者がスクリプトを書き換えるだけでゲートを常に緑にできてしまうためです。

> **前提**: リポジトリ所有者の Copilot サブスクリプションで「Copilot code review」が有効でないと、reviewers 要求が 422 で失敗します。`--with-copilot-review` を指定しなければ、これらのワークフローとスクリプトは配置されません（他ベンダーのリモートレビューを使う場合は強制されません）。

> **注意**: `--with-copilot-review` は規範の配置を前提とします。雛形の正本は規範パッケージにあり、DCB は配置先を決めるだけだからです。規範を配置しない構成で指定すると、**ファイルを 1 つも書かずに**エラー終了します（生成物を途中まで書いてから止まると、中途半端な状態の切り分けが必要になるためです）。

> **注意**: `review-gate.yml` は required check にしないでください。Copilot 側の遅延や障害でマージが止まる副作用があるためです。ここで止めたいのは「要求されていないことに気づかないまま通ること」だけです。

### `.gitignore` と github/gitignore の連携
- managed セクションはマーカー行で挟んだ区間だけを差し替え、セクション外の行は保持します。中身は **github/gitignore から取得したテンプレート**と、その後ろに続く **`--with-*` 連動の除外**の 2 部構成です。
- 暗黙ターゲットは `macOS` + `--languages` で指定した言語対応テンプレート（`node`→`Node` / `go`→`Go` / `python`→`Python` / `php`→`PHP` / `rust`→`Rust` / `ruby`→`Ruby`）です。
- `--gitignore-targets <csv>` を指定すると、暗黙ターゲットに追加で合成します（重複は除去）。
- テンプレート取得は `https://github.com/github/gitignore` から行います（`<name>.gitignore` と `Global/<name>.gitignore` を順に探索）。
- 取得できないテンプレート名は警告を出してスキップします（処理は継続）。

> **注意**: `--languages` の値は小文字（`node`, `go`, `python`, `php`, `rust`, `ruby`）で指定します。一方 `--gitignore-targets` の値は [github/gitignore](https://github.com/github/gitignore) リポジトリのファイル名に合わせた大文字始まり（`Node`, `Go`, `PHP`, `Rust`, `Ruby`, `macOS` など）で指定してください。これらは別々の用途を持つため、意図的に表記が異なります。

#### `--with-*` 連動の除外（`# devcontainer-bootstrap owned ignores`）

github/gitignore のテンプレートは言語・OS・エディタの生成物だけを対象としており、**装備フラグで入れたツールが作るファイルは含みません。** 入れた側が後始末を持たないと各プロジェクトが同じ行を手書きすることになり、書き漏らしがそのまま機密の混入になります。そのため、選択した装備に応じた除外を DCB 自身が管理セクションへ書き出します。

**装備を選ばなかった構成へは 1 行も出しません**（使わない除外を配ると、その行が何のためにあるのか判断できなくなるため）。github/gitignore ブロックより後ろへ置くのは、`.gitignore` が後に書いた行を優先するため、テンプレート側の再包含（`!` 行）で除外が打ち消されない順序にするためです。

| 条件 | 除外するもの | 理由 |
|---|---|---|
| `--with-claude` | `.mcp.json` | プロジェクトスコープの MCP 設定。トークン方式の MCP サーバを追加すると**平文の資格情報がここへ入る**ため、`.env` と同じ扱いにします |
| `--with-claude` | `.claude/worktrees/` | 中身はリポジトリ全体のチェックアウトそのもので、除外しないと `git add .` で**リポジトリが自分自身を抱え込みます** |
| `--with-aws` / `--with-gcp` | `**/.terraform/*` / `*.tfstate` / `*.tfstate.*` / `*.tfvars` / `*.tfvars.json` / `tfplan` / `*.tfplan` / `crash.log` / `crash.*.log` / `override.tf` 系 / `.terraformrc` / `terraform.rc` | **tfstate は機密を平文で保持します。** tfvars も同様に機密を含みやすく、plan の出力は**変数の値が解決済みで展開される**ため state / tfvars と同じ理由で機密が載ります（`-out=tfplan` が慣用のため、拡張子なしと `*.tfplan` の両方を書きます） |

> **`.claude/` はディレクトリごと除外しません。** `.claude/skills/` には追跡する成果物（intake 起点スキル・land 起点スキル）が入るため、`.claude/worktrees/` だけを除外します。

> **`.terraform.lock.hcl` は追跡します。** プロバイダ版の固定に必要なため、意図して除外していません（管理セクション内にもその旨のコメントを出力します）。

> **`.claude/settings.local.json`** は管理セクションでは扱いません。`--with-claude` が配る **`.claude/.gitignore`** がこの 1 行を持ちます。`.claude/` の中で閉じる除外は `.claude/` を配る側の責務とし、同じ除外を 2 か所に持たないためです（2 か所にあると、片方だけ直したときにどちらが効いているのか読めなくなります）。`settings.local.json` には対話中に許可した操作の一覧が入るため、追跡すると**その場の判断で許可した強い操作が clone した全員へ配られます。**

> **既存プロジェクトへの影響**: 管理セクションは再実行で丸ごと置換されるため、再生成するとこれらの行が入ります。セクション外へ手書きしていた同じ内容の行はそのまま残りますが、`.gitignore` の重複は無害です。**なお `.gitignore` は既に追跡済みのファイルを追跡対象から外しません。** 既にコミットされている場合は `git rm --cached` が別途必要です。

> **セクションの外の行は、位置と順序を保ちます。** 管理セクションがあれば、その場所で中身だけを差し替えます（`--upgrade`・再実行・`--force` のいずれも同じ）。セクションの前にあった行は前に、後ろにあった行は後ろに残ります。`.gitignore` は後勝ちで、否定パターン（`!name`）の効き方は行の位置で変わるためです。セクションが無い `.gitignore` には、空行 1 行を挟んで末尾へ足します。
>
> **開始行だけ、または終了行だけが残った `.gitignore` は、書き込みの前に検出して止まります**（終了コード 1。`--dry-run` でも同じで、`.gitignore` もほかの生成物も書きません）。どこまでがセクションか決められず、黙って消すと利用側の行を失うためです。壊れた行を消すか、足りない行を補ってください。セクションに触れないなら `--no-gitignore` を指定します。

### 生成されるスクリプトの分類（そのまま配布 / 生成時に展開）

`scripts/*.sh` の正本は `bootstrap.sh` の `get_template_content()` 内のヒアドキュメントです。テンプレートは**そのまま書き出されるもの**と、**生成時に構成へ応じて展開されるもの**の 2 種類に分かれます。生成先で内容が食い違って見えたときに、追随漏れなのか設計どおりなのかを判別できるよう、分類を明示します。

| テンプレート | 生成時の扱い | 展開されるもの |
|---|---|---|
| `scripts/check-control-chars.sh` | そのまま書き出す | — |
| `scripts/check-deps-installed.sh` | そのまま書き出す | —（`--languages` に `node` を含めたときだけ生成） |
| `scripts/check-doc-links.sh` | そのまま書き出す | — |
| `scripts/check-no-secrets.sh` | そのまま書き出す | — |
| `scripts/check-shell-portability.sh` | そのまま書き出す | — |
| `scripts/check-table-breaks.sh` | そのまま書き出す | — |
| `scripts/confirm-merge-hook.sh` | そのまま書き出す | —（`--with-claude` のときだけ生成） |
| `scripts/load-project-env.sh` | そのまま書き出す | — |
| `scripts/loop-gate.sh` | そのまま書き出す | — |
| `scripts/on-attach.sh` | そのまま書き出す | — |
| `scripts/session-coord-hook.sh` | そのまま書き出す | —（`--with-claude` のときだけ生成） |
| `scripts/session-ledger.sh` | そのまま書き出す | — |
| `scripts/update-check.sh` | そのまま書き出す | — |
| `scripts/session-peers.sh` | そのまま書き出す | —（`--with-claude` のときだけ生成） |
| `scripts/claude-session-wrapper.sh` | そのまま書き出す | —（`--with-claude` のときだけ生成） |
| `scripts/setup-git-identity.sh` | そのまま書き出す | — |
| `scripts/verify-commit-identity.sh` | そのまま書き出す | — |
| `scripts/verify-commit-identity-selftest.sh` | そのまま書き出す | — |
| `scripts/verify.sh` | そのまま書き出す | — |
| `scripts/acceptance-remote.sh` | そのまま書き出す（`--with-aws` / `--with-gcp` 選択時のみ配置） | — |
| `scripts/acceptance.sh` | 生成時に展開 | 選択言語のマニフェストに応じた検証行。**生成後はプロジェクトが所有・編集します** |
| `scripts/fix-mount-owner.sh` | 生成時に展開 | `--with-*` で配線した永続 volume のマウント先 |
| `scripts/install-ai-tools.sh` | 生成時に展開 | `--with-<ai>` で選んだ AI CLI の導入行 |
| `scripts/post-rebuild-check.sh` | 生成時に展開 | 永続 volume の実マウント検査、選択言語ランタイム、選択装備の CLI |

- **「そのまま書き出す」側は、生成先で編集しないことを想定しています。** `--force` を付けて再実行するとテンプレートの内容へ戻ります（[再実行したときの挙動](#再実行したときの挙動)）。恒久的に変えたい場合はテンプレート側を直してください。
- **「生成時に展開」側は、生成後にプロジェクトが手を入れる前提です。** とくに `scripts/acceptance.sh` は雛形であり、プロジェクトの実態（テスト・ビルド・lint・E2E）へ合わせて書き換えることを想定しています。

- **配置されるかどうかは、この 2 分類とは別軸です。** `scripts/acceptance-remote.sh` は展開を持たない（そのまま書き出す）一方で、配置は `--with-aws` / `--with-gcp` の選択に従います。

この開発リポジトリ自身も DCB の生成物を取り込んで使っており、`scripts/` はテンプレートの写しにあたります。上表のうち**写しを持つもの**は、正本と写しがバイト一致していることを `tests/test-template-mirror.sh` の `MIRRORED_RELS` が機械照合します（片方だけ直しても両方のテストが緑になり、配布物と手元が黙って食い違うため）。**対象をここへ書き並べません。** 書き並べると、写しを 1 本足すたびにこの文章だけが古い本数を言い続けます（`.ai-playbook/shared-ai-rules.md` 12 章「一覧の複製は機械照合で担保する」）。現在の対象は `tests/test-template-mirror.sh` の `MIRRORED_RELS` を参照してください。「生成時に展開」側はプレースホルダを持ち一致し得ないので検査対象外（`EXCLUDED_RELS`）です。`scripts/acceptance-remote.sh` も検査対象外ですが理由が異なり、**この開発リポジトリが写しを持たない**（cloud 装備を使わないため）ので比べる相手がありません（`EXCLUDED_NO_COPY_RELS`）。いずれも判断と理由を同テストのコメントに残し、写しを置いた時点で一致必須へ移す判断が要ることも機械で担保しています（「検査していない」と「検査対象外と判断した」を読み分けられるようにするため）。

`scripts/confirm-merge-hook.sh` を一致必須の対象へ加えた経緯は、後から写しを足す判断がどう起きるかの一例です。かつてこの開発リポジトリは `.claude/settings.json` を追跡せず、フックを配線できないため写しも置いていませんでした（写しだけを置くと、誰も起動しないスクリプトが `scripts/` とカタログに並ぶためです）。**その後、許可リストを `.claude/settings.local.json` へ分離し、`settings.json` をフックの配線だけにして追跡へ切り替えたため、配線できない理由は成立しなくなりました。** 同テストのコメントが「配線を入れる判断をしたときは写しを置いて一致必須へ移すこと」を要求しており、その手順どおりに移しています。`scripts/check-control-chars.sh` / `scripts/check-table-breaks.sh` / `scripts/check-shell-portability.sh` は、判定がプレースホルダを持たず生成条件に依らず全構成で同一であるため、最初から一致必須の対象として加えています。**移植性の検査はさらに、自分自身を走査対象に含めます**——正本と写しがずれると、同じツリーに対して片方だけが赤くなる形で矛盾するため、一致必須である必要が他の 2 本より強くあります。

この開発リポジトリは `.claude/` 配下の写し（スキル定義・サブエージェント定義）も持ちます。こちらは `tests/test-claude-mirror.sh` が雛形とのバイト一致を照合します。**`scripts/` に照合があって `.claude/` に無かったあいだ、実際に 3 件がドリフトしていました。**

## 新しい版の確認と追従（update-check）

生成した環境が、DCB と ai-playbook の古い版のまま気づかずに使われ続けないようにする仕組みです。生成物の `scripts/update-check.sh` が担い、**既定で有効**です（既存の利用者は次の `--upgrade` から）。

- **確認:** 接続時（`postAttachCommand` の `scripts/on-attach.sh`）に、ORIGIN の版を GitHub の最新の安定版（DCB は `releases/latest`。プレリリースを除く。ai-playbook は Release を作らずタグだけを打つため、タグの一覧（`/repos/<owner>/ai-playbook/tags`。100 件ずつ。100 件未満のページが来るまで、上限 10 ページ）のうち `vX.Y.Z` の形（プレリリースの形を除く）の最大。認証なし）と比べ、新しければ通知を 1 行だけ出します。聞きません。`on-attach.sh` は端末の入力を受けられないためです。
- **聞く:** 対話のシェル（`on-attach.sh` が `~/.bashrc` / `~/.zshrc` へ注入します。端末が付いている対話のシェルで、今いるディレクトリがそのプロジェクトの中のときだけ。差し込みの印はプロジェクトごとです）で「追従しますか？ [y/N]」と聞きます。今の版と最新の版を示し、**「移行」の節がある版を 2 つ以上飛び越えるときは `[注意]` で目立たせます**（最新のタグの配布先の `CHANGELOG.md`（`raw.githubusercontent.com`）を読み、(今の版, 最新] の「## vX.Y.Z」の節のうち「### 移行」を持つ版を数えます。リリースの本文は「Release vX.Y.Z」の 1 行でリリースノートを含まないためです。読めなければ、リリースノートを読む案内に留めます）。問いかけの文には、**追従する作業ツリーのパスと、何が起きるか**を問いかけの文に含めます（既定ブランチの上なら「作業用のブランチ <名前> を切って追従します」、それ以外なら「今のブランチ <名前> の上で追従します」。名前は実際に切るブランチと同じ関数で決めます。`origin/HEAD` が無いときの扱いも同じです。専用の worktree は作らないので、プライマリの作業ツリーで y と答えると、そのブランチが動きます）。手で呼ぶ `upgrade` も、追従を始める前に同じ内容を 1 行出します。 複数の端末が同時に開いても、聞く・追従するのは 1 つの端末だけです（`flock`。無い環境ではロックのディレクトリ）。
- **y のとき:** 新しい版の `bootstrap.sh` と `SHA256SUMS`（リリースの資産）を取得し、**ハッシュを照合してから**、ORIGIN を引き継ぐ `--upgrade` を流します。ai-playbook に新しい版があれば、取得元の種類のまま渡します（`tag` は `--playbook-version`、リリースのタグの tarball の url は、フォークの owner を保ったままの `--playbook-from`）。**y で上げるのは、表示した部品だけです**（N と答えた版は上げません。DCB を上げないときは、今の版の `bootstrap.sh` で追従し、生成物の DCB の版を下げません）。失敗したとき、何も書かれていなければ、切った作業用のブランチを消して元のブランチへ戻します。途中で書かれたファイルがあれば、自動では戻さず（作業ツリー全体を戻すと、ほかの端末での編集まで消しうるため）、作業用のブランチに留まって戻し方（`git restore .` と `git clean -fd`）を案内します。規範の取得元が `adjacent` / `local` / 記録のない url のときは、取得した `bootstrap.sh` からは再現できないので追従せず、手元の `bootstrap.sh` で `--upgrade` する案内に留めます。既定ブランチの上なら先に作業用のブランチ（`chore/update-dcb-<版>`）を切ります。既定ブランチは `origin/HEAD` で判定します。`origin/HEAD` が無いときは推定せず、main / master のどちらかの上にいれば切ります（リモートへは問い合わせません）。問いかけで表示した版だけが、N の記録と y の追従の対象です（待っているあいだにキャッシュが更新されても、読み直しません）。差分を作業ツリーに残して止まり、変わったファイルと次の手順（差分を読む → `scripts/verify.sh` → コミット → PR）を出します。**コミット・push・PR はしません。** 未コミットの変更があるときは、差分が混ざるので追従せずに止めます。照合に通らないときは何も実行しません。
- **N のとき:** その版のあいだは聞きません（通知も出しません）。さらに新しい版が出れば、また聞きます。
- **手で追従する:** `bash scripts/update-check.sh upgrade`（最新を問い合わせて、y と同じ処理をします）。
- **間引きと失敗:** 問い合わせは 1 日 1 回です。**取得をすべて終えた日だけ**数えます。どの部品の取得がどんな理由（通信ができない・HTTP のエラー・API の制限・形の不一致・`CHANGELOG.md` の取得の失敗）で失敗しても、その日の印を書かず、次の接続で取り直します（成功した部品は差し替え、失敗した部品の前の日のキャッシュは消します。更新は更新用のロック（`refresh-lock`）を取って行い、取れなければ（別の接続が更新中なら）更新を飛ばして、通知だけキャッシュから出します。問いかけのロックとは別なので、更新のあいだも問いかけは出ます）。`upgrade` は、今回の問い合わせで取得できた部品だけを対象にします（取得できなかった部品は、同じ日のキャッシュがあっても追従せず、そう報告します。どちらも取得できなければ失敗で終わります）。オフラインのマシンでは接続のたびに問い合わせます（最大 2 秒）。オフライン・API の失敗・制限は黙って通し（短いタイムアウト）、起動を止めません。端末が付いていないシェル（AI エージェント・CI・スクリプト）では何も聞かず、何も出しません。
- **キャッシュ:** `${XDG_CACHE_HOME:-~/.cache}/dcb-update-check/<プロジェクトごとの鍵>/`。コミットしません。問い合わせの結果は、いったん作業用のファイルへ書いてから rename で差し替えます（先に消さないので、更新のあいだに prompt が読んでも一貫した状態を読めます）。今日の印（`checked`）は取得を終えてから最後に書きます。通信ができずに途中で抜けたときは書かず、前の日のキャッシュを消すので、次の接続で取り直します（`upgrade` は取得できなかったと報告して失敗で終わり、古い版へは追従しません）。`migrations-<部品>` は「<版>=<版の一覧>」で、`latest-<部品>` と版が一致するときだけ使います（別々の rename でも、組み合わせを読み違えません）。作業用のファイルは、中断（Ctrl-C など）でも片づけ、1 日より古い残りは次の取得の開始時に消します。
- **確認の対象:** ORIGIN の `version=` が `vX.Y.Z` のときの DCB（取得元は `ojos/devcontainer-bootstrap`）。ai-playbook は、取得元が `tag`、またはリリースのタグの tarball の URL（`https://github.com/<owner>/ai-playbook/archive/refs/tags/<版>.tar.gz`）のときだけで、ほかの取得元（`adjacent` / `local` など）は確認しません。ORIGIN が無い、`version=` がリリースの版でない環境（この開発リポジトリを含む）では何もしません。
- **止め方:** 生成時の `--no-update-check`（ORIGIN に記録し、`--upgrade` で引き継ぎます。戻すのは `--upgrade --update-check`）、または `UPDATE_CHECK=off`（`0` / `false` / `no` / `disabled` も同じ）。環境変数で設定すれば止まります。`UPDATE_CHECK` に値（空でない）があれば、環境の値でも、コマンドで明示した値（`UPDATE_CHECK=off bash scripts/update-check.sh notify` など）でも、それを採ります。通知の末尾の「止めるには」も同じ順で、`UPDATE_CHECK=off`（環境の値。無ければ .env の値）と案内します。`.env` の `UPDATE_CHECK` は、`UPDATE_CHECK` に値が無いときだけ `update-check.sh` がローダーの値取得の関数（`__load_project_env_value`。変数は変えません）で読みます（`.env` の自動読み込み `load-project-env.sh` は `UPDATE_CHECK` だけ上書きしません。このキーを読むのは `update-check.sh` だけなので、対話のシェルの `UPDATE_CHECK` は `.env` の値を映しません）。`.env` に書くときは、`.env.example` のコメントの行の `#` を外します。

## Doctor 自己診断

生成後、生成先を対象に実行して構成を検証します。公開リリースから `doctor.sh` を入手する手順は [doctor.sh を後から取得する](#doctorsh-を後から取得する) を参照してください。

```bash
# 生成先を明示する場合（--target-dir 省略時はカレントディレクトリ）
./doctor.sh --target-dir ./myapp

# 生成先のコンテナ内で実行する場合は WARN も失格にする
./doctor.sh --strict
```

オプション:

- `--target-dir <path>`（既定: カレントディレクトリ）
- `--strict`（既定: 無効。WARN があれば非 0 で終了する）
- `-h` / `--help`

検査は 5 カテゴリです。

| カテゴリ | 検査内容 |
|---|---|
| 静的構造 | `.devcontainer/devcontainer.json` / `.env.example` / `scripts/on-attach.sh` / `scripts/fix-mount-owner.sh` / `scripts/post-rebuild-check.sh` / `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh` / `scripts/check-no-secrets.sh` の実在。`devcontainer.json` が妥当な JSON であること（コメントは除いて判定します。JSONC として読みます）。**`${localEnv:` の混入が無いこと**（下記）。`dockerComposeFile` が参照する compose ファイルが実在すること |
| スクリプト検査 | 生成した各スクリプトの `bash -n` 構文検査（NG なら FAIL）と実行ビットの有無（無ければ WARN） |
| 衛生検査の配線 | 生成先に衛生検査 4 本（`check-control-chars.sh` / `check-table-breaks.sh` / `check-doc-links.sh` / `check-shell-portability.sh`）のいずれかがあり、`scripts/acceptance.sh` がそのファイル名を参照していなければ `[WARN]`（件数と配線の例を添える。`--strict` では非 0）。ファイル名がコメントにあるだけでも参照と見なすので、意図して呼ばない検査はファイル名と理由をコメントで書けば WARN が出ない。`acceptance.sh` が無いときは判定しない。`doctor.sh` は単体で取得されうるため、4 本の一覧は自前で持つ（`bootstrap.sh` と同じ内容。`tests/test-hygiene-wiring.sh` が照合する） |
| 生成物の由来（下記） | `.devcontainer/ORIGIN`（[生成物の由来の記録](#生成物の由来の記録devcontainerorigin)）と現物を突き合わせ、生成時からの変更・記録した版が古いことを検出する |
| 実行時コマンドの可用性 | `bash` / `jq` / `perl` / `gh`。`devcontainer.json` の features から検出した言語ランタイム（`rust` は feature 名と実行ファイル名が異なるため `cargo` で判定。`ruby` は一致するため `ruby` で判定）。`--with-aws` / `--with-gcp` で配線した cloud CLI（`aws` / `gcloud` / `terraform`）。`docker-outside-of-docker` を配線していれば `docker`。いずれも不在は WARN |

**`${localEnv:` の検出がこの診断の中核です。** 「[資格情報の扱い](#資格情報の扱い)」で述べたホスト資格情報の非注入は、方針を書いただけでは守られません。`remoteEnv` へホスト環境変数の参照が復活していないことを doctor が機械的に検査し、見つけたら FAIL にします。作業ディレクトリの受け渡し（`${localWorkspaceFolder}`）は `localEnv` ではないため対象外です。

**生成物の由来の検査（`.devcontainer/ORIGIN`）は次のように判定します。**

| 状態 | 判定 |
|---|---|
| 記録が無い | `[WARN]` **診断できません。** この生成先が本機能より前に作られたか、記録が削除された可能性があります。記録の無い生成先への遡及はできません |
| 記録が壊れている（`version=` 行が読めない等） | `[FAIL]` 診断できません |
| 記録した生成物が現物と一致しないが、`accepted:` の記録（`bootstrap.sh --accept`）とは一致する | `[OK]` 取り込み済みとして件数を報告 |
| 記録した生成物が現物と一致しないが、`owned:`（プロジェクトが所有・編集）の記録があり、`pending:` が無い | `[OK]` 編集済みの所有ファイルとして件数を報告 |
| 記録した生成物が現物と一致せず、`accepted:` / `owned:` の記録とも合わない、または `pending:` がある | `[FAIL]` 該当ファイル名を添えて「生成時から変化しています」と報告し、`bootstrap.sh --accept <path>` の案内を添える |
| 記録した生成物が現物と一致するが、`pending:` が残っている | `[WARN]` 件数と対象のパスを出し、`bootstrap.sh --accept <path>` か `--upgrade` で外すよう案内（取り込む差分は無いが記録が古い。`--strict` では落ちる） |
| 記録した生成物が消えている（`absent:` の記録が無い） | `[FAIL]` 該当ファイル名を添えて報告 |
| 記録した生成物が消えているが、`absent:` の記録がある（外せない一覧のパスを除く） | `[OK]` 意図して置かないファイルとして件数を報告 |
| `absent:` の記録があるのに、現物がある | `[FAIL]` 該当ファイル名を添え、`bootstrap.sh --no-absent <path>` の案内を添える |
| 外せない一覧のパスに `absent:` の記録がある | `[FAIL]` ORIGIN の破損として報告（そのパスが消えていても同じ） |
| `absent:` の対象に `hash:` が無い（生成物でない）、または値が `1` でない | `[FAIL]` 記録が壊れている |
| 静的な構造の検査（`.env.example`・各スクリプトなどの存在）で、無いファイルに `absent:` の記録がある（外せない一覧のパスを除く） | `[OK]` 置かない記録どおりとして報告（`devcontainer.json` が参照する compose ファイルの存在は、`absent:` があっても `[FAIL]` のまま） |
| 記録の版が `doctor.sh` 自身の版より古い | `[WARN]` 「上流が更新されています」と報告 |
| 記録の版が一致（または新しい） | `[OK]` |
| `*.dcb-new` が残っている | `[WARN]` 一覧と取り込み方を出す（下記） |

**`doctor.sh` は `bootstrap.sh` と同じ版を使ってください。** 旧い `doctor.sh` は `owned:` / `pending:` / `absent:` を「認識できない行」として `[FAIL]` にします（`accepted:` の導入時と同じ性質）。

**書式の検査**: `version=` / `flags=` / `inputs-format=` / `input:<名前>=` / `hash:<パス>=<sha256>` / `accepted:<パス>=<sha256>` / `owned:<パス>=<値>` / `pending:<パス>=<値>` / `absent:<パス>=<値>` 以外の行、`%` の不正な並び、不正な `hash:` / `accepted:` の行は `[FAIL]`（記録が壊れている）です。新しい形式（`inputs-format=1`）では `version=` と `flags=`（空の値は可）が必須で、無ければ `[FAIL]` です。同じ `input:` の名前が重複していても `[FAIL]` です。`inputs-format` が `1` でなければ、知らない書式なので入力の検査を省いて `[WARN]` にします。`inputs-format` の無い古い形式は、行の文法だけを見て通します。

**残っている `*.dcb-new` の報告**: `bootstrap.sh --upgrade` が、手を入れたファイルの隣へ置いた新しい版（`<path>.dcb-new`）が出力先に残っていれば、`[WARN]` でパスを一覧します（`.git` と `node_modules` は除き、シンボリックリンクはたどりません）。取り込み方は、**元のファイルと `.dcb-new` の中身を見比べ、必要な差分を手で混ぜてから `.dcb-new` を消す**ことです。自動では混ぜません。`--strict` では、これも失格になります。

いずれも**検査が成立しないことを合格（`[OK]`）にはしません。** 記録の欠落・破損は `[WARN]` または `[FAIL]` として明示し、黙って通過させません。

> **既知の限界**: 上流の更新有無は、ネットワークへ問い合わせず `doctor.sh` 自身に埋め込んだ版とだけ比較します（規範がループ用の受け入れ検証から外部層を外しているのと同じ理由です）。そのため、**古い `doctor.sh` をそのまま使い続けると、その後さらに上流が更新されていても気づけません。** `doctor.sh` は公開リリースごとに取得し直してください（[doctor.sh を後から取得する](#doctorsh-を後から取得する)）。「診断が緑なら最新」とは言えません。

判定は `[OK]` / `[WARN]` / `[FAIL]` の 3 種で出力し、末尾に `Summary: PASS=<n> WARN=<n> FAIL=<n>` を表示します。終了コードは 3 値です。

| 終了コード | 意味 |
|---|---|
| `0` | FAIL が 0 件（`--strict` を付けた場合は WARN も 0 件） |
| `1` | FAIL が 1 件以上 |
| `2` | `--strict` 指定時に FAIL は 0 件だが WARN が 1 件以上 |

WARN は「コンテナの外から実行したので言語ランタイムが見えない」といった、環境由来で正当なこともあります。**生成先のコンテナ内で実行するときに `--strict` を使う**のが想定運用です。

## リモートレビュー分離への移行

`--with-copilot` からリモートのレビュー機構を切り出し、`--with-copilot-review` を新設しました（**破壊的変更**）。1 つのフラグが「手元の開発ツール」と「リモートのレビュー機構」という性質の違う 2 つを制御していたため、リモートのゲートだけを使う構成を機構で表現できなかったのが理由です。

| 指定 | ローカル装備（CLI / 拡張 / `~/.copilot` 永続化） | リモートのワークフロー 2 本 |
|---|---|---|
| `--with-copilot` | 入る | **入らない（変更点）** |
| `--with-copilot-review` | 入らない | 入る（規範の配置が前提） |
| 両方 | 入る | 入る（旧 `--with-copilot` + 規範の配置と同じ結果） |

移行手順:

- **これまで `--with-copilot` + 規範の配置でワークフローを得ていた場合**は、`--with-copilot-review` を足してください。それだけで従来と同じ生成結果になります。
- **ローカルの CLI・拡張だけが目的だった場合**は、変更は不要です。`--with-copilot` の意味がローカル配線だけに縮んだ形になります。
- **既存の生成物は、再生成しない限り影響を受けません。** 配置済みの `.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml` はそのまま残ります。`--with-copilot-review` を付けずに `--force` 付きで再生成した場合も、DCB はこの 2 本を削除しません（生成しないだけです）。ただし規範側の更新が反映されなくなるため、リモート最終ゲートを使い続けるなら新フラグを付けてください。
- `--with-copilot-review` は規範の配置（`--with-playbook` / `--playbook-version` / `--playbook-from`）が前提です。規範なしで指定すると、**ファイルを 1 つも書かずに**エラー終了します。

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

