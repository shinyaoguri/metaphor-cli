# 0002: リリースの bump は PR タイトルから自動判定し、major は自動判定しない

- **状態**: 採用 (2026-07-20)

- **文脈**: [ADR 0001](0001-github-flow.md) で単一 main に戻したあと、リリースの引き金は `release:patch|minor|major` ラベルだった。つまり**マージのたびに「これはリリースか、どの bump か」を人が判断してラベルを貼る**必要がある。

  一方この時期には Claude が PR を作る運用が定着していて、コミットと PR タイトルは Conventional Commits で書く規約になっていた。squash マージなので **PR タイトルはそのままマージコミットのメッセージになる** — 変更の種類はすでに機械可読な形でそこに書かれている。同じ情報をラベルで二度言わせているだけで、ラベルの貼り忘れは「リリースされない」という形で静かに落ちる。

- **決定**: `release-on-merge.yml` が PR タイトルの type から bump を導出する。優先順位は次のとおり:

  1. `release:skip` ラベル → リリースしない
  2. `release:major` / `release:minor` / `release:patch` ラベル → 明示上書き
  3. ラベル無し → タイトルの type から自動判定: `feat:` → minor / `fix:` `perf:` → patch / それ以外 (docs / chore / refactor / test / ci) → **リリースなし** (次の feat/fix リリースに同乗)

  **major は自動判定しない。** `feat!:` のような破壊的変更マーカーが付いていても type どおりの bump にする。理由は非対称なリスクにある — patch/minor を取り逃しても次のリリースに載るだけだが、事故で v1.0 に到達すると取り消せない。major と v1.0 到達は必ず `release:major` ラベルで人が明示する。

  `release.yml` には `concurrency` (group: release, cancel-in-progress: false) を入れて直列化する。連続マージで同一タグを二重計算する競合を防ぎ、待機中の重複リリースは最新 1 本にまとまる (ビルドは main HEAD からなので取りこぼしはない)。

- **影響**: 規約どおりのタイトルで PR を作れば、マージだけでリリースまで届く。人がリリースのために別途行う操作は無くなった。

  代償として、**PR タイトルがリリースの契約になった**。`chore:` で出した変更は出荷されない — これは意図した挙動だが、`chore:` タイトルで出る Syphon pin bump PR が「マージしたのにユーザーへ届かない」という形で問題になった。そこで `syphon-bump.yml` は bot PR に `release:patch` ラベルを貼る ([ADR 0003](0003-syphon-pin-automation.md))。

  この**ラベル 1 枚だけで繋がっている結合**はワークフローをまたぐので、どちらかを変えても気付けない。段 1 の `repository_dispatch` が同型の「黙って切れる結合」で v0.9.0 まで沈黙していた前科があるため、`scripts/check-contract.sh` が `syphon-bump.yml` (貼る側) と `release-on-merge.yml` (読む側) の両方に `release:patch` トークンが在ることを機械検査する (#117 / #118)。

  リリースが Homebrew tap まで届き切ったかどうかは、個々のワークフローの成否ではなく tap の Formula から逆算して `release-pipeline-audit.yml` が監査する (#113)。まだ知らない壊れ方も同じ 1 本で捕まえる意図。
