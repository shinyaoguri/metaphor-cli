# 0008: `.metaphor/` の置き場は親が解決した絶対パスを子へ渡して一致させる

- **状態**: 採用 (2026-08-15)

- **文脈**: `.metaphor/` は cli (consumer) と子スケッチ (producer) の待ち合わせ場所で、Probe (契約点 4)・パラメータ (契約点 7)・状態ハンドオフ (契約点 8) の 3 つがここを経由する。この置き場は**スケッチディレクトリ = 子プロセスの cwd 相対**で解決していた。

  ところが `.app` に包んだスケッチを LaunchServices から起動すると (`open` / Dock / ログイン項目)、**子の cwd は `/` になる**。cli は `<sketch>/.metaphor` を、子は `/.metaphor` を見るので、`snapshot` の応答が返らない・パラメータが永続化されない、という壊れ方をする。常設運用はまさにこの形態なので、狙って使うほど壊れる。

  「両方が同じ相対パスを解釈する」という設計は、**双方の cwd が一致していることを暗黙の前提**にしていた。子の起動方法を cli が完全には制御できない以上、この前提は保てない。

- **決定**: 基準を環境変数 `METAPHOR_STATE_DIR` (CONTRACT.md 契約点 2) で明示し、**親が解決した絶対パスを子へ渡す**。

  - `MetaphorStateDirectory` が `METAPHOR_STATE_DIR` を基準に `.metaphor/` を解決する。**未設定なら従来どおりスケッチディレクトリ基準** (additive で後方互換)
  - consumer 側の 5 経路すべてが同じ基準を見る (`ProbeSnapshotTool` / `ProbeSequenceTool` / `ParameterStoreTool` / `StateHandoff` / `MetricsPoller` / `SharedSession`)
  - `metaphor run` / `watch` (ビューアあり・`--no-viewer` の両方) / `mcp` の単独モードが、**解決済みの絶対パス**を子の環境へ入れる。子の cwd が何であっても食い違わない

  「解決済みの絶対パスを渡す」ことが要点で、単に環境変数を継承させるだけでは足りない。相対指定 (`METAPHOR_STATE_DIR=state`) だと親子で同じ**文字列**を持ちながら解決基準が違い、cli は `<cli の cwd>/state/.metaphor`、子は `<sketch>/state/.metaphor` を見る。この抜けが `mcp` の単独モードにだけ残っていて後から実バグとして出た (#143)。

  `metaphor mcp <dir>` との優先順位は「`METAPHOR_STATE_DIR` が優先、未指定なら `<dir>`」とし、`--help` と README に明文化した。

- **影響**: `.app` 化したスケッチでも `snapshot` と `params` が効く。producer 側 (metaphor#704) と背中合わせでマージした ([ADR 0004](0004-wire-schema-canon.md) の identity 制約による)。

  未設定時の挙動を変えなかったので、既存のスケッチと運用は影響を受けない。代わりに**「渡していない経路」が静かなバグとして残りうる**構造になった — 実際 `mcp` 単独モードがそれで、`FoundationProcessLauncher` が親の環境をマージするために絶対指定では偶然動いてしまい、相対指定でのみ露見した。新しく子を起動する経路を足すときは、環境の組み立てを既存のヘルパ (`MCPCommand.childEnvironment(for:syphonName:environment:)` と同型) に寄せる。
