# 0004: クロスリポ契約は wire schema を正典にして守る

- **状態**: 採用 (2026-07-01)

- **文脈**: `metaphor-cli` は `metaphor` をライブラリとして依存していない。両者を結んでいるのは**ランタイムの暗黙の契約**だけ — 環境変数 (`METAPHOR_VIEWER` 等)、stdin へ流す JSON Lines の入力イベント、`.metaphor/` 配下の Probe ファイル、Syphon pin。どれも型システムの外にあるので、**片側だけを変えても両方のビルドが通ってしまい、壊れるのは実行時のライブビューア**という構造だった。

  最初の手当ては「合意したトークンが両リポのファイルに在るか」の存在検査だった (#12 の `scripts/check-contract.sh` + 両リポでバイト等値な `CONTRACT.md`)。これは名前の消失は捕まえるが、**JSON の中身が食い違う**ドリフト — キーの型が変わる、必須キーが増える、値の enum が広がる — には無力。

  型を共有する案も検討されたが、cli は `request.json` を `JSONSerialization` で手組みしており、共有型にしてもコンパイル時保証は付かない。**wire schema なら decode 不要で consumer の出力そのものを機械検証できる**点が決定的な差だった。

- **決定**: wire format の JSON を**単一スキーマで正典化**する。

  - `contract/*.schema.json` を両リポで**バイト等値**に保つ。定義の正本は producer = `metaphor` 側
  - `scripts/check-contract-schema.sh` が実際の入出力をスキーマで検証する。cli 側は `ProbeRequestSchemaTests` が `snapshot` / `capture_sequence` の**実際に書いた `request.json`** を `request.schema.json` にかける (`check-jsonschema` へ shell out、未導入なら XCTSkip)
  - `scripts/check-contract-identity.sh` が共有ファイル群のバイト等値を検査する
  - 既存の `scripts/check-contract.sh` は**非 JSON の契約点に限定**して縮小する (環境変数名・Syphon pin など、スキーマで書けないもの)
  - CI に `check-jsonschema` のインストールと上記ステップを組み込む

- **影響**: 契約点に触る変更は「両リポ同時 + バイト等値」が機械的に強制される。片方だけマージすると identity ジョブが赤くなるので、背中合わせのマージ運用 (先にマージした側の push-to-main CI は一度赤くなるので re-run する) が前提になった。

  この制約は重い代わりに、エージェントが片側だけ直して「テストが通ったので完了」と報告する事故を構造的に防いでいる。AGENTS.md / CONTRACT.md が「片方だけ作業中ならもう片方に対応 PR/Issue を必ず立てる」と書いているのはこの ADR の帰結。

  スキーマで書けない契約点 (環境変数の意味論、起動順序、ラベル結合など) は存在検査に残るため、**契約の守り方は 2 系統に分かれている**。新しい契約点を足すときはどちらで守るかを選ぶ必要がある — 後に `release:patch` ラベル結合が後者へ足された ([ADR 0002](0002-release-from-pr-title.md))。
