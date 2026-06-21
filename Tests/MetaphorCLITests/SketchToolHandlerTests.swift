import XCTest
@testable import MetaphorCLICore

final class SketchToolHandlerTests: XCTestCase {
    private final class Box {
        var lines: [String] = []
        var outcome: BuildOutcome?
    }

    private func makeHandler(_ box: Box, inputAvailable: Bool = true) -> SketchToolHandler {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handler-\(ProcessInfo.processInfo.globallyUniqueString)")
        return SketchToolHandler(
            snapshotTool: ProbeSnapshotTool(sketchDirectory: dir, timeout: 1.0),
            forwardInput: { box.lines.append($0) },
            buildStatusProvider: { box.outcome },
            inputAvailable: inputAvailable
        )
    }

    func testToolsListIncludesAllThree() {
        let names = makeHandler(Box()).tools.map(\.name)
        XCTAssertEqual(Set(names), ["snapshot", "input", "build_status"])
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
}
