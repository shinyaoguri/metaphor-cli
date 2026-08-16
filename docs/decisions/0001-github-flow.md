# 0001: ブランチ運用は単一 main の GitHub Flow に戻す

- **状態**: 採用 (2026-06-21)

- **文脈**: リリースを整えるにあたって、いったん `develop` 統合 + `main` リリーストレインの二本立てを採った (#15)。日々の PR は `develop` へ集め、`develop → main` の PR に `release:patch|minor|major` を付けてマージした時だけリリースが走る、という形。

  ところが同じ日のうちに実害が出た。**Syphon.xcframework の pin bump が `develop` にしか載らない**状態になり、`main` は古い pin を指したままになった。pin は `Package.swift` の URL + checksum で、`main` からビルドされるリリースが参照するものなので、「日々の変更が届いている枝」と「出荷する枝」が別だと、この種の**片方にしか無い変更**が黙って積み上がる。実際 #18 では develop 側にしか無かった v0.3.0 への bump を main へ持ち上げる作業が必要になっている。

  そもそもこのリポジトリは単一メンテナ + エージェントの運用で、統合枝を挟んで得られるはずの「リリース前にまとめて安定させる期間」に人が入る場面が無い。`develop` は**リリースの粒度を人が決めるための待合室**だが、その判断を人がしないのなら待合室は滞留を作るだけになる。

- **決定**: `main` を唯一の長命ブランチとする GitHub Flow へ戻す。feature ブランチは `main` から切り、PR はすべて `main` 宛。CI は `main` のみで走らせ、`develop` は削除する。

  リリースは「マージした瞬間に出る」方向へ倒す。この時点ではまだ `release:*` ラベル方式 (ラベルの付いた PR をマージするとリリースが走る) を維持し、後に [ADR 0002](0002-release-from-pr-title.md) で PR タイトルからの自動判定へ進んだ。

  保護設定 (デフォルトブランチ・ruleset の対象・`develop` の削除) はリポジトリ設定側なので、PR とは別に GitHub API で適用した。

- **影響**: 「出荷する枝」と「日々の枝」が同一になり、片方にしか無い変更が構造的に発生しなくなった。リリースの粒度は人が枝で決めるのではなく、PR 単位のマージタイミングで決まる。

  代償として、**`main` は常にリリース可能でなければならない**。これは AGENTS.md の保護設定 (PR 必須 / `build-and-test` 必須 / 直 push 禁止 / squash のみ) と、赤い CI を残したままセッションを終えない運用で担保する。

  squash マージのみにしたことは後に効いてくる。squash されたコミットは既定ブランチの祖先にならないので、マージ済みローカルブランチの掃除に `git branch -d` 系の判定が使えない (この帰結は個人標準側の [claude-plugins ADR 0018](https://github.com/shinyaoguri/claude-plugins/blob/main/docs/decisions/0018-provable-branch-deletion.md) で扱っている)。
