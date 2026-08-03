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
- `v0.9.0`

取得したスクリプトは実行前に必ず検証します。取得と実行は一時ディレクトリで行い、生成先は `--output-dir` で指定します。スクリプトの置き場所と生成先は独立しているため、実行後は `trap` で作業ディレクトリごと破棄でき、手元に取得物や後片付けが残りません。

```bash
TAG=v0.9.0
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
TAG=v0.9.0
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
TAG=v0.9.0
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
| `--with-claude` | Claude Code CLI（`@anthropic-ai/claude-code`）+ `anthropic.claude-code` 拡張 + `~/.claude` 永続化 |
| `--with-gemini` | Gemini CLI（`@google/gemini-cli`）+ `Google.gemini-cli-vscode-ide-companion` 拡張 + `~/.gemini` 永続化 |
| `--with-copilot` | GitHub Copilot CLI（`@github/copilot`）+ `github.copilot` / `github.copilot-chat` 拡張 + `~/.copilot` 永続化 |
| `--with-copilot-review` | リモート最終ゲートのワークフロー 2 本（`.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml`）。**ローカルの装備は一切入りません。** 規範の配置が前提（下記） |

- **ローカル装備とリモート機構は別フラグ**: `--with-copilot` が配線するのは手元の開発ツール（CLI・拡張・永続 volume）だけで、リモートのレビュー機構は `--with-copilot-review` が担います。効く場所が違うものを 1 つのフラグで束ねると、「リモートのレビューゲートだけ欲しい」構成を機構で表現できないためです（[リモートレビュー分離への移行](#リモートレビュー分離への移行)）。
- **`--with-copilot-review` は規範の配置が前提**: 配置するワークフローの雛形は規範パッケージが持つため、規範を配置しない構成では供給元がありません。`--with-playbook` / `--playbook-version` / `--playbook-from` のいずれも指定せずに（または `--without-playbook` と併せて）指定すると、**ファイルを 1 つも書かずに**エラー終了します。
- **Terraform は cloud 随伴**: `--with-aws` または `--with-gcp` のいずれかを指定すると、Terraform feature + `hashicorp.terraform` 拡張が **1 回だけ** 同梱されます（両指定でも 1 回、cloud 無指定なら入りません）。
- **AI ツールは明示 opt-in のみ**: `--with-<ai>` を指定したときだけ、CLI 導入・VS Code 拡張・設定ディレクトリの永続化（compose named volume）を行います。トークン有無による自動導入は行いません。
- **資格情報はホストから注入しません**: `remoteEnv` が運ぶのは作業ディレクトリのパス（`LOCAL_WORKSPACE_FOLDER`）だけです。認証はコンテナ内で行い、その状態を named volume に残します（下記「資格情報の扱い」）。

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
- `--playbook-conflict-policy` が効くのは**規範ファイル**（`.ai-playbook/**` / 入口ファイル / `scripts/gemini-review.sh` など）だけで、`.devcontainer/` や `scripts/` のテンプレート生成物には効きません。テンプレート生成物の上書きは `--force` が唯一の手段です。
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
| `scripts/gemini-review.sh` | 第二意見レビューの実行体。`scripts/loop-gate.sh` が存在すれば自動で直列化する |
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
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS` / 終了コード 0）を返す接地信号 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。`verify.sh` と、任意の第二意見レビューを直列で通す単一入口（`GATE_PASS` / 終了コード 0） |

- `acceptance.sh` は生成時、選択言語ごとに**ルート直下のマニフェストの実在を確認してから**慣習的コマンド（`node`/`package.json`→`npm test`、`go`/`go.mod`→`go test ./...`、`python`/`pyproject.toml`・`requirements.txt`→`python -m pytest`、`php`/`composer.json`→`composer test`、`rust`/`Cargo.toml`→`cargo test`、`ruby`/`Gemfile`→`bundle exec rake`）を実行します。マニフェストが無い言語は理由を出して**スキップ**し（失敗させない）、マニフェストはあるがツールが無い場合は導入手順を添えて**失敗**させます（スキップと混同しない）。1 つも検証を実行できなければ「受け入れ条件が未定義」として**非 0 で終了**します（全スキップで誤って緑になる事故を防ぐ）。スクリプト位置からルートを解決するため、起動時の作業ディレクトリに依存しません。プロジェクトの実態に合わせて編集してください。受け入れ条件が検証可能であるほど、反復が収束しやすくなります。
  - monorepo など、各言語がルート直下ではなくサブディレクトリ（例 `apps/*`）に配置される構成では、生成直後は対象が見つからず「未定義」で失敗します。これは**意図した既定**であり、実配置のマニフェストを見るよう `acceptance.sh` を編集して受け入れ条件を確定させてください。
- `verify.sh` の受け入れ定義は `VERIFY_ACCEPTANCE` 環境変数で差し替えできます。
- `loop-gate.sh` の第二意見は、`scripts/gemini-review.sh` が存在すれば直列化し、無ければ優雅にスキップします。`LOOP_GATE_REVIEW_CMD` で任意のレビューコマンドへ差し替え、空文字で無効化できます。
- これらは純粋な機構であり、規範（受け入れ検証の機械ゲート化・収束規則・verify ランナー契約）は ai-playbook の `loop-workflow.md` が正本です。規範を配置した場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、第二意見の `gemini-review.sh` も配置され、`loop-gate.sh` が自動で直列化します。

```bash
# 反復のたびに接地信号を確認する
bash scripts/verify.sh

# push / PR 前のローカル事前ゲート（受け入れ検証 + 任意の第二意見）
bash scripts/loop-gate.sh
```

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
- `common-utils` / `docker-outside-of-docker`（buildx + compose-switch を標準装備）/ `ripgrep` / `tmux` / `github-cli`

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
| 認証（GitHub / cloud / AI CLI） | **コンテナ内でのログイン**（`gh auth login` / `aws sso login` / `gcloud auth login` / `claude /login`） | named volume（`gh-storage` / `aws-storage` / `gcloud-storage` / `<ai>-storage`）。リビルドを跨いで残る |
| プロジェクト固有値（API キー・コミット identity） | **プロジェクトの `.env`**（雛形: 生成される `.env.example`） | ファイルとして目に見える。`scripts/load-project-env.sh` が読む |

`.env.example` が持つキー:

- `GEMINI_API_KEY` — 第二意見レビュー（`scripts/gemini-review.sh`）が読みます。
- `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` — コミット identity。`scripts/setup-git-identity.sh` が local へ適用します。
  - `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` という名前を使わないのは、それが **git 自身の読む環境変数**だからです。環境に置くと local 設定を持たないリポジトリでも identity が解決でき、`user.useConfigOnly` による保護（未設定なら commit を止める）が無効になります。

`GH_TOKEN` / `GITHUB_TOKEN` を恒久的に設定しないでください。gh に登録済みのアカウントより優先され、コンテナ内のログイン状態が無視されます。

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
- 対話シェルへは `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へマーカー付きで**冪等に**注入するため、ターミナルから起動する CLI（`gemini` 等）にも `.env` の値が効きます。非対話実行（`scripts/gemini-review.sh` 等）は各スクリプトが冒頭で明示的に読み込みます。

## Git identity ガード

**local 設定を持たないリポジトリは、git が黙って global へフォールバックしてコミットを通します。** 新規リポジトリを作った直後がまさにその状態で、別アカウント名義のコミットが `main` に混入する事故が起き得ます。この穴を、適用・検証・CI の 3 層で塞ぎます。

- `scripts/setup-git-identity.sh`（適用。`scripts/on-attach.sh` が毎接続で再適用）
  - global の `user.name` / `user.email` を削除し、`user.useConfigOnly=true` を立てます。これにより **local 設定を持たないリポジトリでは `git commit` が exit 128 で停止**します（黙って別名義になるより止まって気づく）。
  - 当リポジトリの local へ、`.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` を適用します。未設定なら local 適用はスキップし WARN に留めます。
  - global の `credential.helper` を「空 → `!gh auth git-credential`」の順に固定します。git はヘルパーを定義順に試し、**空文字は一覧をリセットする**ため、この順序だと `/etc/gitconfig` 側やエディタが注入したヘルパーが応答しなくなります。資格情報の供給元がコンテナ内の `gh` だけに絞られます。
  - 冪等です（2 回実行しても git config は不変）。`bash scripts/setup-git-identity.sh --check` で状態を検証できます。`--check` は identity に加えて、上記の固定順序と「local 設定を持たない一時リポジトリでの実効ヘルパーが `gh` のみであること」も検査します。`gh` を呼ばないためオフラインでも動きます。
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
- `.gitignore` の managed セクション（言語構成に応じて自動更新。`--no-gitignore` で無効化）

規範を配置する場合（`--with-playbook` / `--playbook-version` / `--playbook-from`）は、加えて次を出力します。

- `.ai-playbook/**`（AI 共通ルール一式。内容の正本は ai-playbook 側にあり、DCB は木ごと配置するだけです）
- `.ai-playbook/VERSION`（DCB が記録する取得元の証跡。`version=`（`--playbook-version` のタグ。未指定なら `(unspecified)`）と `source=`（解決したディレクトリまたは URL）の 2 行を持つ機械可読な key=value 形式。規範ファイルと同じ `--playbook-conflict-policy` に従うため、規範を skip した実行では VERSION も更新されません）
- `.github/project-ai-rules.md`
- `CLAUDE.md` / `.github/copilot-instructions.md`
- `scripts/gemini-review.sh`（第二意見レビュー。`scripts/loop-gate.sh` が存在を検出して自動で直列化します。上記「ループコーディング支援」参照）
- `.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml`（`--with-copilot-review` を併せて選択した場合のみ。2 本で 1 組。下記参照）
- `.claude/skills/intake/SKILL.md`（`--with-claude` を併せて指定した場合のみ。intake 起点スキル）

なお bootstrap.sh は生成先の README.md を読み書きしません。セットアップ手順を README へ追記する処理は持たないため、生成後の README への反映は利用者側の作業です。

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
- managed セクションの中身は `github/gitignore` から取得したテンプレートだけです（DCB 固有の静的な無視パターンは持ちません）。マーカー行で挟んだこの区間だけを差し替え、セクション外の行は保持します。
- 暗黙ターゲットは `macOS` + `--languages` で指定した言語対応テンプレート（`node`→`Node` / `go`→`Go` / `python`→`Python` / `php`→`PHP` / `rust`→`Rust` / `ruby`→`Ruby`）です。
- `--gitignore-targets <csv>` を指定すると、暗黙ターゲットに追加で合成します（重複は除去）。
- テンプレート取得は `https://github.com/github/gitignore` から行います（`<name>.gitignore` と `Global/<name>.gitignore` を順に探索）。
- 取得できないテンプレート名は警告を出してスキップします（処理は継続）。

> **注意**: `--languages` の値は小文字（`node`, `go`, `python`, `php`, `rust`, `ruby`）で指定します。一方 `--gitignore-targets` の値は [github/gitignore](https://github.com/github/gitignore) リポジトリのファイル名に合わせた大文字始まり（`Node`, `Go`, `PHP`, `Rust`, `Ruby`, `macOS` など）で指定してください。これらは別々の用途を持つため、意図的に表記が異なります。

### 生成されるスクリプトの分類（そのまま配布 / 生成時に展開）

`scripts/*.sh` の正本は `bootstrap.sh` の `get_template_content()` 内のヒアドキュメントです。テンプレートは**そのまま書き出されるもの**と、**生成時に構成へ応じて展開されるもの**の 2 種類に分かれます。生成先で内容が食い違って見えたときに、追随漏れなのか設計どおりなのかを判別できるよう、分類を明示します。

| テンプレート | 生成時の扱い | 展開されるもの |
|---|---|---|
| `scripts/load-project-env.sh` | そのまま書き出す | — |
| `scripts/loop-gate.sh` | そのまま書き出す | — |
| `scripts/on-attach.sh` | そのまま書き出す | — |
| `scripts/setup-git-identity.sh` | そのまま書き出す | — |
| `scripts/verify-commit-identity.sh` | そのまま書き出す | — |
| `scripts/verify.sh` | そのまま書き出す | — |
| `scripts/acceptance.sh` | 生成時に展開 | 選択言語のマニフェストに応じた検証行。**生成後はプロジェクトが所有・編集します** |
| `scripts/fix-mount-owner.sh` | 生成時に展開 | `--with-*` で配線した永続 volume のマウント先 |
| `scripts/install-ai-tools.sh` | 生成時に展開 | `--with-<ai>` で選んだ AI CLI の導入行 |
| `scripts/post-rebuild-check.sh` | 生成時に展開 | 永続 volume の実マウント検査、選択言語ランタイム、選択装備の CLI |

- **「そのまま書き出す」側は、生成先で編集しないことを想定しています。** `--force` を付けて再実行するとテンプレートの内容へ戻ります（[再実行したときの挙動](#再実行したときの挙動)）。恒久的に変えたい場合はテンプレート側を直してください。
- **「生成時に展開」側は、生成後にプロジェクトが手を入れる前提です。** とくに `scripts/acceptance.sh` は雛形であり、プロジェクトの実態（テスト・ビルド・lint・E2E）へ合わせて書き換えることを想定しています。

この開発リポジトリ自身も DCB の生成物を取り込んで使っており、`scripts/` はテンプレートの写しにあたります。上表の「そのまま書き出す」6 本は、正本と写しがバイト一致していることを `tests/test-template-mirror.sh` が機械照合します（片方だけ直しても両方のテストが緑になり、配布物と手元が黙って食い違うため）。「生成時に展開」側はプレースホルダを持ち一致し得ないので検査対象外とし、その判断と理由を同テストのコメントに残しています（「検査していない」と「検査対象外と判断した」を読み分けられるようにするため）。

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
| 静的構造 | `.devcontainer/devcontainer.json` / `.env.example` / `scripts/on-attach.sh` / `scripts/fix-mount-owner.sh` / `scripts/post-rebuild-check.sh` / `scripts/verify.sh` / `scripts/acceptance.sh` / `scripts/loop-gate.sh` の実在。`devcontainer.json` が妥当な JSON であること。**`${localEnv:` の混入が無いこと**（下記）。`dockerComposeFile` が参照する compose ファイルが実在すること |
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

