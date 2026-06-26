import XCTest
@testable import MetaphorCLICore

final class SketchToolHandlerTests: XCTestCase {
    private final class Box {
        var lines: [String] = []
        var outcome: BuildOutcome?
    }

    private func makeHandler(
        _ box: Box,
        inputAvailable: Bool = true,
        docsRoot: URL? = nil
    ) -> SketchToolHandler {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handler-\(ProcessInfo.processInfo.globallyUniqueString)")
        return SketchToolHandler(
            snapshotTool: ProbeSnapshotTool(sketchDirectory: dir, timeout: 1.0),
            forwardInput: { box.lines.append($0) },
            buildStatusProvider: { box.outcome },
            inputAvailable: inputAvailable,
            docsRootProvider: { docsRoot }
        )
    }

    func testToolsListIncludesAllTools() {
        let names = makeHandler(Box()).tools.map(\.name)
        XCTAssertEqual(Set(names), ["snapshot", "input", "build_status", "api_reference"])
    }

    func testInputBuildsJSONLineAndForwards() throws {
        let box = Box()
        let handler = makeHandler(box)

        let result = handler.call(name: "input", arguments: [
            "type": "mouseDown", "x": 12.5, "y": 8.0, "button": 1,
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(box.lines.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(box.lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["t"] as? String, "mouseDown")
        XCTAssertEqual(object?["x"] as? Double, 12.5)
        XCTAssertEqual(object?["y"] as? Double, 8.0)
        XCTAssertEqual(object?["button"] as? Int, 1)
    }

    func testInputKeyDownCarriesCharsAndRepeat() throws {
        let box = Box()
        let handler = makeHandler(box)

        _ = handler.call(name: "input", arguments: [
            "type": "keyDown", "code": 53, "chars": "a", "repeat": false,
        ])

        let object = try JSONSerialization.jsonObject(with: Data(box.lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["t"] as? String, "keyDown")
        XCTAssertEqual(object?["code"] as? Int, 53)
        XCTAssertEqual(object?["chars"] as? String, "a")
        XCTAssertEqual(object?["repeat"] as? Bool, false)
    }

    func testInputRejectsMissingType() {
        let box = Box()
        let result = makeHandler(box).call(name: "input", arguments: ["x": 1.0])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(box.lines.isEmpty)
    }

    func testBuildStatusReportsFailureWithOutput() {
        let box = Box()
        box.outcome = BuildOutcome(succeeded: false, exitCode: 1, output: "error: boom", initial: false)
        let result = makeHandler(box).call(name: "build_status", arguments: [:])

        XCTAssertTrue(result.isError)
        let text = result.content.first?["text"] as? String
        XCTAssertTrue(text?.contains("FAILED") == true)
        XCTAssertTrue(text?.contains("error: boom") == true)
    }

    func testBuildStatusSuccessIsNotError() {
        let box = Box()
        box.outcome = BuildOutcome(succeeded: true, exitCode: 0, output: "", initial: true)
        let result = makeHandler(box).call(name: "build_status", arguments: [:])
        XCTAssertFalse(result.isError)
    }

    func testBuildStatusWithoutResult() {
        let result = makeHandler(Box()).call(name: "build_status", arguments: [:])
        XCTAssertFalse(result.isError)
    }

    // MARK: - Attach mode (shared session)

    func testInputUnavailableInAttachMode() {
        let box = Box()
        let handler = makeHandler(box, inputAvailable: false)

        let result = handler.call(name: "input", arguments: ["type": "mouseDown", "x": 1.0, "y": 2.0])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(box.lines.isEmpty)  // 何も転送しない
        let text = result.content.first?["text"] as? String
        XCTAssertTrue(text?.contains("共有セッション") == true)
    }

    func testSnapshotTimeoutCarriesBuildFailureNote() {
        // スナップショットはディレクトリが無いのでタイムアウト（isError）。直近ビルドが
        // 失敗していれば、その素性ノートが追記される。
        let box = Box()
        box.outcome = BuildOutcome(succeeded: false, exitCode: 1, output: "error: boom", initial: false)
        let result = makeHandler(box).call(name: "snapshot", arguments: [:])

        let joined = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("直近の swift build は失敗"))
    }

    func testSnapshotNoNoteWhenBuildSucceeded() {
        let box = Box()
        box.outcome = BuildOutcome(succeeded: true, exitCode: 0, output: "", initial: false)
        let result = makeHandler(box).call(name: "snapshot", arguments: [:])

        let joined = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertFalse(joined.contains("直近の swift build は失敗"))
    }

    // MARK: - api_reference

    /// docs ルートに各ファイルを置いた一時ディレクトリを作る。
    private func makeDocsRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docs-\(ProcessInfo.processInfo.globallyUniqueString)")
        let aiDir = root.appendingPathComponent("docs/ai")
        try FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        try "compact sketch guide".write(to: root.appendingPathComponent("llms-sketch.txt"), atomically: true, encoding: .utf8)
        try "ALPHA api\nBETA api\ngamma api".write(to: root.appendingPathComponent("llms.txt"), atomically: true, encoding: .utf8)
        try "examples index".write(to: aiDir.appendingPathComponent("examples-index.md"), atomically: true, encoding: .utf8)
        return root
    }

    func testAPIReferenceDefaultsToSketchDoc() throws {
        let root = try makeDocsRoot()
        let result = makeHandler(Box(), docsRoot: root).call(name: "api_reference", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.first?["text"] as? String, "compact sketch guide")
    }

    func testAPIReferenceExamplesDoc() throws {
        let root = try makeDocsRoot()
        let result = makeHandler(Box(), docsRoot: root).call(name: "api_reference", arguments: ["doc": "examples"])
        XCTAssertEqual(result.content.first?["text"] as? String, "examples index")
    }

    func testAPIReferenceGrepFiltersLines() throws {
        let root = try makeDocsRoot()
        let result = makeHandler(Box(), docsRoot: root)
            .call(name: "api_reference", arguments: ["doc": "full", "grep": "api"])
        let text = result.content.first?["text"] as? String
        XCTAssertEqual(text, "ALPHA api\nBETA api\ngamma api")

        let narrow = makeHandler(Box(), docsRoot: root)
            .call(name: "api_reference", arguments: ["doc": "full", "grep": "alpha"])
        XCTAssertEqual(narrow.content.first?["text"] as? String, "ALPHA api")  // 大小無視
    }

    func testAPIReferenceUnresolvedRoot() {
        let result = makeHandler(Box(), docsRoot: nil).call(name: "api_reference", arguments: [:])
        XCTAssertTrue(result.isError)
        let text = result.content.first?["text"] as? String
        XCTAssertTrue(text?.contains("解決できませんでした") == true)
    }

    func testAPIReferenceInvalidDoc() throws {
        let root = try makeDocsRoot()
        let result = makeHandler(Box(), docsRoot: root).call(name: "api_reference", arguments: ["doc": "nope"])
        XCTAssertTrue(result.isError)
    }

    func testAPIReferenceMissingFile() {
        // 存在するが llms-sketch.txt の無いディレクトリ。
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
        let result = makeHandler(Box(), docsRoot: empty).call(name: "api_reference", arguments: ["doc": "sketch"])
        XCTAssertTrue(result.isError)
    }
}
