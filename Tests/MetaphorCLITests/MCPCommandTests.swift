import Foundation
import Testing

@testable import MetaphorCLICore

/// `metaphor mcp [sketch-dir]` が単独モードで spawn する子へ渡す環境変数。
///
/// `run` / `watch` と同じく、`.metaphor/` の基準は**解決済みの絶対パス**で渡す必要がある。
/// 子の cwd は `<sketch-dir>` になるので、相対指定の `METAPHOR_STATE_DIR` をそのまま
/// 継承させると、cli（consumer）は自分の cwd 基準・子（producer）は `<sketch-dir>` 基準で
/// 解決し、別の場所を見てしまう（#133 / metaphor#688 が MCP 経路だけ残っていた）。
@Suite("metaphor mcp の子プロセス環境")
struct MCPCommandTests {

    private let sketch = URL(fileURLWithPath: "/Users/someone/sketches/strata")

    @Test("ヘッドレス起動に要るキーは従来どおり渡す")
    func keepsExistingKeys() {
        let env = MCPCommand.childEnvironment(
            for: sketch, syphonName: "strata", environment: [:])
        #expect(env["METAPHOR_VIEWER"] == "1")
        #expect(env["METAPHOR_PROBE"] == "1")
        #expect(env["METAPHOR_SYPHON_NAME"] == "strata")
    }

    @Test("METAPHOR_STATE_DIR 未指定なら sketch-dir の絶対パスを渡す")
    func defaultsToSketchDirectory() {
        let env = MCPCommand.childEnvironment(
            for: sketch, syphonName: "strata", environment: [:])
        #expect(env["METAPHOR_STATE_DIR"] == sketch.path)
    }

    @Test("相対指定は cli 自身の cwd 基準で絶対化してから渡す")
    func resolvesRelativeAgainstCLICurrentDirectory() {
        let env = MCPCommand.childEnvironment(
            for: sketch,
            syphonName: "strata",
            environment: ["METAPHOR_STATE_DIR": "state"]
        )
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("state").standardizedFileURL
        // 生の "state" のまま渡すと、子は cwd = sketch-dir 基準で解決してしまう。
        #expect(env["METAPHOR_STATE_DIR"] == expected.path)
        #expect(env["METAPHOR_STATE_DIR"] != "state")
    }

    @Test("絶対指定は sketch-dir より優先される")
    func absoluteEnvironmentWinsOverSketchDirectory() {
        let env = MCPCommand.childEnvironment(
            for: sketch,
            syphonName: "strata",
            environment: ["METAPHOR_STATE_DIR": "/tmp/state-here/"]
        )
        #expect(env["METAPHOR_STATE_DIR"] == "/tmp/state-here")
    }
}
