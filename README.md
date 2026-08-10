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

`doctor.sh` は `jq` を使います（`devcontainer.json` の JSON 妥当性検査と `dockerComposeFile` の読み取り）。

`docker` は**任意**です。あればベースイメージの `os/arch` 適合を実際のマニフェストで判定し、無ければ既定の `mcr.microsoft.com/devcontainers/base:ubuntu` へフォールバックします（警告のみで停止しません）。

## 公開リリースからの利用

公開リポジトリ:
- https://github.com/ojos/devcontainer-bootstrap

最新安定リリース:
- `v0.9.1`

取得したスクリプトは実行前に必ず検証します。取得と実行は一時ディレクトリで行い、生成先は `--output-dir` で指定します。スクリプトの置き場所と生成先は独立しているため、実行後は `trap` で作業ディレクトリごと破棄でき、手元に取得物や後片付けが残りません。

```bash
TAG=v0.9.1
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"

d="$(mktemp -d "${TMPDIR:-/tmp}/dcb.XXXXXX")" || exit 1
trap 'rm -rf "$d"' EXIT
curl -sSL "${BASE}/bootstrap.sh" -o "$d/bootstrap.sh"
curl -sSL "${BASE}/SHA256SUMS"  -o "$d/SHA256SUMS"

# --ignore-missing: SHA256SUMS は doctor.sh も対象にするため、bootstrap.sh だけを
# 取得した場合は付けないと「doctor.sh が無い」で失敗する。
#
# 検証と実行は && で連結する。この手順は対話シェルへ貼って使うため set -e が効かず、
# 行を分けると検証に失敗しても次の bash が走る。
( cd "$d" && sha256sum --ignore-missing -c SHA256SUMS ) &&
bash "$d/bootstrap.sh" --project-name myapp --output-dir "$PWD/myapp" \
  --languages node,go --with-aws --with-claude
```

一時ディレクトリから実行するため、次の 2 点に注意してください。

- **`--output-dir` を必ず明示します。** 省略時の既定は `$PWD/<project-name>`、つまり一時ディレクトリの中になり、生成物が `trap` で消えます。
- **`sha256sum --ignore-missing` は GNU coreutils 8.25 以降が必要です。** それ以前の環境や BSD 系の `shasum` を使う場合は、`doctor.sh` も取得したうえで `--ignore-missing` を外してください。

検証を挟まない `curl | bash` 形式は採りません。`SHA256SUMS` は改ざんと取得失敗の両方を検出する唯一の手段で、省くと配布物の同一性を確認する経路が無くなります。

AI 共通ルールも配置する場合は、ルールの取得元を指定します。一時ディレクトリから実行すると隣接チェックアウトが存在しないため、`--playbook-version` または `--playbook-from` が必要です（[AI 共通ルールの配置](#ai-共通ルールの配置)）。

```bash
# 上の手順の最後（検証と実行）を、規範の取得元を足した形へ置き換える。
( cd "$d" && sha256sum --ignore-missing -c SHA256SUMS ) &&
bash "$d/bootstrap.sh" --project-name myapp --output-dir "$PWD/myapp" \
  --languages node,go --with-claude --playbook-version v0.1.4
```

`--playbook-version` は既定ソース `ojos/ai-playbook` のタグ tarball への糖衣で、長い archive URL を打たずに済みます。ソースを指定した時点で配置されるため `--with-playbook` は不要です。別 owner・任意の URL・ローカルディレクトリから取得する場合は、従来どおり `--playbook-from` を使います（`--playbook-version` とは排他）。

> **破壊的変更（`--mode` 廃止）**: 従来の `--mode <minimal|standard|full>` は廃止しました。装備は
> `--with-*` フラグで明示選択します。移行対応表は [mode オプションからの移行](#mode-オプションからの移行) を参照してください。

### doctor.sh を後から取得する

上の手順は `bootstrap.sh` だけを取得します。生成後の自己診断（[Doctor 自己診断](#doctor-自己診断)）を実行するときに、同じ要領で `doctor.sh` を取得します。`doctor.sh` も診断対象を `--target-dir` で受け取るため、一時ディレクトリから実行できます。

```bash
TAG=v0.9.1
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"

d="$(mktemp -d "${TMPDIR:-/tmp}/dcb.XXXXXX")" || exit 1
trap 'rm -rf "$d"' EXIT
curl -sSL "${BASE}/doctor.sh"  -o "$d/doctor.sh"
curl -sSL "${BASE}/SHA256SUMS" -o "$d/SHA256SUMS"

( cd "$d" && sha256sum --ignore-missing -c SHA256SUMS ) &&
bash "$d/doctor.sh" --target-dir ./myapp
```

診断のたびに取得すれば、生成先のリポジトリへ `doctor.sh` を混入させずに済みます。手元へ置いて繰り返し使う場合は、`bootstrap.sh` と `doctor.sh` を同じディレクトリへ取得し、`--ignore-missing` を付けずに `sha256sum -c SHA256SUMS` で両方を検証してください。

### リリース資産

各リリースには次の 5 つを添付します。通常の利用に必要なのは上の 3 つだけで、残りの 2 つは「配布物そのものを検証・保全したい」場合に使います。

| 資産 | 用途 |
|---|---|
| `bootstrap.sh` | 生成コマンド本体。単体で動作します |
| `doctor.sh` | 生成後の自己診断コマンド。単体で動作します |
| `SHA256SUMS` | 上の 2 つのチェックサム。`sha256sum -c SHA256SUMS` で改ざん・取得失敗を検出します（片方だけ取得した場合は `--ignore-missing` を付けます） |
| `PACKAGE_ARCHIVE.tar.gz` | そのリリース時点の公開リポジトリのツリー一式（`.git` と生成した 3 資産を除く。`bootstrap.sh` / `doctor.sh` / この README / `LICENSE` / `CHANGELOG.md`）。スクリプトと手順書を 1 つの塊として手元へ固定したい場合や、リリース間の差分を追いたい場合に使います |
| `RELEASE-MANIFEST.json` | パッケージ名・版・資産一覧・チェックサムを機械可読にまとめたもの。`assets` がそのリリースに添付された資産の一覧、`checksums` が `PACKAGE_ARCHIVE.tar.gz` と `SHA256SUMS` のハッシュです |

検証は 2 段構えです。`RELEASE-MANIFEST.json` が `SHA256SUMS` のハッシュを持ち、`SHA256SUMS` が `bootstrap.sh` / `doctor.sh` のハッシュを持つため、マニフェストを起点に配布物全体まで辿れます。

```bash
TAG=v0.9.1
BASE="https://github.com/ojos/devcontainer-bootstrap/releases/download/${TAG}"
curl -sSL "${BASE}/RELEASE-MANIFEST.json" -o RELEASE-MANIFEST.json
curl -sSL "${BASE}/PACKAGE_ARCHIVE.tar.gz" -o PACKAGE_ARCHIVE.tar.gz
curl -sSL "${BASE}/SHA256SUMS" -o SHA256SUMS

# 1. マニフェストが記録したハッシュと実物を突き合わせる
jq -r '.checksums | to_entries[] | "\(.value)  \(.key)"' RELEASE-MANIFEST.json | sha256sum -c -

# 2. マニフェストが検証した SHA256SUMS で、実行するスクリプトを検証する
curl -sSL "${BASE}/bootstrap.sh" -o bootstrap.sh
curl -sSL "${BASE}/doctor.sh" -o doctor.sh
sha256sum -c SHA256SUMS

# アーカイブから中身を取り出す場合
tar -xzf PACKAGE_ARCHIVE.tar.gz
```

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
| `--with-copilot` | GitHub Copilot CLI（`@github/copilot`）+ `github.copilot` / `github.copilot-chat` 拡張 + `~/.copilot` 永続化 |
| `--with-copilot-review` | リモート最終ゲートのワークフロー 2 本（`.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml`）。**ローカルの装備は一切入りません。** 規範の配置が前提（下記） |

- **ローカル装備とリモート機構は別フラグ**: `--with-copilot` が配線するのは手元の開発ツール（CLI・拡張・永続 volume）だけで、リモートのレビュー機構は `--with-copilot-review` が担います。効く場所が違うものを 1 つのフラグで束ねると、「リモートのレビューゲートだけ欲しい」構成を機構で表現できないためです（[リモートレビュー分離への移行](#リモートレビュー分離への移行)）。
- **`--with-copilot-review` は規範の配置が前提**: 配置するワークフローの雛形は規範パッケージが持つため、規範を配置しない構成では供給元がありません。`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれも指定せずに（または `--without-playbook` と併せて）指定すると、**ファイルを 1 つも書かずに**エラー終了します。
- **Terraform は cloud 随伴**: `--with-aws` または `--with-gcp` のいずれかを指定すると、Terraform feature + `hashicorp.terraform` 拡張が **1 回だけ** 同梱されます（両指定でも 1 回、cloud 無指定なら入りません）。
- **AI ツールは明示 opt-in のみ**: `--with-<ai>` を指定したときだけ、CLI 導入・VS Code 拡張・設定ディレクトリの永続化（compose named volume）を行います。トークン有無による自動導入は行いません。
- **資格情報はホストから注入しません**: `remoteEnv` が運ぶのは作業ディレクトリのパス（`LOCAL_WORKSPACE_FOLDER`）だけです。認証はコンテナ内で行い、その状態を named volume に残します。唯一の例外は GitHub CLI で、PAT を `.env` の `GH_TOKEN` へ置けます（下記「[資格情報の扱い](#資格情報の扱い)」）。

### オプション入力
- `--output-dir <path>`（既定: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（既定: Docker サーバーの `os/arch` から自動判定。この値で上書きして明示指定）
- `--dry-run`（既定: 無効。生成予定のパスを `plan:` 行として並べるだけで、**ファイルを 1 つも書きません**）
- `--force`（既定: 無効。既存ファイルの上書きを許可します。下記「再実行したときの挙動」参照）
- `--no-gitignore`（既定: 無効＝`.gitignore` の managed セクションを更新する。指定すると `.gitignore` に一切触れません）
- `--gitignore-targets <csv>`（既定: 空。暗黙ターゲットに**追加で合成**する github/gitignore テンプレート名。下記「`.gitignore` と github/gitignore の連携」参照）
- `--with-playbook` / `--without-playbook`（AI 共通ルールの配置。既定: 配置しない）
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

同じ出力先へ再実行しても、**既定では既存ファイルを上書きしません**。

- `--force` 未指定（既定）: 既に存在するファイルは `skip (exists): <path>` と表示して**そのまま温存**します。テンプレートを更新した DCB で再実行しても、生成済みファイルは古いままになります。
- `--force` 指定: 既存ファイルを新しいテンプレートで**上書き**します。
- `--playbook-conflict-policy` が効くのは**規範ファイル**（`.ai-playbook/**` / 入口ファイル / `scripts/second-opinion-review.sh` など）だけで、`.devcontainer/` や `scripts/` のテンプレート生成物には効きません。テンプレート生成物の上書きは `--force` が唯一の手段です。
- `.gitignore` の managed セクションだけは `--force` に依らず毎回差し替えます（セクション外の行は保持）。
- 何が書かれるかを先に確かめたい場合は `--dry-run` を使います。

### AI 共通ルールの配置

共通ルールと入口ファイルを生成先へ配置します。**既定では配置しません**（オプトイン）。次のいずれかで配置を有効化します。

- `--playbook-version <tag>` または `--playbook-from <path|url>` で**ソースを指定する**（指定した時点で配置意図が明確なため、`--with-playbook` は不要）
- `--with-playbook`（ソースを指定せず、**隣接する ai-playbook チェックアウト**から入れたい場合の明示スイッチ）

`--without-playbook` を指定すると、ソース指定があっても配置しません（明示オプトアウトが最優先）。

配置されるもの:

| 配置先 | 内容 |
|---|---|
| `.ai-playbook/**` | 共通規範、ロール契約、タスクプレイブック、レビュー運用、intake 規律 |
| `.ai-playbook/VERSION` | 取り込んだ規範の出所（`version=` / `source=`）を on-disk に残す証跡。どの版の規範が入っているかを生成後の環境から照合できる |
| `.github/project-ai-rules.md` | プロジェクト共通ルールの雛形 |
| `CLAUDE.md` / `.github/copilot-instructions.md` | 実行環境の入口ファイル（3 層の優先順位を配線） |
| `scripts/second-opinion-review.sh` | 第二意見レビューの実行体。`scripts/loop-gate.sh` が存在すれば自動で直列化する。既定は `gemini` CLI（Antigravity CLI への切り替えにも対応するが、`agy` の導入はこの生成器の対象外） |
| `.claude/skills/intake/SKILL.md` | Claude Code 向け intake 起点スキル（`--with-claude` 指定時のみ）。規範を複製せず `.ai-playbook/intake/` を参照するだけの薄いスキル |

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

導入するのは `--with-claude` / `--with-gemini` / `--with-copilot` で**明示選択した AI CLI のみ**です。トークン有無での自動導入は行いません（明示 opt-in）。何も選択しなければ AI CLI は導入されません。

## ループコーディング支援

AI エージェントの反復（実装 → 検証 → 修正 → …）を、**機械が緑判定できる決定的な信号**の上で収束させるための実行体を生成します。装備の選択によらず常に生成し、**外部パッケージの導入を前提にせず単体で動作**します。

> この節は DCB 環境での**操作手順**（各スクリプトをどう回すか）を扱います。ループコーディングという**ワークフロー自体の考え方**（従来との違い・収束規律・受け入れ検証の機械ゲート化）は、規範パッケージ ai-playbook の解説ガイド `loop-coding-guide.md`（規範の正本は `loop-workflow.md`）を参照してください。規範を配置する（`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれか）と、これらの規範も生成先へ配置されます。

| スクリプト | 役割 |
|---|---|
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（プロジェクトが所有・編集）。選択言語のうち、ルート直下にマニフェストが存在する対象だけを慣習的テストで検証する |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS` / 終了コード 0）を返す接地信号。手前で `check-no-secrets.sh` を実行する |
| `scripts/check-no-secrets.sh` | 機密混入の検知ゲート（`SECRETS_PASS` / 終了コード 0）。判定の正本で、`verify.sh` と CI が共用する。下記「[機密混入検査](#機密混入検査)」参照 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。`verify.sh` と、任意の第二意見レビューを直列で通す単一入口（`GATE_PASS` / 終了コード 0） |
| `scripts/acceptance-remote.sh` | **外部層**の受け入れ条件（プロジェクトが所有・編集）。`--with-aws` / `--with-gcp` を選んだときだけ配置する骨格のみの雛形。下記「受け入れ条件の二層」参照 |

- `acceptance.sh` は生成時、選択言語ごとに**ルート直下のマニフェストの実在を確認してから**慣習的コマンド（`node`/`package.json`→`npm test`、`go`/`go.mod`→`go test ./...`、`python`/`pyproject.toml`・`requirements.txt`→`python -m pytest`、`php`/`composer.json`→`composer test`、`rust`/`Cargo.toml`→`cargo test`、`ruby`/`Gemfile`→`bundle exec rake`）を実行します。マニフェストが無い言語は理由を出して**スキップ**し（失敗させない）、マニフェストはあるがツールが無い場合は導入手順を添えて**失敗**させます（スキップと混同しない）。1 つも検証を実行できなければ「受け入れ条件が未定義」として**非 0 で終了**します（全スキップで誤って緑になる事故を防ぐ）。スクリプト位置からルートを解決するため、起動時の作業ディレクトリに依存しません。プロジェクトの実態に合わせて編集してください。受け入れ条件が検証可能であるほど、反復が収束しやすくなります。
  - monorepo など、各言語がルート直下ではなくサブディレクトリ（例 `apps/*`）に配置される構成では、生成直後は対象が見つからず「未定義」で失敗します。これは**意図した既定**であり、実配置のマニフェストを見るよう `acceptance.sh` を編集して受け入れ条件を確定させてください。
- `verify.sh` の受け入れ定義は `VERIFY_ACCEPTANCE` 環境変数で差し替えできます（既定は `scripts/acceptance.sh`）。層を増やすときも同じランナーを使い、受け入れ定義だけを差し替えます（下記「受け入れ条件の二層」）。
- `verify.sh` は受け入れ条件の**手前**で `scripts/check-no-secrets.sh` を実行します。`acceptance.sh` 側へ置かないのは、あちらがプロジェクトの所有物で受け入れ条件を書き足すたびに触られ、規範由来の検査が消える経路ができるためです。`check-no-secrets.sh` が不在なら `VERIFY_FAIL` で止まります（検査が成立していないことを合格にしないため）。**この検査は git を前提にします**（下記「[機密混入検査](#機密混入検査)」参照）。
- `loop-gate.sh` の第二意見は、`scripts/second-opinion-review.sh` が存在すれば直列化し、無ければ優雅にスキップします。`LOOP_GATE_REVIEW_CMD` で任意のレビューコマンドへ差し替え、空文字で無効化できます。
- 第二意見へ渡す**差分の範囲**は次の順で決まります。ステージ済み差分があるときはレビュー実行体の既定に委ね（範囲を渡しません）、空のときだけ commit 済み範囲へ切り替えます。切り替え先の既定は `@{upstream}..HEAD` で、下のいずれかに当たる場合は**既定ブランチとの分岐点（merge-base）を起点**にします。既定ブランチは `origin/HEAD` → `origin/main` → `origin/master` の順で解決し、汚染の判定と分岐点の算出は**同じ枝**を見ます（別々に決めると、汚染ありと判定した枝と分岐点を取った枝が別物になりうるため）。**上流以外を起点に採った場合は、その理由を 1 行出力します**（黙って範囲を変えると、なぜその差分が対象なのかを読み手が追えないため）。
  - **上流との差分が空**（push 済みで上流 == HEAD）。ここで空のまま第二意見を呼ぶと、一度も差分を見ないまま通過する偽の緑になります。
  - **上流が未設定**。
  - **`@{upstream}..HEAD` が既定ブランチへ到達可能なコミットを含む**（＝このブランチへ既定ブランチを取り込んだ直後）。`@{upstream}..HEAD` は 2 点間の比較なので、取り込んだ側のコミットがまるごと差分へ入り、既にレビューを通った他ブランチの成果を巻き込みます。判定は「マージコミットを含むか」ではなく到達可能性（`git rev-list --count <up>..HEAD` と `git rev-list --count <up>..HEAD ^<base>` の一致）で行うため、マージコミットを作らない fast-forward や rebase での取り込みも同じく検出します。なお squash / cherry-pick での取り込みは新しいコミットを作るだけで到達可能性を生まないため、どの起点を選んでも差分から外れません（範囲の選び方だけでは解けない制約です）。
  - 既定ブランチの追跡枝を解決できない環境では汚染を判定できないため、**従来どおり上流を使います**（判定不能を汚染扱いにすると、分岐点も取れないまま範囲を失うため）。
- `loop-gate.sh` は source ガードを持ち、`source`（`.`）で読み込んだだけではゲート本体を実行せず、範囲解決の関数だけを提供します。範囲の決め方を単体で検証できるようにするためで、ルートへの `cd` もゲート本体側に置いてあり、読み込んだ側の作業ディレクトリを動かしません。
- これらは純粋な機構であり、規範（受け入れ検証の機械ゲート化・収束規則・verify ランナー契約）は ai-playbook の `loop-workflow.md` が正本です。規範を配置した場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、第二意見の `second-opinion-review.sh` も配置され、`loop-gate.sh` が自動で直列化します。
- 上の 3 本は**手元から起動する入口**で、実行するかどうかは人に委ねられています。**回し忘れれば何も起きません。** それを塞ぐため、`verify.sh` を CI でも回す `.github/workflows/verify.yml` を**常に**配置します（下記「受け入れ検証の CI ワークフロー」参照）。

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

> **この開発リポジトリ自身には `verify.yml` を置きません。** 既に `.github/workflows/ci.yml` が同じ役割を持ち、`scripts/acceptance.sh` がその 6 ジョブ + `identity-guard.yml` を完全ミラーしているため、`verify.yml` を置くと役割が重複し、`tests/test-ci-mirror.sh` のミラー対象が 2 本になります。**雛形を配りながら自分では使わない状態を、無自覚ではなく明示の判断として残します。**

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
- `--with-claude`: `anthropic.claude-code`。`--with-gemini`: `Google.gemini-cli-vscode-ide-companion`。`--with-copilot`: `github.copilot` / `github.copilot-chat`。

## 資格情報の扱い

**ホスト OS の資格情報をコンテナへ注入しません。** 生成される `remoteEnv` が運ぶのは作業ディレクトリのパス（`LOCAL_WORKSPACE_FOLDER`）だけです。

この方針は事故の反省から来ています。`${localEnv:...}` でトークンを注入する構造では、コンテナ内のツールが「どの資格情報を使っているか」を利用者が意識できません。ホスト側と `.env` に別の値が入っていると、`.env` を読まない文脈でだけ黙ってホスト側が使われ、別アカウントの PAT が `git credential fill` から警告なく返る、別アカウントの API キーでクォータと課金が消費される、といった形で表面化します。

代わりに、次の 2 経路に限定します。

| 種類 | 供給元 | 永続化 |
|---|---|---|
| 認証（GitHub / cloud / AI CLI） | **コンテナ内でのログイン**（`gh auth login` / `aws sso login` / `gcloud auth login` / `claude /login`）。GitHub だけは `.env` の `GH_TOKEN` で PAT に固定する経路もあります（[理由](#github-認証だけが例外である理由)）。`GITHUB_TOKEN` は[供給元にしません](#github_token-は設定しない) | named volume（`gh-storage` / `aws-storage` / `gcloud-storage` / `<ai>-storage`）。リビルドを跨いで残る |
| プロジェクト固有値（API キー・コミット identity） | **プロジェクトの `.env`**（雛形: 生成される `.env.example`） | ファイルとして目に見える。`scripts/load-project-env.sh` が読む |

`.env.example` が持つキー:

- `GEMINI_API_KEY` — 第二意見レビュー（`scripts/second-opinion-review.sh`）が読みます。
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
  - committer が `noreply@github.com` のコミットに限り、author が `<login>@users.noreply.github.com` の形であれば許可します。GitHub 側で「メールアドレスを非公開にする」を有効にしている利用者の PR マージ・web UI 編集に対応するためで、許可を committer に縛ることでローカルで作ったコミットには適用されません（ローカルの identity 適用漏れは従来どおり検知します）。
  - 使い方: 既定は `origin/main..HEAD`、範囲指定可、`--full` で HEAD の全履歴（`git rev-list --all` にはしない）。
- `.github/workflows/identity-guard.yml`（CI）
  - `pull_request`（PR の全コミット）と `push`（`main` の全履歴）の 2 系統で `verify-commit-identity.sh` を呼びます。直接 push こそが混入の原因なので `push(main)` を省略しません。判定はスクリプト側にあり、ワークフローは呼ぶだけです。

### 利用側の設定手順（許可 author email）

CI に固有の email を焼き込まないため、**利用側リポジトリでリポジトリ変数を設定します**。

1. GitHub リポジトリの **Settings → Secrets and variables → Actions → Variables** を開く。
2. `ALLOWED_AUTHOR_EMAILS` という **Repository variable** を作成し、許可する author email を設定する（複数はカンマまたは空白区切り。例: `you@example.com`）。

未設定のまま CI が走ると、`verify-commit-identity.sh` は許可 email を解決できず fail-closed で失敗します（検査を素通りさせないため）。コンテナ内・手元では `.env` の `GIT_IDENTITY_EMAIL` が自動でフォールバックとして使われるため、通常は追加設定なしで `bash scripts/verify-commit-identity.sh` を実行できます。

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
| Gemini | `gemini` | `.env` の `GEMINI_API_KEY` | `--with-gemini` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | API キー不足または API/認証エラーで失敗 |
| Copilot | `copilot` | GitHub 認証（`gh` / OAuth） | `--with-copilot` 指定時に `scripts/install-ai-tools.sh`（`postCreateCommand`）で導入 | 未認証時はログインプロンプト表示またはエラー終了 |
| Codex  | `codex` | `.env` の `OPENAI_API_KEY` | 未対応（`--with-codex` は将来対応予定。現状は手動導入のみ） | バイナリ未導入または API キー未設定で失敗 |

各 AI ツールを `--with-<ai>` で選ぶと、CLI に加えて対応 VS Code 拡張が入り、設定ディレクトリ（`~/.claude` / `~/.gemini` / `~/.copilot`）が compose の named volume でリビルド間に保持されます。

### Claude の認証（コンテナ内で `/login`）

`--with-claude` では、コンテナ内で作業前に `/login` して認証します。`~/.claude` は named volume で永続するため、一度 `/login` すればリビルドをまたいで有効です。

OAuth トークン（`CLAUDE_CODE_OAUTH_TOKEN`）を `remoteEnv` へ注入する経路は**用意しません**。権限スコープが限定されてフルスペックの操作が許可されないうえ、opt-in で穴を残せる構造そのものが「黙って別アカウントの資格情報が使われる」事故を生んだ形だからです。

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python|php|rust|ruby）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `remoteEnv` は `LOCAL_WORKSPACE_FOLDER` のみを持つこと（ホスト資格情報の注入経路を作らない）
4. ベースイメージは Docker サーバーの `os/arch` から自動判定（既定: `mcr.microsoft.com/devcontainers/base:ubuntu`、必要に応じて `--base-image` で上書き可能）

## 期待される出力

装備の選択によらず常に生成するもの（`--dry-run` を付けると、この一覧が `plan:` 行としてそのまま確認できます）:

- `.devcontainer/devcontainer.json`（言語別 feature を反映。docker-compose ベースで `.devcontainer/compose.yaml` の `app` サービスを参照）
- `.devcontainer/compose.yaml`（単一サービス `app` の compose 定義。compose 利用時は feature や devcontainer.json の mounts が適用されないため、docker socket を常に明示。認証用の永続 volume は `gh` を常時、cloud / AI CLI を `--with-*` 随伴で配置）
- `.env.example`（プロジェクト固有値の雛形。`GEMINI_API_KEY` / `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL`）
- `scripts/fix-mount-owner.sh`（永続 volume のマウント先を remoteUser 所有へ戻す。`postCreateCommand` の先頭で実行）
- `scripts/install-ai-tools.sh`（`postCreateCommand` の後段で実行。`--with-<ai>` で選んだ AI CLI だけを導入する。上記「AI CLI 導入挙動」参照）
- `scripts/load-project-env.sh`（プロジェクト `.env` の優先読み込み。下記参照）
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`（永続 volume の実マウント検査を含む）
- `scripts/setup-git-identity.sh` / `scripts/verify-commit-identity.sh`（git identity ガード。下記参照）
- `.github/workflows/identity-guard.yml`（コミット identity の検証 CI。下記参照）
- `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh`（ループコーディング支援。下記参照）
- `scripts/check-no-secrets.sh`（機密混入の検知ゲート。`verify.sh` が受け入れ条件の手前で呼ぶ。下記参照）
- `.github/workflows/verify.yml`（受け入れ検証を CI で回すゲート。上記「受け入れ検証の CI ワークフロー」参照）
- `.gitignore` の managed セクション（言語構成に応じて自動更新。`--no-gitignore` で無効化）

`--with-claude` を選んだ場合は、規範の配置とは独立に次を出力します（下記「[マージ確認フック](#マージ確認フックclaude-code)」参照）。

- `scripts/confirm-merge-hook.sh`（マージ実行の前に確認を挟む PreToolUse フックの本体）
- `.claude/settings.json`（上記フックの配線。既存ファイルは既定ポリシー `skip` で温存します）
- `.claude/.gitignore`（`settings.local.json` を追跡しない）

規範を配置する場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、加えて次を出力します。

- `.ai-playbook/**`（AI 共通ルール一式。内容の正本は ai-playbook 側にあり、DCB は木ごと配置するだけです）
- `.ai-playbook/VERSION`（DCB が記録する取得元の証跡。`version=`（`--playbook-version` のタグ。未指定なら `(unspecified)`）と `source=`（解決したディレクトリまたは URL）の 2 行を持つ機械可読な key=value 形式。規範ファイルと同じ `--playbook-conflict-policy` に従うため、規範を skip した実行では VERSION も更新されません）
- `.github/project-ai-rules.md`
- `CLAUDE.md` / `.github/copilot-instructions.md`
- `scripts/second-opinion-review.sh`（第二意見レビュー。`scripts/loop-gate.sh` が存在を検出して自動で直列化します。上記「ループコーディング支援」参照）
- `.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml`（`--with-copilot-review` を併せて選択した場合のみ。2 本で 1 組。下記参照）
- `.claude/skills/intake/SKILL.md`（`--with-claude` を併せて指定した場合のみ。intake 起点スキル）

`--with-aws` / `--with-gcp` のいずれかを選択した場合は、加えて次を出力します（規範の配置は前提としません）。

- `scripts/acceptance-remote.sh`（**外部層**の受け入れ条件の雛形。宣言と実際の外部状態の一致を検証する骨格のみ。上記「受け入れ条件の二層」参照）

なお bootstrap.sh は生成先の README.md を読み書きしません。セットアップ手順を README へ追記する処理は持たないため、生成後の README への反映は利用者側の作業です。

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
| `gh pr merge` | **コマンド位置**にあるもの（行頭、または `;` `&&` `\|\|` `\|` `(` の直後。先行する環境変数代入は読み飛ばします） |
| `pulls/<n>/merge` | **かつ `--method PUT` / `-X PUT` を同じ行で指定しているもの。** `--method=PUT`（= 連結）・`-XPUT`（連結形）・`--method put`（小文字）も拾います。GET はマージ済みか調べるだけで状態を変えないため対象外です |
| `mergePullRequest` | **かつ `gh api graphql` から呼ばれているもの** |

単純な部分一致にしていないのは、`grep -rn 'mergePullRequest' .` や `git log -S 'gh pr merge'` まで確認を求めると、**内容を読まずに承認する習慣ができて機構が形だけになる**ためです。

**`.claude/settings.json` の `permissions.ask` では代替できません。** `allow` / `ask` / `deny` はコマンド名と引数文字列の**前方一致**で判定するため、次を表現できません（実測値は無害な `echo` で確認しています）。

- **同じ操作の別経路**: `gh pr merge` を対象にした規則は `gh api --method PUT .../pulls/1/merge` にも `gh api graphql` の `mergePullRequest` にも一致しません。`gh api` ごと対象にすると、状態を変えない GET まで確認を求めます。
- **引数の位置に依らない判定**: `--method PUT` が引数の途中や末尾へ来る綴りは捕捉できません（実測: `deny` 規則 `Bash(echo --method PUT:*)` は `echo --method PUT repos/o/r/pulls/1/merge` を止めますが、`echo repos/o/r/pulls/1/merge --method PUT` は素通りします）。

> **既知の限界**: これは「うっかり実行」に確認を挟む guardrail であり、**意図的な迂回を防ぐ security boundary ではありません。** 文字列照合である以上、書き方を変えれば抜けられます。`gh -R owner/repo pr merge`（`gh` とサブコマンドの間にオプションが挟まる形）/ `/usr/bin/gh pr merge`（絶対パス起動）/ `env gh pr merge`（プレフィックス）/ `bash -c "gh pr merge 1"`（引用符の内側）/ `gh api .../pulls/$N/merge`（URL の変数展開）/ `gh api graphql -F query=@q.gql`（クエリを外部ファイルから読む形）はいずれも通ります。**塞ぐたびに新しい書き方が見つかるため完全性は達成できません。** 完全であるかのように書くと実態より強い保証があると誤認させるため、限界をそのまま記録しています。なお `gh api -XPUT` / `--method=PUT` / 小文字 `put` は、意図的な迂回ではなく普通の綴りにあたるため既知の限界には含めず、上の判定が拾います。

> **副作用**: マージコマンドに見える文字列を**行頭に含む**コミットメッセージやテストは、そのままでは実行できず確認を求められます。`git commit -F <file>` のようにファイル経由で渡すか、テストスクリプトへ書き出して実行すれば回避できます。引用符の内側（`grep 'gh pr merge'`）は元から通ります。

> **`main` への直接 push は扱いません。** ブランチ保護がサーバ側で拒否するほうが確実で、ブランチ名に `main` を含む feature ブランチへの push を誤って止める副作用も避けられるためです。

> **`jq` が無くても検査を飛ばしません。** コマンドを取り出せない場合（`jq` 不在・壊れた JSON・将来のペイロード変更）はペイロード全体を検査対象にします。「取れなければ通す」にすると検査が黙って無効化され、**このフックが防ごうとしている「気づかないまま実行できる」状態そのものを再現する**ためです。出力側も同じ理由で `printf` のフォールバックを持ちます。

> **他の実行環境へ一般化できるか**: 現時点ではできません。`.claude/settings.json` の `PreToolUse` は Claude Code 固有の機構で、`--with-gemini` / `--with-copilot` に同等の「ツール実行前に判定を差し込む」配線がありません。フック本体（`scripts/confirm-merge-hook.sh`）は標準入力の JSON を読んで標準出力へ判定を返すだけなので、同種の機構を持つ実行環境が現れたら**配線だけを足せば再利用できます。** 判定ロジックを実行環境ごとに複製しない形にしてあります。

#### リモート最終ゲート（Copilot）ワークフロー
規範を配置し、かつ `--with-copilot-review` を選択した場合のみ、**要求側と確認側の 2 本**を配置します（規範 `.ai-playbook/review-workflow.md`「リモート最終ゲート」に対応）。

このフラグはリモート側だけを担い、ローカルの装備（CLI・拡張・`~/.copilot` の永続化）は入れません。ローカルの装備が必要なら `--with-copilot` を併せて指定します。逆に `--with-copilot` だけを指定した構成では、これらのワークフローは配置されません。

| ファイル | 役割 |
|---|---|
| `.github/workflows/copilot-review.yml` | **要求側。** PR 作成時（`pull_request: types: [opened]`）に一度だけ Copilot へコードレビューを要求します。`synchronize`（push 更新）では再要求しないため「1 回だけ」を機構で保証します |
| `.github/workflows/review-gate.yml` | **確認側。** 要求されたことを別の契機から確認します。要求はしません |

要求側は、フォークからの PR をスキップします。既定の `GITHUB_TOKEN` で要求できない構成では、リポジトリ Secrets に `COPILOT_REVIEW_TOKEN`（`pull-requests` 書き込み権限を持つ PAT）を設定すると自動で切り替わります。要求に失敗した場合は、切り分け手順を `::error::` で出力して実行を落とします（握り潰してスキップにはしません。リモート最終ゲートが実行されていないのに緑を出すと、偽の緑と通過の区別が付かなくなるためです）。

確認側を別に置くのは、**要求側の契機が届かないことがある**ためです。届かなければ要求側は起動せず、エラーも出ず、他のチェックは緑なので、最終ゲートだけが黙って抜けます。同じ契機を見る 2 本目では塞げないため、確認側は `opened` / `synchronize` / `reopened` / `ready_for_review` に加えて**20 分ごとの定期実行**を張ります。判定は head SHA への commit status（`review-gate`）として出します。定期実行から見た PR にはジョブの成否が紐づかず、status でなければ PR 上に何も現れないためです。`opened` の契機だけは、要求が届くまで 120 秒待ってから判定します（要求側と同時に走るため）。

> **前提**: リポジトリ所有者の Copilot サブスクリプションで「Copilot code review」が有効でないと、reviewers 要求が 422 で失敗します。`--with-copilot-review` を指定しなければ、これらのワークフローは配置されません（他ベンダーのリモートレビューを使う場合は強制されません）。

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

> **`.claude/` はディレクトリごと除外しません。** `.claude/skills/` には追跡する成果物（intake 起点スキル）が入るため、`.claude/worktrees/` だけを除外します。

> **`.terraform.lock.hcl` は追跡します。** プロバイダ版の固定に必要なため、意図して除外していません（管理セクション内にもその旨のコメントを出力します）。

> **`.claude/settings.local.json`** は管理セクションでは扱いません。`--with-claude` が配る **`.claude/.gitignore`** がこの 1 行を持ちます。`.claude/` の中で閉じる除外は `.claude/` を配る側の責務とし、同じ除外を 2 か所に持たないためです（2 か所にあると、片方だけ直したときにどちらが効いているのか読めなくなります）。`settings.local.json` には対話中に許可した操作の一覧が入るため、追跡すると**その場の判断で許可した強い操作が clone した全員へ配られます。**

> **既存プロジェクトへの影響**: 管理セクションは再実行で丸ごと置換されるため、再生成するとこれらの行が入ります。セクション外へ手書きしていた同じ内容の行はそのまま残りますが、`.gitignore` の重複は無害です。**なお `.gitignore` は既に追跡済みのファイルを追跡対象から外しません。** 既にコミットされている場合は `git rm --cached` が別途必要です。

### 生成されるスクリプトの分類（そのまま配布 / 生成時に展開）

`scripts/*.sh` の正本は `bootstrap.sh` の `get_template_content()` 内のヒアドキュメントです。テンプレートは**そのまま書き出されるもの**と、**生成時に構成へ応じて展開されるもの**の 2 種類に分かれます。生成先で内容が食い違って見えたときに、追随漏れなのか設計どおりなのかを判別できるよう、分類を明示します。

| テンプレート | 生成時の扱い | 展開されるもの |
|---|---|---|
| `scripts/check-no-secrets.sh` | そのまま書き出す | — |
| `scripts/confirm-merge-hook.sh` | そのまま書き出す | —（`--with-claude` のときだけ生成） |
| `scripts/load-project-env.sh` | そのまま書き出す | — |
| `scripts/loop-gate.sh` | そのまま書き出す | — |
| `scripts/on-attach.sh` | そのまま書き出す | — |
| `scripts/setup-git-identity.sh` | そのまま書き出す | — |
| `scripts/verify-commit-identity.sh` | そのまま書き出す | — |
| `scripts/verify.sh` | そのまま書き出す | — |
| `scripts/acceptance-remote.sh` | そのまま書き出す（`--with-aws` / `--with-gcp` 選択時のみ配置） | — |
| `scripts/acceptance.sh` | 生成時に展開 | 選択言語のマニフェストに応じた検証行。**生成後はプロジェクトが所有・編集します** |
| `scripts/fix-mount-owner.sh` | 生成時に展開 | `--with-*` で配線した永続 volume のマウント先 |
| `scripts/install-ai-tools.sh` | 生成時に展開 | `--with-<ai>` で選んだ AI CLI の導入行 |
| `scripts/post-rebuild-check.sh` | 生成時に展開 | 永続 volume の実マウント検査、選択言語ランタイム、選択装備の CLI |

- **「そのまま書き出す」側は、生成先で編集しないことを想定しています。** `--force` を付けて再実行するとテンプレートの内容へ戻ります（[再実行したときの挙動](#再実行したときの挙動)）。恒久的に変えたい場合はテンプレート側を直してください。
- **「生成時に展開」側は、生成後にプロジェクトが手を入れる前提です。** とくに `scripts/acceptance.sh` は雛形であり、プロジェクトの実態（テスト・ビルド・lint・E2E）へ合わせて書き換えることを想定しています。

- **配置されるかどうかは、この 2 分類とは別軸です。** `scripts/acceptance-remote.sh` は展開を持たない（そのまま書き出す）一方で、配置は `--with-aws` / `--with-gcp` の選択に従います。

この開発リポジトリ自身も DCB の生成物を取り込んで使っており、`scripts/` はテンプレートの写しにあたります。上表のうち**写しを持つ 7 本**（`check-no-secrets.sh` / `load-project-env.sh` / `loop-gate.sh` / `on-attach.sh` / `setup-git-identity.sh` / `verify-commit-identity.sh` / `verify.sh`）は、正本と写しがバイト一致していることを `tests/test-template-mirror.sh` が機械照合します（片方だけ直しても両方のテストが緑になり、配布物と手元が黙って食い違うため）。「生成時に展開」側はプレースホルダを持ち一致し得ないので検査対象外です。`scripts/acceptance-remote.sh` も検査対象外ですが理由が異なり、**この開発リポジトリが写しを持たない**（cloud 装備を使わないため）ので比べる相手がありません。いずれも判断と理由を同テストのコメントに残し、写しを置いた時点で一致必須へ移す判断が要ることも機械で担保しています（「検査していない」と「検査対象外と判断した」を読み分けられるようにするため）。

`scripts/confirm-merge-hook.sh` も同じく**写しを持たない**ため照合対象外です。この開発リポジトリは `.claude/settings.json` を追跡しておらず（`.gitignore` が `.claude/*` を除外し、再包含するのは `!.claude/skills/` と `!.claude/agents/` だけ）フックを配線できないため、写しだけを置くと誰も起動しないスクリプトが `scripts/` とカタログに並びます。**写しを置いた時点で「照合する相手が無い」という理由は成立しなくなるので、一致必須への付け替えを要求して落ちます。**

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

検査は 3 カテゴリです。

| カテゴリ | 検査内容 |
|---|---|
| 静的構造 | `.devcontainer/devcontainer.json` / `.env.example` / `scripts/on-attach.sh` / `scripts/fix-mount-owner.sh` / `scripts/post-rebuild-check.sh` / `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh` / `scripts/check-no-secrets.sh` の実在。`devcontainer.json` が妥当な JSON であること。**`${localEnv:` の混入が無いこと**（下記）。`dockerComposeFile` が参照する compose ファイルが実在すること |
| スクリプト検査 | 生成した各スクリプトの `bash -n` 構文検査（NG なら FAIL）と実行ビットの有無（無ければ WARN） |
| 実行時コマンドの可用性 | `bash` / `jq` / `perl` / `gh`。`devcontainer.json` の features から検出した言語ランタイム（`rust` は feature 名と実行ファイル名が異なるため `cargo` で判定。`ruby` は一致するため `ruby` で判定）。`--with-aws` / `--with-gcp` で配線した cloud CLI（`aws` / `gcloud` / `terraform`）。`docker-outside-of-docker` を配線していれば `docker`。いずれも不在は WARN |

**`${localEnv:` の検出がこの診断の中核です。** 「[資格情報の扱い](#資格情報の扱い)」で述べたホスト資格情報の非注入は、方針を書いただけでは守られません。`remoteEnv` へホスト環境変数の参照が復活していないことを doctor が機械的に検査し、見つけたら FAIL にします。作業ディレクトリの受け渡し（`${localWorkspaceFolder}`）は `localEnv` ではないため対象外です。

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

