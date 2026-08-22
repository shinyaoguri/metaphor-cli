# 0014: ライブビューアは frame IPC だけで受け、Syphon.framework を同梱しない

- **状態**: 採用 (2026-08-23)

- **文脈**: `metaphor watch` のライブビューアは、子スケッチが publish する Syphon サーバーに cli が Syphon client として接続する形だった。そのために cli は Syphon.xcframework を `binaryTarget` で抱え (本体の Release asset を pin = CONTRACT.md 旧契約点 1)、tarball・Homebrew・`make install`・`update self` のすべてで **Syphon.framework を binary の隣に同梱**し、pin の追随を [0003](0003-syphon-pin-automation.md) の自動化 (dispatch + 週次ポーリング + bot PR) と `release-pipeline-audit.yml` の 4 段監査で支えていた。

  本体側は Syphon を公式プラグイン (独立リポ `metaphor-syphon`) へ分離し、親子プロセス専用の転送路として **frame IPC** (Unix domain socket + 匿名 POSIX 共有メモリ + `MTLBuffer(bytesNoCopy:)`) を持つことにした ([metaphor ADR-0014](https://github.com/shinyaoguri/metaphor/blob/main/docs/adr/0014-viewer-frame-ipc-and-syphon-plugin.md)、[metaphor#792](https://github.com/shinyaoguri/metaphor/issues/792))。親子の転送に外部アプリ向けの名前 discovery・zombie server 対策・UUID の張り替え (cli の `SyphonRecoveryPolicy`、[#139](https://github.com/shinyaoguri/metaphor-cli/issues/139)) を抱える理由が無く、xcframework の pin 連鎖 (bot PR は 2 か月で 11 本) が本体の週次トレインを重くしていたため。

  cli 側は 3 段で移った: C0 で `FrameSource` を切り出して窓から Syphon 型を外し (#169)、C1 で consumer (`CMetaphorFrameIPC` / `FrameIPCListener` / `ViewerSlotTracker` / `FrameIPCSource`) を実装して `Package.swift` から binaryTarget を外し (#171、契約点 1 の廃止と契約点 5 の書き換えを本体 #1047 と同時に)、C2 = 本 ADR で配布機構から Syphon.framework を外した。

- **決定**:

  1. **ビューアの転送路は frame IPC だけ** (dual transport を持たない)。`hello` を送ってこない古い本体 (< 0.11.0) をリンクしたスケッチには、窓の overlay で「本体の版を上げる」案内を出す (`BuildInfo.minimumMetaphorVersionForViewer`)。利用者がまだ少ないうちに互換窓を作らない
  2. **Syphon.framework を同梱しない**。tarball は `metaphor` + `templates`、Homebrew Formula は `libexec.install` の binary と `bin.install_symlink`、`update self` は binary + templates の置換とロールバック。**libexec + bin symlink のレイアウトは維持する** (全導入経路で実体の場所が 1 つに揃い、`update self` が symlink を辿って置き換えられる)
  3. **契約点 1 (Syphon pin) と pin 自動化を廃止**。`syphon-bump.yml` を削除し、[0003](0003-syphon-pin-automation.md) を廃止。`release-pipeline-audit.yml` は「cli の最新リリースが tap の Formula に届いたか」の 1 段だけを見る
  4. MadMapper / Resolume 等への Syphon 出力は本体側の公式プラグイン `metaphor-syphon` の責務になる。cli は `--syphon` / `--syphon-name` で `METAPHOR_SYPHON_NAME` を渡すだけで、framework を持たない

- **影響**:

  - `brew install` / `scripts/install.sh` / `update self` の成果物が binary + templates だけになり、Syphon.framework の置き場・rpath・再署名の配慮が消えた。旧版が残した `libexec/metaphor/Syphon.framework` は install スクリプトが消す
  - `watch --viewer` は本体 **0.11.0 以上**を要求する。古い本体では子は動くがフレームが届かず、窓は案内を出す (overlay)。`doctor` の Syphon.framework 検査は C1 で削除済み
  - 本体リリースに cli が追随する理由が無くなり、cli のリリースは cli 自身の変更だけで決まる。本体 → cli の連鎖 (dispatch・pin bump・`release:patch` ラベル結合) を機械検査していた `check-contract.sh` の項目も C1 で外れた
  - GitHub App (`metaphor-tap-publisher`) の用途は tap への Formula PR だけに戻った (install 先は `homebrew-tap` だけで足りる)
  - 解像度・色空間・向きは契約点 5 の `hello` が運ぶ。v1 は `bgra8Unorm` / premultiplied / row 0 = top で、HDR は additive に足す
