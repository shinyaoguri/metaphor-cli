import Foundation
import Testing

@testable import MetaphorCLICore

/// `.metaphor/` の基準ディレクトリ解決（CONTRACT.md 契約点 2 / metaphor#688）。
///
/// `.app` を LaunchServices から起動すると cwd が `/` になり、producer（スケッチ）と
/// consumer（cli）が別の場所を見てしまう。`METAPHOR_STATE_DIR` で基準を明示できる。
/// **未設定なら従来どおり**スケッチディレクトリ基準であることが後方互換の要。
@Suite("METAPHOR_STATE_DIR")
struct MetaphorStateDirectoryTests {

    private let sketch = URL(fileURLWithPath: "/Users/someone/sketches/strata")

    @Test("未設定ならスケッチディレクトリが基準（従来どおり）")
    func defaultsToSketchDirectory() {
        #expect(MetaphorStateDirectory.base(for: sketch, environment: [:]) == sketch)
        #expect(
            MetaphorStateDirectory.root(for: sketch, environment: [:]).path
                == "/Users/someone/sketches/strata/.metaphor")
    }

    @Test("空文字・空白だけの指定は無視する")
    func ignoresEmptyValues() {
        #expect(MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": ""]) == sketch)
        #expect(MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": "   "]) == sketch)
    }

    @Test("絶対パスの指定はそのまま基準になる")
    func absolutePathWins() {
        let base = MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": "/tmp/state-here"])
        #expect(base.path == "/tmp/state-here")
        #expect(
            MetaphorStateDirectory.root(
                for: sketch, environment: ["METAPHOR_STATE_DIR": "/tmp/state-here"]
            ).path == "/tmp/state-here/.metaphor")
    }

    @Test("末尾スラッシュや冗長な要素は正規化される")
    func normalizesPaths() {
        let base = MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": "/tmp/a/../state-here/"])
        #expect(base.path == "/tmp/state-here")
    }

    @Test("~ は展開される")
    func expandsTilde() {
        let base = MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": "~/metaphor-state"])
        #expect(base.path.hasPrefix("/"))
        #expect(base.path.hasSuffix("/metaphor-state"))
        #expect(!base.path.contains("~"))
    }

    @Test("相対指定は cli 自身の cwd 基準で絶対化する")
    func relativeResolvesAgainstCurrentDirectory() {
        let base = MetaphorStateDirectory.base(
            for: sketch, environment: ["METAPHOR_STATE_DIR": "state"])
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("state").standardizedFileURL
        #expect(base.path == expected.path)
    }
}
