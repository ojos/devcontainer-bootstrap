# DevContainer Bootstrap 使い方ガイド

## 概要
`bootstrap.sh` は、新規または既存のワークスペースに DevContainer の基本構成を一括生成するコマンドです。
このガイドでは、次の内容を説明します。

- 何を生成するか（出力物）
- どの引数を指定すればよいか（入力仕様）
- 生成後に何を確認するか（Doctor 自己診断）

まずは最小コマンドで生成し、必要に応じて言語やテンプレートオプションを追加する使い方を推奨します。

## 入力仕様

## 必須入力
- `projectName`（文字列）
- `languages`（CSV 形式。`node`、`go`、`python` を任意に組み合わせ）
- `bootstrapMode`（`minimal` | `standard` | `full`）

## オプション入力
- `--output-dir <path>`（省略時: カレントディレクトリ直下に `<project-name>/` を作成して展開）
- `--base-image <image>`（自動判定結果を上書きして明示指定）

## 言語サポート
対応ランタイム（任意の組み合わせ）:
- `node`（Node.js / JavaScript / TypeScript）
- `go`（Go）
- `python`（Python 3）

**使用例:**
```bash
# 単一言語（カレントディレクトリ直下に myapp/ を作成して展開）
./bootstrap.sh --project-name myapp --languages node --mode minimal

# 複数言語
./bootstrap.sh --project-name myapp --languages node,go,python --mode standard

# バックエンドのみ（フロントエンドなし）
./bootstrap.sh --project-name backend-api --languages go,python --mode minimal

# 出力先を明示指定したい場合
./bootstrap.sh --project-name myapp --languages node --mode standard --output-dir /path/to/existing-workspace

# .gitignore の managed セクション更新を無効化したい場合
./bootstrap.sh --project-name myapp --languages node --mode minimal --no-gitignore

# 暗黙ターゲット（macOS + 言語対応テンプレート）のみ使う場合
./bootstrap.sh --project-name myapp --languages node,python --mode standard

# 追加テンプレートを明示指定したい場合（暗黙ターゲットに追加で合成）
./bootstrap.sh --project-name myapp --languages node --mode standard --gitignore-targets macOS,Node,VisualStudioCode
```

## Feature フラグ
- `features.docker`（既定値: true）
- `features.githubCli`（既定値: true）
- `features.node`（`languages` に `node` を含む場合）
- `features.go`（`languages` に `go` を含む場合）
- `features.python`（`languages` に `python` を含む場合）
- `features.awsCli`（`full` モードのみ）
- `features.devTools`（既定値: true）

## エージェント入力
- `agent.enableMultiAgent`（真偽値）
- `agent.defaultRoles`（文字列配列）
- `agent.orchestrationMode`（`local` | `remote` | `hybrid`）

## シークレット方針
- 受け付けるのは環境変数名のみ（秘密値そのものは不可）
  - `secrets.githubTokenEnv`
  - `secrets.claudeTokenEnv`
  - `secrets.geminiKeyEnv`
- 生成される devcontainer 設定では `${localEnv:...}` 参照を必須とする。

## 検証ルール
1. `languages` には少なくとも 1 つの対応言語（node|go|python）を含めること
2. 指定した各言語に対応する feature を devcontainer.json に追加すること
3. `bootstrapMode=minimal` では `agent.enableMultiAgent=false` を許可
4. `bootstrapMode=full` では `agent.enableMultiAgent=true` を推奨
5. ベースイメージは Docker サーバーの `os/arch` から自動判定（既定: `mcr.microsoft.com/devcontainers/base:ubuntu`、必要に応じて `--base-image` で上書き可能）

## 期待される出力
- `.devcontainer/devcontainer.json`（言語別 feature を反映）
- `scripts/on-attach.sh`
- `scripts/post-rebuild-check.sh`
- `.gitignore` の managed セクション（言語構成に応じて自動更新）
- README のセットアップ節更新

### `.gitignore` と github/gitignore の連携
- managed セクション末尾には常に `github/gitignore` テンプレートを追加します。
- 暗黙ターゲットは `macOS` + `--languages` で指定した言語対応テンプレート（`node`→`Node` / `go`→`Go` / `python`→`Python`）です。
- `--gitignore-targets <csv>` を指定すると、暗黙ターゲットに追加で合成します（重複は除去）。
- テンプレート取得は `https://github.com/github/gitignore` から行います（`<name>.gitignore` と `Global/<name>.gitignore` を順に探索）。
- 取得できないテンプレート名は警告を出してスキップします（処理は継続）。

> **注意**: `--languages` の値は小文字（`node`, `go`, `python`）で指定します。一方 `--gitignore-targets` の値は [github/gitignore](https://github.com/github/gitignore) リポジトリのファイル名に合わせた大文字始まり（`Node`, `Go`, `macOS` など）で指定してください。これらは別々の用途を持つため、意図的に表記が異なります。

## Doctor 自己診断
生成後に次を実行して検証します:
```bash
./doctor.sh --target-dir result --strict
```
設定された各言語ランタイムの可用性を動的にチェックします。
