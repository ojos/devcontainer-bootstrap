# devcontainer-bootstrap Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。旧世代（〜v0.3.1）は開発リポジトリの `docs/archive/release-notes-devcontainer-bootstrap.md` にあります。

> このファイルは公開リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。
>
> 同じ理由で、issue 参照は `ojos/ai-packages-dev#NNN` の形で書いてください。裸の `#NNN` は GitHub のオートリンクが**配布先リポジトリの issue** として解決するため、配布後は存在しない issue や無関係な issue を指します。

## v0.10.0

### Summary
- **Antigravity CLI（`agy`）を選べるようにした**（ojos/ai-packages-dev#271）。`--with-antigravity` を新設し、CLI の導入・永続化・テレメトリ無効化を配線する。ai-playbook v0.2.0 が配布した `scripts/second-opinion-review.sh --engine antigravity` は、これまで生成物では選んでも動かなかった。**機能追加のみで、既存の生成物と既存フラグの挙動は変わらない。**
- **`--with-gemini` には束ねていない**（ojos/ai-packages-dev#271）。認証手段が違う（API キー / OAuth）ため、片方だけ使う構成を機構で表現できるようにする。束ねると使わない CLI が必ず入る。
- **永続 volume は `gemini` と共有する**（ojos/ai-packages-dev#271）。`agy` は資格情報を `~/.gemini/antigravity-cli/` に置くため、`--with-gemini` / `--with-antigravity` の**どちらか一方でも指定すれば `/home/vscode/.gemini` の named volume が 1 つだけ**作られる。両方指定しても重複しない。
- **テレメトリを既定で無効化する**（ojos/ai-packages-dev#271）。`~/.gemini/antigravity-cli/settings.json` の `enableTelemetry` を `false` へマージする。冪等で非破壊、`jq` 不在と壊れた JSON では非 0 で停止する。**無効化されるのは CLI のみで、Antigravity IDE は別設定。**
- `--with-antigravity` 指定時のみ、`.env.example` へ第二意見のエンジン選択欄（`SECOND_OPINION_ENGINE`）が入る。

### Highlights

- **volume は名前まで共有する（ojos/ai-packages-dev#271）**: ディレクトリだけ共有して名前を分けると、`--with-antigravity` 単独で作った `antigravity-storage` に対し、あとから `--with-gemini` を足した構成が `gemini-storage` を見に行く。同じ場所を指しているのに別 volume へ切り替わり、**ログイン状態が消えたように見える**。名前も `gemini-storage` に寄せた。
- **重複は機構で潰す（ojos/ai-packages-dev#271）**: volume 生成の条件が「単一フラグ → 単一ディレクトリ」から外れる唯一の例外。重複したまま流すと定義・マウント・所有権修復・実マウント検査がすべて 2 行ずつになり、**compose は同じ名前の volume を 2 回定義した時点で落ちる**。併用構成で各行が 1 本であることを回帰テストで固定した。
- **`agy` は npm 配布ではない（ojos/ai-packages-dev#271。実測）**: `install_if_missing <cmd> <npm-pkg>` の同型に乗らず、配布元のインストーラを取得して `~/.local/bin/agy` へ置く。インストーラが 0 で終わりながらバイナリを置かない経路があるため、実体の有無で「PATH に無いだけ」と「置かれていない」を分け、後者は非 0 で止める。
- **テレメトリのオプトアウトは設定ファイルしか手段が無い（ojos/ai-packages-dev#271。実測）**: `AGY_*` にテレメトリ系の環境変数は無く、`DO_NOT_TRACK` も非対応（agy 1.1.11 のバイナリを実測）。`settings.json` は `agy` 自身も書く（`colorScheme` / `trustedWorkspaces` 等）ため、上書きではなくマージする。
- **`jq` の `//` は false も代替側へ落とす（ojos/ai-packages-dev#271）**: `.enableTelemetry // empty` で判定すると「既に false」を「未設定」と誤り、毎回書き込みが起きる。値を直読みする。
- **雛形の地の文へ装備名を列挙しない（ojos/ai-packages-dev#271）**: ヒアドキュメント内は構成によらず生成物へ入るため、フラグ名を列挙すると選ばれていない装備の名前が残る。「そのフラグを指定しなければ関連する記述が 1 行も入らない」を、生成物ツリー全体の検査で担保している。

### 移行

- **既存の生成物は、再生成しない限り影響を受けない。** 追加されたのはフラグ 1 つで、既存フラグの挙動は変わらない。
- `--with-antigravity` を使う場合、**`agy` は OAuth のみ**で API キーに対応しない。導入だけでは使えず、コンテナ内で対話的に `agy` を起動して初回ログインを済ませる必要がある。
- 既に `--with-gemini` で生成済みのプロジェクトへ `--with-antigravity` を足して再生成しても、**volume 名は `gemini-storage` のままなので既存のログイン状態は保持される。**

## v0.9.1

### Summary
- **この版は ai-playbook v0.2.0 以降を要求する。** 第二意見レビューの雛形が `gemini-review.sh` から `second-opinion-review.sh` へ改名されたため（ojos/ai-packages-dev#268）、生成器は新しい名前を規範パッケージから解決する。**古い規範パッケージを指すと、生成時にエラーで停止する**（雛形が見つからない）。生成される `loop-gate.sh` も新しい名前を呼ぶ。
- **機密混入検査を配布スクリプト `scripts/check-no-secrets.sh` として切り出した**（ojos/ai-packages-dev#239）。共通規範「機密をコミットしない」の機械化で、生成される `verify.sh` から直接呼ぶ。追跡前（追跡対象へ入る前に落とす）と追跡済み（CI で落とす）の 2 経路に加え、`.env.example` の値検査とキー整合の計 4 検査。
- **その機密検査が、パス名に改行を含むファイルを両経路で取りこぼしていたのを塞いだ**（ojos/ai-packages-dev#263）。列挙を NUL 区切りへ変更（`git ls-files -z` / `git status --porcelain -z`）。
- **マージ実行に確認を挟む PreToolUse フックを配布する**（ojos/ai-packages-dev#241。`--with-claude` 連動）。規範 `closer.md` が定める既定の merge 方針（手動承認）を、呼びかけではなく機構で担保する。
- **`verify.sh` を CI で回すワークフロー雛形を追加した**（ojos/ai-packages-dev#238）。両利用プロジェクトが独立に同じものを作っており、配布物の欠落だった。
- **`.env` の `GH_TOKEN` で gh 認証を PAT に固定できるようにした**（ojos/ai-packages-dev#237）。複数アカウント運用でトークンが互いに失効する問題への対処。
- **`review-gate.yml` の誤判定を timeline で塞いだ**（ojos/ai-packages-dev#235）、**生成物が素で shellcheck を通るようにし、回帰テストと shellcheck の常時装備を追加した**（ojos/ai-packages-dev#236。`load-project-env.sh` の SC2296 が severity error だった）、**`.gitignore` 管理セクションへ Claude 生成物と Terraform を追加**（ojos/ai-packages-dev#240）、**`loop-gate.sh` のレビュー範囲がベースブランチ取り込みで汚染される問題を修正**（ojos/ai-packages-dev#242）、**`setup-git-identity.sh` が system スコープの credential.helper を可視化するようにした**（ojos/ai-packages-dev#243）、**雛形の `--with-copilot` 参照を現行へ直しフラグ名を機械照合するようにした**（ojos/ai-packages-dev#245）。

### Highlights

- **機密検査は `acceptance.sh` 雛形へ入れない（ojos/ai-packages-dev#239）**: あちらはプロジェクトが所有・編集する設計で、受け入れ条件を書き足すたびに触られる。規範由来の検査をそこへ置くと、書き換えのたびに検査が消える経路ができる。`verify.sh` から直接呼ぶ。
- **検査が成立していないことを合格にしない（ojos/ai-packages-dev#239）**: git 管理外での実行、git コマンド自体の失敗、追跡ファイル 0 件は、いずれも「機密が無い」ことを意味しない。すべて失敗として扱う。出力に機密の値は出さない（パスとキー名のみ）。
- **改行を含むパス名は 2 経路とも漏れていた（ojos/ai-packages-dev#263。実測）**: git は行区切りの出力で改行をそのまま出すため、1 パスが 2 行へ割れる。「2 経路で同じ広さに保つ」（ojos/ai-packages-dev#239）は保たれていたが、その広さの外側に穴があった。NUL 区切りへ移すにあたり、`git status --porcelain` の既定が未追跡ディレクトリを `?? dir/` へ畳む点（`--untracked-files=all` で回避）と、改名が 1 レコード 2 パスになる点（`--no-renames` で回避）も塞いでいる。
- **フックは「実行できること」と「実行してよいこと」を分ける（ojos/ai-packages-dev#241）**: 対話中の許可承認によりマージコマンドが技術的に実行可能になった結果、承認を経ないまま PR がマージされた実例がある。ツール実行の前に確認を差し込める機構で担保する。

### 移行

- **ai-playbook を v0.2.0 以降へ上げてから再生成すること。** `--playbook-version` / `--playbook-from` で古い版を指したままだと、雛形が解決できず生成が停止する（ファイルを 1 つも書かずに終了する）。
- 既存の生成物を再生成する場合、`scripts/gemini-review.sh` は新しい名前 `scripts/second-opinion-review.sh` で置かれる。**旧名のファイルは自動では消えない**ので手で削除する。`.env` のキー名の移行も要る（ai-playbook v0.2.0 の「移行」を参照）。
- 再生成しない限り、既存の生成物に影響はない。

## v0.9.0

### Summary
- **破壊的変更。`--with-copilot` からリモートのレビュー機構を分離した**（ojos/ai-packages-dev#230）。`--with-copilot` は手元の開発ツール（CLI・拡張・永続 volume）だけを配線し、リモート最終ゲートのワークフローは新設した `--with-copilot-review` が担う。**`--with-copilot` だけで再生成すると、ワークフローが配置されなくなる**（下記「移行」）。
- **リモート最終ゲートが要求されないまま PR が通る穴を塞いだ**（ojos/ai-packages-dev#222）。要求側 `copilot-review.yml` に加え、要求されたことを別の契機から確認する `review-gate.yml` を配置する。**この版は ai-playbook v0.1.8 以降を要求する**（雛形の供給元が規範パッケージのため）。
- **生成される `verify-commit-identity.sh` が GitHub 由来のコミットを扱えるようになった**（ojos/ai-packages-dev#223）。web UI でのマージやメール非公開設定では author が `<login>@users.noreply.github.com` になり、従来は一律で NG になっていた。あわせて許可エントリにドメイン一括指定を追加した。**許可範囲が広がる挙動変更を含む。**
- **生成される `load-project-env.sh` が git worktree からメインの作業コピーの `.env` へ回り込むようになった**（ojos/ai-packages-dev#227）。worktree は追跡ファイルしか持たず、`.gitignore` された `.env` は複製されない。回り込みが無いと worktree 側でローカル事前ゲート（identity 検査を含む）が使えない。
- 生成される `setup-git-identity.sh` の一時ファイル名に `dcb-` 接頭辞を付けた（ojos/ai-packages-dev#227）。**挙動は不変**で、作成先の名前だけが変わる。

### 移行

**これまで `--with-copilot` + 規範の配置でワークフローを得ていた場合**は、`--with-copilot-review` を足す。それだけで従来と同じ生成結果になる。

```bash
# 従来
bootstrap.sh ... --with-copilot --with-playbook

# 移行後（同じ結果）
bootstrap.sh ... --with-copilot --with-copilot-review --with-playbook
```

- **ローカルの CLI・拡張だけが目的だった場合は、変更は不要。** `--with-copilot` の意味がローカル配線だけに縮んだ形になる。
- **既存の生成物は、再生成しない限り影響を受けない。** 配置済みの `.github/workflows/copilot-review.yml` / `.github/workflows/review-gate.yml` はそのまま残る。`--with-copilot-review` を付けずに `--force` 付きで再生成した場合も、この 2 本は削除されない（生成しないだけ）。ただし規範側の更新が反映されなくなるため、リモート最終ゲートを使い続けるなら新フラグを付けること。
- **`--with-copilot-review` は規範の配置が前提。** `--with-playbook` / `--playbook-version` / `--playbook-from` のいずれも指定せずに（または `--without-playbook` と併せて）指定すると、**ファイルを 1 つも書かずに**エラー終了する。

### Highlights

- **効く場所が違うものを 1 つのフラグで束ねない（ojos/ai-packages-dev#230）**: 分離前は「リモートのレビューゲートだけ欲しい」構成を機構で表現できなかった。ローカル装備とリモート機構は動く場所も前提条件も違う。前者はコンテナ内の開発体験、後者は GitHub 上の PR ゲートで、規範パッケージの雛形を必要とする点も異なる。
- **規範なしの指定は書き込み前に落とす（ojos/ai-packages-dev#230）**: 雛形の解決に任せると、生成物を途中まで書いてから停止する。v0.4.2 で「playbook 取得失敗時に部分生成せず書き込み前にアトミック停止」を選んだ前例に揃え、引数検証の段階で落とす。判定は既存の「規範を配置するか」のロジックを再利用しており、条件を二重に定義していない。
- **要求と確認を分ける（ojos/ai-packages-dev#222）**: `pull_request` の `opened` は配信が取りこぼされることがあり、届かなければ要求側は起動せず、エラーも出ず、他のチェックは緑になる。最終ゲートだけが黙って抜ける。`opened` を見る 2 本目を足しても塞げない（届いていないのはイベント自体）ため、確認側は定期実行を含む別の契機を張る。設計理由の正本は規範パッケージの `review-workflow.md`「要求されたことを別の契機で確認する」。
- **雛形は規範パッケージが持ち、DCB は置き先だけを決める（ojos/ai-packages-dev#222）**: `review-gate.yml` の実体は ai-playbook 側にある。この分離は `copilot-review.yml` と同じで、規範をここで再定義しない。
- **noreply 経路の許可は committer に縛る（ojos/ai-packages-dev#223）**: `is_github_authored()` は committer が `noreply@github.com` であることを必須とする。これにより GitHub 自身が作成したコミットに限定され、ローカルで作ったコミットには適用されない。許可リストへ個別 email を足して回る運用だと、メンバーが増えるたびに同じ穴が開く。
- **ドメイン一括許可は 2 形に限定する（ojos/ai-packages-dev#223）**: 解釈するのは `@example.com` と `*@example.com` だけ。任意の glob を許すと、設定ミスの `*` 1 文字で全 email が通り、検知層が黙って無効化される。`*` 単体はどちらの形にも当たらず、何も許可しない。
- **`@` を 2 つ持つ email を弾く（ojos/ai-packages-dev#223）**: 末尾一致だけで見ると `attacker@untrusted.com@example.com` が通る。git は author email を検証しないため、この形は実際に作れる。
- **正本と写しの追随漏れを機械で検知する（ojos/ai-packages-dev#227）**: `scripts/*.sh` は `bootstrap.sh` 内のヒアドキュメントが正本で、開発リポジトリ直下の `scripts/` はその写しである。両者の同期を検査する機構が無く、片方だけ直しても両方のテストが緑になっていた。実際に 2 件の追随漏れが積み上がっていた。検査は開発リポジトリ側の機構で、配布物には含まれない。

### 影響

- **`--with-copilot-review` を使う場合、規範パッケージは ai-playbook v0.1.8 以降が必要。** それより古い版を組み合わせると次で停止する。

  ```
  error: template not found in rules source: templates/review-gate.yml
         規範パッケージがこの版に必要な雛形を持っていません。
  ```

  このとき生成物は**途中まで書かれた状態で残る**。`--playbook-version v0.1.8`（以降）を指定すること。なお、この失敗の形は `review-gate.yml` に固有のものではなく、規範パッケージの雛形を要求する箇所すべてに共通する既存の挙動である。
- **`verify-commit-identity.sh` は挙動が変わる。** これまで NG になっていた GitHub 由来のコミット（committer が `noreply@github.com` かつ author が `<login>@users.noreply.github.com`）が通るようになる。ローカルの identity 適用漏れ（別アカウントの個人 email の混入）は従来どおり検知する。取り込み済みの利用側は再生成すること。
- **`load-project-env.sh` は挙動が変わる。** `.env` が生成先に無く、かつ git worktree から実行された場合に限り、メインの作業コピーの `.env` を読む。`PROJECT_ENV_FILE` を明示している場合は回り込まない。従来 `.env` を引けていた経路の挙動は変わらない。
- `setup-git-identity.sh` の変更は一時ファイル名のみで、生成物の挙動には影響しない。

## v0.8.1

### Summary
- **macOS ホストで `bootstrap.sh` が落ちる経路を塞いだ**（ojos/ai-packages-dev#218）。テンプレート引数を持たない `mktemp` / `mktemp -d` は GNU coreutils でしか動かず、BSD 系（macOS）ではテンプレートが必須で usage エラーになる。後方互換の不具合修正。
- **README の導入手順も同じ形で落ちていた**。取得と実行を一時ディレクトリで行う手順の 1 行目が素の `mktemp -d` だったため、macOS 利用者は `bootstrap.sh` を取得する前に落ちる。手順側も修正した。
- 生成物の挙動は変わらない。一時ファイル・一時ディレクトリの**作成先の名前**が変わるだけで、いずれも従来どおり実行後に削除される。

### Highlights

- **同一ファイルの中で分岐が片側だけだった（ojos/ai-packages-dev#218）**: `bootstrap.sh` は `stat` について「GNU coreutils は `-c`、BSD/macOS は `-f`」と分岐を持っており、macOS ホストでの実行は前提に入っていた。一方 `mktemp` は素のまま 8 箇所あり、macOS では**導入の最初の 1 回**で落ちる。Linux コンテナ内でしか動かさない開発では一度も表面化せず、利用者の側で初めて落ちる形になっていた。
- **書き忘れは目視では止まらなかった（ojos/ai-packages-dev#218）**: 開発リポジトリ全体では 6 ファイル 19 箇所まで積み上がっており、見つけたのは外部のレビュー。呼び出しを足すたびに人が思い出す形にせず、テンプレート無しの呼び出しを検出する検査を CI へ入れた（開発リポジトリ側の機構で、配布物には含まれない）。
- **検査は文書のコードブロックまで見る**: 実装だけを検査対象にしていたため、README の導入手順に残っていた同じ欠陥を最初の版では拾えなかった（リリース準備の段階で発見）。利用者がホストで実行するのは手順に書かれたコマンドであり、実装と同じ検査対象に置く。地の文は対象にしない（説明として `mktemp` と書く箇所があり、検査が文章の書き方に依存するため）。
- **作成先は `${TMPDIR:-/tmp}` を尊重する**: 従来どおり `TMPDIR` で作成先を変えられる。用途が読める接頭辞（`dcb-playbook` など）を付けたため、残骸が出た場合の出所も追える。

### 互換性

- 破壊的変更なし。CLI のオプション・生成物・生成物の配置はいずれも変わらない。

---

## v0.8.0

### Summary
- `--languages` に **`ruby` を第 6 の選択肢として追加**した（ojos/ai-packages-dev#206）。既存 5 言語（`node` / `go` / `python` / `php` / `rust`）と同等の生成・検査・診断・文書体験を提供する。後方互換の機能追加。
- 対応言語の README 追随漏れを機械で落とす**両方向の集合照合**を追加した。個別言語の取りこぼし検査は書いた言語しか守れず、次の言語追加で検査ごと足し忘れると素通りするため。

### Highlights

- **`--languages ruby` を追加（ojos/ai-packages-dev#206）**: `ghcr.io/devcontainers/features/ruby:1` を feature として配線し、`.gitignore` へ github/gitignore の `Ruby` テンプレートを取り込み、`doctor.sh` と生成物 `post-rebuild-check.sh` の検査対象に含める。VS Code の language server 拡張は選択時のみ `Shopify.ruby-lsp` を配線する（有料ティアを持たないため、`php` のような非配線扱いにはしない）。
- **`ruby` は feature 名と実行ファイル名が一致するため写像を持たない**: `rust` は feature が `rust` なのに実行ファイルが `cargo` / `rustc` に分かれるため `runtime_check_cmd` に `rust`→`cargo` の写像を置いている。`ruby` は一致するので分岐を追加しない。`runtime_check_cmd` は「例外だけを書く」形を保つ。
- **acceptance は `bundle exec rake` に委譲する**: ruby はテストフレームワークが Minitest / RSpec に分かれ、単一の慣習的コマンドが無い。`bundle exec rspec` や `bundle exec rake test` を既定にすると他方の流儀のプロジェクトで必ず失敗するため、`npm test` / `composer test` と同じく **プロジェクトの `Rakefile` の default タスクへ委譲**する形にした。マニフェスト判定は `Gemfile` の実在、ツール可用性の判定は `bundle`（`composer test` に対し `composer` を見る `php` と同型）。`Gemfile` が無ければ理由を出してスキップし、`Gemfile` があって `bundle` が無い場合は導入手順を添えて失敗させる（スキップと混同しない）。
- **対応言語の両方向照合を追加した**: 実装の受理値 `case` から対応言語の集合を生成し、README「言語サポート」節の箇条書きと差集合を両方向で突き合わせる。実装が受理するのに README に無い言語は「存在しない機能」になり、README にあるのに受理されない言語はコピペで即エラーになる。フラグ照合と同じ理由で片方向にしない（規範「一覧の複製は機械照合で担保する」）。
- **回帰テスト**: `tests/test-ruby-support.sh`（24 ケース）を追加。feature 配線・検査行・acceptance・gitignore ターゲット解決・拡張の条件配線・doctor 検出・入力検証を、いずれもネットワークに出ずに検証する。

### 互換性

- 破壊的変更なし。`--languages` へ選択肢が増えるだけで、既存 5 言語の挙動は変わらない。
- `ruby` を指定しない生成物には、ruby feature・`Ruby` gitignore テンプレート・`Shopify.ruby-lsp` 拡張・ruby の検査行と acceptance 行のいずれも入らない。

---

## v0.7.4

### Summary
- 生成される `scripts/loop-gate.sh` で、**push 済みブランチのときに第二意見が一度も差分を見ないまま `GATE_PASS` になる**経路を塞いだ（ojos/ai-packages-dev#198）。後方互換の不具合修正。
- v0.7.2 が塞いだ「ステージ済み差分が空のときの素通り」と同じ構造の残穴。当時は切り替え先の範囲が空になる場合を見ていなかった。

### Highlights

- **push 済みブランチでの素通りを塞ぐ（ojos/ai-packages-dev#198）**: 範囲解決は上流が設定されていれば `@{upstream}..HEAD` を組んでいたが、**push 済みのブランチでは上流と HEAD が同じコミットを指すため範囲の差分が空になる**。reviewer は空差分を「レビュー対象なし」として 0 で返すので、ゲート全体が「レビュー済み」として緑になる。実測では、修正を push した直後にゲートを回して `no diff to review (origin/<branch>..HEAD)` と `GATE_PASS` が並んで出ていた。範囲は「解決できたか」ではなく **「実際に差分があるか」** で選ぶよう改めた。上流との差分が空なら、既定ブランチの追跡枝（`origin/HEAD` / `origin/main` / `origin/master` の順に探索。名前は決め打ちしない）との**分岐点**まで戻し、ブランチ全体をレビュー対象にする。
- **起点を分岐点（merge-base）にした**: 従来の `base..HEAD` は 2 点間の比較で、既定ブランチ側に進んだコミットを「打ち消し」として差分へ混ぜる。ブランチが加えた変更だけを第二意見へ渡すため、起点を分岐点へ変更した。分岐点が求まらない（履歴が繋がっていない）場合は従来どおり追跡枝そのものを起点にする。
- **レビュー対象が本当に無い場合は明示して通過する**: 分岐点まで戻しても差分が無い状態（例: 既定ブランチを push した直後）は起こり得る。ここを一律 `GATE_FAIL` にすると、差分の無い状態でのゲート実行が落ちる。`[loop-gate] no reviewable diff; second opinion has nothing to review` を出したうえで通過させる。**黙って通すと偽の緑と区別が付かない**ため、出力での明示を伴わせる。対象が無いことが分かっている以上、reviewer は呼ばない（引数なしで呼ぶと空のステージ済み差分を見せることになり、v0.7.2 で塞いだ素通りへ戻る）。
- **空ツリーへの後退は remote が無い場合に限定した**: 起点が無いプロジェクト向けの最後の受け皿（空ツリーからの全体）は従来どおり残すが、上流や既定ブランチの追跡枝が存在する場合はそこへ落とさない。差分が無いことを理由にリポジトリ全体をレビュー対象へ広げてしまうためで、この場合は「レビュー対象なし」として扱う。
- **`gemini-review.sh` 側は変更していない**: 空差分での `exit 0` は、単体で使う場合の挙動として正しい（差分が無ければ何もしない）。ゲートとしての判断は `loop-gate.sh` が持つ、という責務分担を維持している。

### 影響

- 生成される `loop-gate.sh` の内容が変わる。既存の生成物は衝突ポリシー（`skip`/`overwrite`/`prompt`）により上書きされないため、再生成しない限り影響しない。
- **push 済みブランチでゲートを回すと、第二意見が実際に実行されるようになる**（従来は実行されずに通過していた）。ブランチ全体が対象になるため、実行時間と API 消費が増える。
- `LOOP_GATE_REVIEW_CMD` による差し替え・無効化の契約、ステージ済み差分があるときに引数を渡さない挙動、git 管理下にないプロジェクトでの挙動は変えていない。
- CLI の引数契約・生成される devcontainer の構成は変えていない。

---

## v0.7.3

### Summary
- README と実装の乖離を解消した（ojos/ai-packages-dev#170 / ojos/ai-packages-dev#171）。実装済みの CLI フラグ 3 件が未記載、実行前提コマンドが未記載、生成しないものを生成物として記載、doctor の検査項目と終了コードが未記載、といった記述誤りをまとめて直している。**生成物の挙動は変えていない。**
- `bootstrap.sh` / `doctor.sh` の usage が、開発リポジトリと公開配布物のどちらか一方でしか解決しないパスを示していた問題を修正した（ojos/ai-packages-dev#174 / ojos/ai-packages-dev#182）。
- `LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加した（ojos/ai-packages-dev#177）。あわせて README へ「配布専用リポジトリであり外部からの貢献は受け付けない」旨を明記した。
- 後方互換。

### Highlights

- **未記載だった CLI フラグを追加（ojos/ai-packages-dev#170）**: `--dry-run` / `--force` / `-h`・`--help` が README のどこにも無かった。とくに `--force` の欠落は影響が大きい。既定では既存ファイルを `skip (exists)` で温存するため、**再実行しても上書きされないことが README から読み取れなかった**。`--no-gitignore` / `--gitignore-targets` も使用例にしか現れていなかったのでオプション節へ昇格した。実行前提コマンド（`jq` / `perl` / `awk` / `sed` / `curl`、URL ソース時の `tar`）も一切書かれていなかったため追加した。不在時は即エラー終了する。
- **rust 対応の記述漏れ（ojos/ai-packages-dev#170）**: 対応言語の列挙 3 箇所から `rust` が抜けており、同一 README 内で矛盾していた（`--languages` の説明では rust を挙げている）。
- **生成物一覧を実装と一致させた（ojos/ai-packages-dev#171）**: 生成しない「README のセットアップ節更新」を削除し、常に生成される `scripts/install-ai-tools.sh` / `scripts/gemini-review.sh` と、規範配置時に作られる `.ai-playbook/VERSION` を追加した。`postCreateCommand` の記載値も実値と違っていた。
- **doctor 節の取りこぼし（ojos/ai-packages-dev#171）**: 「言語ランタイムと cloud CLI の可用性」しか説明していなかったが、実際は静的構造の存在検査・`devcontainer.json` の JSON 妥当性・**`${localEnv:` 混入の検出**・compose 参照先の実在・生成スクリプトの構文検査も行う。終了コードも未記載だった（FAIL>0 で 1、`--strict` かつ WARN>0 で **2**）。
- **リリース資産の説明（ojos/ai-packages-dev#171）**: 配布している `PACKAGE_ARCHIVE.tar.gz` と `RELEASE-MANIFEST.json` が README で一切説明されていなかった。あわせて `RELEASE-MANIFEST.json` の `assets` に、README が入手を案内する `bootstrap.sh` / `doctor.sh` が載っていなかった問題も直した。
- **usage のパス（ojos/ai-packages-dev#174 / ojos/ai-packages-dev#182）**: `doctor.sh` は固定パスで開発リポジトリの位置を出しており、公開配布物（リポジトリ直下）では解決しなかった。呼び出しに使われたパスをそのまま出す形へ変更した。`bootstrap.sh` も同様だが、usage ヒアドキュメント内に**リテラルの `$PWD`** が含まれるため、`doctor.sh` と同じく引用符を外すとヘルプの記述が壊れる。1 行目だけ分離して対処した。
- **`bootstrap.sh` の永続化に関する記述（ojos/ai-packages-dev#174）**: usage が「gh / cloud のログインは永続化されないのでリビルドのたびにやり直す必要がある」と述べていたが、実装は `gh` を常に永続化し、cloud も `--with-*` 選択時に永続化する。README のほうが正しく、usage が旧仕様のまま残っていた。
- **`CHANGELOG.md` を生成物へ持ち込まない（ojos/ai-packages-dev#177）**: 規範の配布ルートに `CHANGELOG.md` を置いたことで、`--with-playbook` の `*.md` 一括コピーが生成プロジェクトの `.ai-playbook/` へこれを取り込む状態になった。既存の `README.md` 除外と並べて除外した。

### 影響

- **生成物の内容が 1 点変わる**: `--with-playbook` で配置される `.ai-playbook/` に `CHANGELOG.md` が含まれなくなる（本来含むべきでないファイルの除外）。既存の生成物は衝突ポリシーにより上書きされないため、再生成しない限り影響しない。
- 配布物に `LICENSE` と `CHANGELOG.md` が加わる。`SHA256SUMS` の対象（`bootstrap.sh` / `doctor.sh`）は変わらない。
- `RELEASE-MANIFEST.json` の `assets` に `bootstrap.sh` / `doctor.sh` が加わる。
- CLI の引数契約・生成される devcontainer の構成は変えていない。

---

## v0.7.2

### Summary
- 生成される `scripts/loop-gate.sh` で、ステージ済み差分が空のときに第二意見が実質スキップされる経路を塞いだ（ojos/ai-packages-dev#152）。後方互換の不具合修正。
- **v0.7.1 の内容（ojos/ai-packages-dev#149）を含む。** v0.7.1 はタグを公開しないまま v0.7.2 へ統合したため、公開版としては v0.7.0 の次が v0.7.2 になる。

### Highlights
- **ステージ空での第二意見の素通りを塞ぐ（ojos/ai-packages-dev#152）**: `loop-gate.sh` の第 2 段は `gemini-review.sh` を引数なしで呼び、その既定対象はステージ済み差分だった。`gemini-review.sh` は差分が空だと「レビュー対象なし」として 0 を返すため、commit 後（ステージが空）にゲートを回すと**第二意見が実質スキップされたまま `GATE_PASS` が出ていた**。push 前ゲートとしては偽の緑になる。ステージが空のときだけ commit 済み範囲（`@{upstream}..HEAD` →無ければ `origin/HEAD` / `origin/main` / `origin/master` の順 →いずれも無ければ**空ツリー**からの全体）へ切り替える。最後の受け皿を `HEAD` にしてはならない。reviewer は範囲を `git diff` へ渡すため、`git diff HEAD` は「作業ツリー vs HEAD」となり、commit 直後はクリーンで差分が空になって素通りが復活する（`git log HEAD` が全履歴を指すのとは意味が違う）。空ツリーのハッシュはオブジェクト形式で異なるため定数を焼き込まず `git hash-object -t tree /dev/null` に計算させる。既定ブランチ名は決め打ちしない。ステージ済み差分があるときは従来どおり引数を渡さず reviewer の既定に委ねる（対象を上書きするとレビュー範囲が意図せず広がるため）。**git リポジトリでない場合・コミットが 0 件の場合も従来どおり引数なしで呼ぶ**（ここで落とすと、git 管理下にない生成直後のプロジェクトでゲートが使えなくなる）。
- 検出経路: ojos/ai-packages-dev#146 の実装中に判明し、第二意見（gemini-review）と Copilot も独立に同じ箇所を指摘した。

### 影響
- 生成される `loop-gate.sh` の内容が変わる。既存の生成物は衝突ポリシー（`skip`/`overwrite`/`prompt`）により上書きされないため、再生成しない限り影響しない。
- `LOOP_GATE_REVIEW_CMD` による差し替え・無効化の契約は変えていない。

---

## v0.7.1（未公開・v0.7.2 へ統合）

> この版はタグを公開しない。文書上の版として確定した直後に ojos/ai-packages-dev#152 が見つかったため、内容は v0.7.2 へ統合した。公開版としては v0.7.0 の次が v0.7.2 になる。記録として節を残す。

### Summary
- 生成される `scripts/verify-commit-identity.sh` で、許可 author email の解決からパス名展開（glob）を除去した（ojos/ai-packages-dev#149）。後方互換の不具合修正。

### Highlights
- **許可リストの glob 展開を除去（ojos/ai-packages-dev#149）**: 許可 email の配列代入がクォートなし（`ALLOWED_AUTHOR_EMAILS_ARR=($resolved)`）で、単語分割と同時にパス名展開も行っていた。`ALLOWED_AUTHOR_EMAILS` / `GIT_IDENTITY_EMAIL` に `*` や `?` が含まれると、許可リストが「検査対象リポジトリにどのファイルが存在するか」で変わる。実際に、ルートに author と同名のファイルを置くかどうかだけで `IDENTITY_PASS` と `IDENTITY_FAIL` が反転することを確認した。検知層の判定が検査対象の中身に左右されるのは、fail-closed 設計の意味を失わせる。`read -r -a` へ改め、単語分割だけを行わせる。here-string は末尾に改行を付けるため `set -e` 下でも `read` は 0 を返し、空文字なら空配列になって既存の fail-closed 検査に落ちる。回帰テストは「ファイルの有無で判定が変わらないこと」を検証する（片側だけでは、完全一致で落ちているのか展開が抑止されているのかを区別できないため）。

### 影響
- 生成される `verify-commit-identity.sh` の内容が変わる。既存の生成物は衝突ポリシー（`skip`/`overwrite`/`prompt`）により上書きされないため、再生成しない限り影響しない。
- 通常の email には glob メタ文字が含まれないため、既存の運用で挙動が変わることはない。

---

## v0.7.0

### Summary
- **破壊的変更**。生成物からホスト OS の資格情報を注入する経路（`remoteEnv` の `${localEnv:...}`）を全廃した。`remoteEnv` が運ぶのは `LOCAL_WORKSPACE_FOLDER` のみになり、認証はコンテナ内で行い、その状態を named volume に残す構造へ移行した（ojos/ai-packages-dev#129 / ojos/ai-packages-dev#130 / ojos/ai-packages-dev#131 / ojos/ai-packages-dev#132 / ojos/ai-packages-dev#133 / ojos/ai-packages-dev#141）。
- `--github-profiles` / `--gemini-key-env` を廃止し、`GITHUB_TOKEN_*` / `GITHUB_OWNER_*` / `GIT_AUTHOR_*_<PROFILE>` の環境変数契約を撤去した。`scripts/github-account-switch.sh` は生成しない。
- git identity の供給元をプロジェクト `.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` へ一本化し、雛形として `.env.example` を生成するようにした。
- 永続 volume を `gh` / `aws` / `gcloud` へ拡張し、所有権修復を `scripts/fix-mount-owner.sh` として独立させた。

### Highlights
- **remoteEnv からの資格情報撤去（ojos/ai-packages-dev#130）**: ホスト側と `.env` に別の値が入っていると、`.env` を読まない文脈でだけ黙ってホスト側が使われる。実際に、別アカウントの PAT が `git credential fill` から警告なく返り、別アカウントの API キーでクォータと課金が消費される事故が起きた。`remoteEnv` を `LOCAL_WORKSPACE_FOLDER` のみへ縮小し、廃止フラグは**黙殺せず**移行先を示して非ゼロ終了する（黙って無視すると「指定したのに注入されない」状態を作り、資格情報の所在をふたたび曖昧にするため）。
- **認証状態の永続化（ojos/ai-packages-dev#131）**: 注入を止めた以上、コンテナ内でのログインが唯一の認証手段になる。`gh` は github-cli feature が常時入るため `gh-storage` を常時定義し、`aws-storage` / `gcloud-storage` は `--with-aws` / `--with-gcp` に随伴する。生成する `post-rebuild-check.sh` は、定義した volume が**実際にマウントされているか**を `/proc/mounts` で検査する（定義しただけでマウントされない状態は、CLI が動くぶん気づきにくく、rebuild のたびに静かにログインが消える形で表面化するため）。
- **所有権修復の独立（ojos/ai-packages-dev#132）**: 空の named volume を初回マウントするとマウントポイントは `root:root` で作られ、`gh auth login` が Permission denied で落ちる。修復を `scripts/fix-mount-owner.sh` へ切り出し、`postCreateCommand` を `fix-mount-owner.sh && install-ai-tools.sh` の直列にした。`sudo -n` で非対話を保証し（`-n` が無いとパスワードを要求する環境で postCreate が入力待ちのまま固まる）、失敗しても WARN のうえ `exit 0` で CLI 導入まで到達する。ネストしたマウント先（`~/.config/gh` 等）の親は**非再帰**で直す（`~/.config` 配下の無関係な設定を巻き込まないため）。
- **供給元のコンテナ内集約（ojos/ai-packages-dev#133）**: `on-attach.sh` が接続ごとに `~/.docker/config.json` の `credsStore` / `credHelpers` を除去する（VS Code が接続のたびに書き込み、コンテナ内の docker がホスト OS のキーチェーンへ問い合わせるため）。git の `credential.helper` は「空 → `!gh auth git-credential`」の順で global に固定する。空文字がヘルパー一覧をリセットするため、`/etc/gitconfig` 側やエディタが注入したヘルパーが応答しなくなる。`setup-git-identity.sh --check` に、この固定順序と「local 設定を持たない一時リポジトリでの実効供給元が gh のみであること」の 2 検査を追加した。
- **`.env` への一本化（ojos/ai-packages-dev#133 / ojos/ai-packages-dev#141）**: identity は `.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` から解決する。`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` を使わないのは、それが git 自身の読む環境変数であり、環境に置くと local 未設定リポジトリでも identity が解決できて `user.useConfigOnly` の保護が無効になるため。理由は `.env.example` のコメントに残している。許可 author email の解決も、環境に値があっても必ず `.env` ローダーを通す（`.env` を唯一の供給元に保つため）。
- **doctor の secrets policy 反転（ojos/ai-packages-dev#132）**: 「`${localEnv:` 参照が**見つからない**と WARN」から「参照の**存在**を FAIL」へ改めた。撤去後の世界では、この参照はホスト資格情報の注入経路が復活したことを意味する。

### Breaking Changes
- **重大**: `--github-profiles` / `--gemini-key-env` を廃止した。指定すると非ゼロ終了で停止する。
- **重大**: `GITHUB_TOKEN_<PROFILE>` / `GITHUB_OWNER_<PROFILE>` / `GIT_AUTHOR_NAME_<PROFILE>` / `GIT_AUTHOR_EMAIL_<PROFILE>` の環境変数契約を撤去した。`scripts/github-account-switch.sh` は生成しない。
- **重大**: git identity の供給元が `.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` へ変わった。未設定のリポジトリでは `git commit` が exit 128 で止まる（設計どおり。黙って別名義で通るより止める）。
- トークン注入へ opt-in で戻す経路は用意しない。opt-in で穴を残せる構造そのものが、上記の事故を生んだ形であるため。

### 移行手順（既存の生成済みプロジェクト）
1. `.env` に `GEMINI_API_KEY` / `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL` を設定する（雛形は再生成後の `.env.example`）。
2. `bootstrap.sh` を再実行して生成物を更新する（衝突ポリシーに従う。`--github-profiles` / `--gemini-key-env` は付けない）。
3. rebuild 後、コンテナ内で `gh auth login` を 1 度実行する（以後は `gh-storage` に残る）。`--with-aws` / `--with-gcp` を使う場合は `aws sso login` / `gcloud auth login` も同様。
4. ホスト側 VS Code に `dev.containers.dockerCredentialHelper: false` を設定する（README「ホスト側 VS Code に必要な設定」参照）。
5. ホスト OS の `GITHUB_TOKEN_*` / `GITHUB_OWNER_*` / `GIT_AUTHOR_*_<PROFILE>` は不要になる。

### Verification
- [ ] preflight 全通過（DCB テストスイート全ファイル green、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.6.0

### Summary
- 開発補助として `tmux`（`ghcr.io/devcontainers-extra/features/tmux-apt-get:1`）を、`ripgrep` と同様に**常時同梱**するようにした（後方互換の機能追加。装備フラグ `--with-*` には追加しない。ojos/ai-packages-dev#115）。
- `--with-copilot` 選択時のみ、リモート最終ゲートの雛形を `.github/workflows/copilot-review.yml` として配置するようにした（後方互換の機能追加。雛形は規範パッケージが持ち、DCB は配置先だけを決める。ojos/ai-packages-dev#113）。
- 生成する `scripts/acceptance.sh` の既定を「**ルート直下にマニフェストが存在する対象だけ検証し、1 つも実行できなければ失敗する**」形へ変更した（軽微な破壊的変更。生成される既定内容が変わる。ojos/ai-packages-dev#112）。
- プロジェクト固有 `.env` を「ホスト由来の環境変数（`remoteEnv`）より後勝ちで上書き」で読み込む層を生成物へ追加した（後方互換の機能追加。ojos/ai-packages-dev#109）。
- 生成物に git identity ガード（適用・検証・CI の 3 層）を追加し、local 未設定リポジトリが黙って global へフォールバックしてコミットを通す経路を塞いだ（後方互換の機能追加。生成ファイルが増える。ojos/ai-packages-dev#108）。
- `--with-claude` 指定かつ規範導入時に、Claude Code 向け intake 起点スキルを `.claude/skills/intake/SKILL.md` へ配置するようにした（後方互換の機能追加。`--with-claude` 指定時に生成ファイルが 1 つ増える。ojos/ai-packages-dev#111）。

### Highlights
- **tmux の常時同梱（ojos/ai-packages-dev#115）**: `devcontainer.json` の features に `tmux` を追加した。既に開発補助として `ripgrep` を常時同梱している前例に整合させ、装備フラグ `--with-*`（cloud/AI ツール）へは入れない（`--mode` 廃止時に整理した `--with-*` の意味論を広げないため）。`devcontainers-extra` 名前空間は `ripgrep` で既に使用しており、新たな依存先は増えない。生成される `devcontainer.json` は妥当な JSON を保つ。
- **リモート最終ゲート雛形の配置（ojos/ai-packages-dev#113）**: `--with-copilot` を選び、かつ規範（playbook）を配置する構成のときだけ、規範パッケージの `templates/copilot-review.yml` を `.github/workflows/copilot-review.yml` へコピーする。`--with-copilot` 未指定、または規範を配置しない構成では置かない。DCB は内容を持たず配置先だけを決める（正本は規範パッケージ）。ワークフローは PR 作成時（`pull_request: types: [opened]`）に一度だけ Copilot へレビューを要求し、`synchronize` では再要求しないため「1 回だけ」を機構で保証する。フォークからの PR はスキップし、トークンは `COPILOT_REVIEW_TOKEN || GITHUB_TOKEN` へフォールバックする。既存ファイルには既存の衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う。`--dry-run` の plan 出力にも copilot 選択時のみ含める。
- **acceptance.sh のマニフェスト検出ガード（ojos/ai-packages-dev#112）**: 生成する `scripts/acceptance.sh` を、選択言語ごとに**ルート直下のマニフェスト**（`node`→`package.json`、`go`→`go.mod`、`python`→`pyproject.toml`/`requirements.txt`、`php`→`composer.json`、`rust`→`Cargo.toml`）の実在を確認してから慣習的テストを実行する形へ変更した。マニフェストが無い言語は理由を出して**スキップ**し失敗させない。マニフェストはあるがツールが無い場合は**導入手順を添えて非 0 で終了**する（「スキップ」と「実行できなかった」を混同しない）。`ran_any` ガードで、1 つも検証を実行できなければ「受け入れ条件が未定義」と出力して**非 0 で終了**する（全スキップで誤って緑になり、検証していないことを合格と報告する事故を防ぐ）。スクリプト位置からルートを解決し、起動時 CWD に依存しない。従来はどこにマニフェストが無くても選択言語のテストコマンドを無条件に直列実行していたため、monorepo・未実装段階で生成直後が必ず「テストが無くて赤い」状態になっていた。新しい既定でも生成直後は赤いままだが、「受け入れ条件が未定義だと明示して落ちる」に変わり、失敗メッセージで受け入れ条件の定義を促せる。`verify.sh` は本 issue のスコープ外で変更しない。
- **プロジェクト `.env` の優先読み込み（ojos/ai-packages-dev#109）**: 中立名の `scripts/load-project-env.sh` を常時生成する。`.env` を **`source` せず** `KEY=VALUE` のみ安全にパースして `export` するため、任意コードを実行しない（壊れた `.env` が対話シェルの初期化ごと落とす事故を防ぐ）。CWD 非依存でスクリプト位置から `.env` を解決し、bash / zsh の双方で動作する。CRLF・`export KEY=VALUE`・`KEY = VALUE`・クォート囲みを吸収し、冪等。`PROJECT_ENV_FILE` で対象ファイルを差し替え可能。生成される `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へマーカー付きで**冪等に**注入し、対話シェルから起動する CLI（`gemini` 等）にも `.env` の値を効かせる（rc 不在なら `touch` で作成、参照は絶対パス）。
- **git identity ガード（ojos/ai-packages-dev#108）**: `scripts/setup-git-identity.sh` を追加。global の `user.name` / `user.email` を削除して `user.useConfigOnly=true` を立て、local 未設定リポジトリでの `git commit` を exit 128 で停止させる。当リポジトリの local には先頭 profile（`--github-profiles` の 1 つ目）の `GIT_AUTHOR_*_<PROFILE>` を適用する。冪等で `--check` が状態を検証し、`credential.helper` は壊さない。`scripts/on-attach.sh` が毎接続で再適用する（VS Code の `copyGitConfig` がリビルドごとに `~/.gitconfig` を再生成するため）。**失敗しても on-attach 全体は落とさず**、WARN と手動確認コマンドの案内に留める。
- **git identity 検証（ojos/ai-packages-dev#108）**: `scripts/verify-commit-identity.sh` を追加。コミット履歴の identity を **email のみ**で検証する（CI と手元で共用）。許可 author email は環境変数 `ALLOWED_AUTHOR_EMAILS` を最優先し、無ければ先頭 profile の `GIT_AUTHOR_EMAIL_<PROFILE>` へフォールバック。どちらも無ければ fail-closed。committer は `noreply@github.com`、Co-Authored-By は加えて `noreply@anthropic.com` を許可。`.github/workflows/identity-guard.yml` を追加し、`pull_request` と `push`(main) の 2 系統で検証を強制する。許可 author email は生成物に焼き込まず、利用側のリポジトリ変数 `ALLOWED_AUTHOR_EMAILS`（`vars.ALLOWED_AUTHOR_EMAILS`）から渡す。判定はシェル側にあり、ワークフローは呼ぶだけ。利用側は GitHub の **Settings → Secrets and variables → Actions → Variables** に `ALLOWED_AUTHOR_EMAILS` を設定する（README「Git identity ガード」参照）。
- **Claude intake 起点スキルの配置（ojos/ai-packages-dev#111）**: `--with-claude` を選び、かつ規範（ai-playbook）を導入する場合に限り、`.claude/skills/intake/SKILL.md` を配置する。雛形の内容は DCB では持たず、規範パッケージの `templates/claude-skill-intake.md` を `require_playbook_template` で要求して置くだけにする（内容の正本を 1 つに保ち、規範側の更新に追随させる）。Claude Code の機構がスキル定義ファイル名を `SKILL.md` に固定するため、`lower-kebab-case` の雛形名から改名して配置する。`--with-claude` を指定しない、または規範を導入しない場合は `.claude/` を生成しない。雛形を持たない古い ai-playbook をソースにすると、書き込み前に `require_playbook_template` が失敗する。配置は既存の衝突ポリシー（`--playbook-conflict-policy`）に従い、`--dry-run` の plan 出力にも含める。

### Breaking Changes
- **軽微（ojos/ai-packages-dev#112）**: 生成される `scripts/acceptance.sh` の既定内容が変わる。既存の生成物は衝突ポリシー（`skip`/`overwrite`/`prompt`）により上書きされないため、再生成しない限り影響しない。
- その他はなし（後方互換の機能追加）。git identity ガードで生成ファイルが 3 つ増え、`--with-claude` 指定時にさらに `.claude/skills/intake/SKILL.md` が 1 つ増える。既存の生成物に対しては既存の衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う。

### Verification
- [ ] preflight 全通過（DCB テストスイート、`test-env-loader.sh` / `test-git-identity.sh` を含む全ファイル green、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.5.1

### Summary
- 取り込んだ ai-playbook の出所を、生成先の `.ai-playbook/VERSION` に記録するようにした（後方互換の機能追加）。

### Highlights
- `--playbook-version` などでバージョンを指定しても、生成後の環境に「どの版の playbook を取り込んだか」の on-disk 証跡が残らず、後から照合できなかった（devcontainer 自己診断 F-7）。
- 規範を配置するとき `.ai-playbook/VERSION` を生成し、`version`（`--playbook-version` のタグ。未指定は `(unspecified)`）と `source`（解決済みソース。隣接チェックアウトは `<adjacent checkout>`）を `key=value` で記録する。`--dry-run` の plan 出力にも含める。
- 書き込みは規範ファイルと同じ衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う（`apply_file_with_policy` を再利用）。既存を `skip` した on-disk 規範を温存したまま `VERSION` だけ無条件上書きすると、記録が実際の規範とずれて出所が嘘になるため。

### Breaking Changes
- なし（後方互換の機能追加）。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.5.0

### Summary
- Claude 認証を OAuth トークン注入から作業前 `/login` 既定へ変更（**破壊的変更**）。
- AI ツール永続 volume の所有権を修正し、`/login` 不能を解消（バグ修正）。

### Breaking Changes
- `--with-claude` の生成物で `remoteEnv` へ `CLAUDE_CODE_OAUTH_TOKEN` を**無条件注入する挙動を廃止**。OAuth トークンは権限スコープが限定されフルスペック操作が許可されないため、作業前に `/login` する方式を既定にした。`~/.claude` は named volume で永続するため、一度 `/login` すればリビルドをまたいで有効。
- `--claude-token-env` フラグ / `CLAUDE_TOKEN_ENV` 変数 / `__CLAUDE_TOKEN_ENV__` の sed 置換を除去。
- CI 等でトークン運用が必要な場合は、生成された `.devcontainer/devcontainer.json` の `remoteEnv` へ手動で 1 行追記する（手順は README に記載）。

### Fixes
- AI ツール用の永続 named volume（`claude-storage:/home/vscode/.claude` 等）を空の状態で初回マウントすると、マウントポイントを Docker デーモン（root）が `root:root` で作成するため、`remoteUser`（vscode）が書き込めず AI CLI のログイン/設定書き込みが失敗していた。
- `postCreateCommand`（`install-ai-tools.sh`）に `fix_owner` を追加し、選択した AI ツールの設定ディレクトリの所有者が現ユーザーと異なる場合のみ `sudo chown -R` で復旧する（冪等）。`sudo` 不在・`chown` 失敗のいずれも `set -euo pipefail` 下で postCreate を止めず、WARN を出して CLI 導入まで到達させる。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.2

### Summary
- playbook 取得失敗時に devcontainer を部分生成してから遅延失敗する不具合を修正（バグ修正）。

### Fixes
- 存在しないタグ（例: `--playbook-version` の `v` 抜け）や URL の 404、壊れたアーカイブでも、従来は devcontainer を全ファイル書き込んでから `no rule files found` で失敗していた。README が約束する「取得元が解決できなければ 1 つも書き込まず終了」に反していた。
- 原因は `detect_playbook_dir` が `curl` / `tar` の失敗を明示検査せず `set -e` に依存していたが、`PLAYBOOK_DIR="$(...)"` の代入コマンド置換では `set -e` が発火しないこと。`curl` / `tar` の明示検査、代入コマンド置換の終了コード捕捉、規範 0 件の書き込み前検査で**アトミックに停止**するよう修正。
- `--playbook-version` 使用時の取得失敗には `v` 接頭辞のヒント（例: `v0.1.1`）を表示。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.1

### Summary
- ai-playbook ソース指定の使い勝手を改善（後方互換の追加）。

### Highlights
- `--playbook-version <tag>` を追加。既定ソース `ojos/ai-playbook` のタグ tarball（`.../archive/refs/tags/<tag>.tar.gz`）へ内部展開し、長い URL を打たずに版だけで指定できる。`--playbook-from` とは相互排他。
- ソース（`--playbook-from` / `--playbook-version`）を指定した場合、`--with-playbook` を省略しても規範を配置する。判定順は「明示 opt-out（`--without-playbook`）> 明示 opt-in（`--with-playbook`）> ソース指定あり」。

### Breaking Changes
- なし。`--playbook-from` 単体は従来「無視」だったが「配置」になる（silent no-op の解消）。`--without-playbook` は最優先で従来どおり配置しない。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.0

### Summary
- `--mode <minimal|standard|full>` を廃止し、装備を `--with-*` フラグへ分解した**破壊的変更**。

### Highlights
- `--mode` 廃止（未知オプションとしてエラー）。3 mode 別テンプレを 1 つのパラメータ化テンプレへ集約し重複を解消。
- docker のリッチさ（buildx + compose-switch）を全生成物で標準化。
- cloud: `--with-aws` / `--with-gcp` を追加。Terraform はいずれかの cloud 指定時に暗黙同梱（両指定でも 1 回、cloud 無指定なら無し）。
- AI ツール: `--with-claude` / `--with-gemini` / `--with-copilot` を追加。トークンによる自動導入を廃止し明示 opt-in のみ。各フラグは CLI + VS Code 拡張 + 設定の永続化（compose named volume）を同型で実施。
- AI 認証の永続化を mode 非依存化（旧 full 限定を撤廃）。
- `doctor.sh` に cloud CLI（aws/gcloud/terraform）可用性検査を追加。

### Breaking Changes
- **`--mode` を削除**。旧 `--mode standard` は概ね `--with-aws`、旧 `--mode full` は `--with-aws --with-gcp --with-claude --with-gemini --with-copilot` に相当。移行対応表は DCB README「mode オプションからの移行」を参照。
- AI CLI（claude/gemini）の**トークンによる自動導入を廃止**。今後は `--with-<ai>` の明示指定が必要。
- docker のリッチさが全生成物で標準になったため、旧 `minimal` 相当でも buildx 等が入る。

### 予定（未実装）
- `--with-codex`（OpenAI Codex）/ `--with-sakura`（さくらのクラウド）/ `--with-cloudflare`（Cloudflare）は拡張点の枠のみ。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.3.1

### Summary
- ループコーディング支援の実行体を生成に追加。全モードで生成し、外部パッケージの導入を前提にせず単体で動作する。

### Highlights
- 生成物に `scripts/verify.sh`（受け入れ条件を非対話実行し一意な通過信号 `VERIFY_PASS` を返す接地信号）、`scripts/acceptance.sh`（プロジェクト所有の受け入れ条件。選択言語の慣習的テストコマンドを既定配置）、`scripts/loop-gate.sh`（push / PR 前のローカル事前ゲート。`verify.sh` と任意の第二意見レビューを直列化）を追加。
- `doctor.sh` がループスクリプト 3 種の存在・構文・実行権限を検査。
- README に「ループコーディング支援」節を追加。ワークフローの正本は ai-playbook の `loop-workflow.md` / 解説は `loop-coding-guide.md` を参照。`--with-playbook` の取得元を ai-playbook `v0.1.1` へ更新。

### Breaking Changes
- なし（後方互換の機能追加）。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.1.0

### Summary
- 配布リポジトリをクリーンな履歴で再作成した、新世代の初回リリース。

### Highlights
- 機能は旧世代最終版（v0.3.1）の内容をすべて含む: `--with-playbook --playbook-from <ai-playbook タグ tarball>`、`.ai-playbook/` 配置、GitHub archive 形式の構造検出、`.env` 自動読み込み、アカウント自動選択フォールバック。
- 履歴・タグ・Release を新規に作成。コミット作者情報は `Ido <ido@ojos.jp>` に統一。

### Breaking Changes
- 旧世代のタグ（v0.1.15〜v0.3.1）と Release の固定 URL は無効。取得手順の `TAG` を `v0.1.0` へ更新する。

### Verification
- [x] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [x] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）
- [x] コミット作者・コントリビューターが単一 identity であることを確認
