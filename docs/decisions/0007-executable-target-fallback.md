# 0007: バイナリ解決は executable target までフォールバックする

- **状態**: 採用 (2026-08-01)

- **文脈**: #88 の分解計測 (#89) で、編集 → 反映の往復 p50 2.8 秒のうち **~1.4 秒が「未計上」**として残っていた。追跡すると、律速は検知でもビルドでもなく**バイナリ解決の恒常的な失敗**だった。

  `SwiftPMBinaryResolver.firstExecutableProduct()` は `swift package dump-package` の `products` 配列だけを見る。ところが **`products` 宣言を持たず `executableTarget` だけを書いたパッケージ — つまり example とテンプレートの標準形 — では `products` が空**になる。SwiftPM はターゲット名でバイナリを生成するので実体はあるのに、解決だけが失敗していた。

  しかもこの失敗は静かで、二重に高くついていた:

  - 失敗はキャッシュされないので、**毎リロード 2 サブプロセス** (`--show-bin-path` + `dump-package`) で ~490ms を捨てる
  - 解決できなかった子は `swift run --skip-build` フォールバックで起動され、SwiftPM のロック取得とマニフェスト再チェックに毎回 ~1.4 秒を払う

- **決定**: `products` に executable が無ければ、`dump-package` の `targets` から `type == "executable"` のターゲット名へフォールバックする (SwiftPM は `products` 宣言なしでもターゲット名でバイナリを生成する — 実出力で裏取り済み)。

  あわせて、**静かだった失敗経路すべてにログを出す**。JSON を解釈できない / executable が無い / バイナリの実体が無い、のいずれもフォールバックの理由を残す。

- **影響**: 実測 (ProbeSnapshot・debug CLI・n=5、本修正単体):

  | 指標 | 改善前 p50 | 改善後 p50 |
  |---|---|---|
  | roundtrip (編集 → 反映) | 2,767.8ms | **1,197.6ms (-57%)** |
  | relaunch_ms | 493.6 | 31.0 |
  | cold-start snapshot | 2,134.3 | 135.5 |

  #88 の目標 p50 ≤1.5s をこの 1 本で達成した。[ADR 0006](0006-fsevents-watch.md) の FSEvents 化と合わせた最終測定は main で行い Issue に記録している。

  教訓として残しておく価値があるのは数字よりも**失敗の出方**のほうで、「フォールバック経路が用意されているせいで、本来の経路が常時失敗していても機能としては動いてしまう」という形をしていた。だからこの修正の半分はログであり、以後フォールバックを足すときは理由を必ず出す。

  テストは `ScriptedProcessRunner` で `dump-package` の出力を差し替える形 (product 解決 / target フォールバック / library スキップ / executable 不在 / 実体なし / dump 失敗の 6 本)。フォールバックを一時破壊して該当 2 本が赤くなることを確認済み。
