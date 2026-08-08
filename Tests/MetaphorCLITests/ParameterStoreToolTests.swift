import XCTest
@testable import MetaphorCLICore

/// Parameter Store（CONTRACT.md 契約点 7）の consumer 側ツールの振る舞い。
///
/// producer（スケッチ）は動かせないので、テストは「スケッチ役」を別スレッドで演じる:
/// `set-request.json` を読み、その `id` を `appliedRequestId` にエコーした
/// `params.json` を書く。
final class ParameterStoreToolTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("params-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// producer が書いたことにする `params.json`。
    @discardableResult
    private func writeParamsFile(
        in sketchDirectory: URL,
        revision: Int = 1,
        appliedRequestId: String? = nil,
        warnings: [String] = []
    ) throws -> URL {
        let root = sketchDirectory.appendingPathComponent(".metaphor/params")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "schemaVersion": 1,
            "revision": revision,
            "warnings": warnings,
            "params": [
                ["name": "radius", "type": "float", "value": 120, "min": 10, "max": 200],
                ["name": "showGrid", "type": "bool", "value": false],
            ],
        ]
        if let appliedRequestId { object["appliedRequestId"] = appliedRequestId }
        let path = root.appendingPathComponent("params.json")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        return path
    }

    /// `set-request.json` が現れたら `id` をエコーした `params.json` を書く「スケッチ役」。
    private func playSketch(
        in sketchDirectory: URL,
        revision: Int = 2,
        warnings: [String] = [],
        deadline seconds: TimeInterval = 3
    ) {
        let root = sketchDirectory.appendingPathComponent(".metaphor/params")
        let requestPath = root.appendingPathComponent("set-request.json")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if
                    let data = try? Data(contentsOf: requestPath),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let id = object["id"] as? String
                {
                    try? self.writeParamsFile(
                        in: sketchDirectory,
                        revision: revision,
                        appliedRequestId: id,
                        warnings: warnings
                    )
                    return
                }
                usleep(5_000)
            }
        }
    }

    // MARK: - params

    func testParamsReturnsStoreContents() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir, revision: 7)

        let result = ParameterStoreTool(sketchDirectory: dir).params()

        XCTAssertFalse(result.isError)
        let text = try XCTUnwrap(result.content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"radius\""))
        XCTAssertTrue(text.contains("\"revision\" : 7"))
    }

    func testParamsWithoutStoreIsError() throws {
        let dir = try makeTempDir()

        let result = ParameterStoreTool(sketchDirectory: dir).params()

        XCTAssertTrue(result.isError)
        let text = result.content.first?["text"] as? String
        XCTAssertTrue(text?.contains("@Param") == true)
    }

    // MARK: - set_param

    func testSetParamWritesAtomicRequestAndWaitsForEcho() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)
        playSketch(in: dir, revision: 9)

        let tool = ParameterStoreTool(sketchDirectory: dir, timeout: 3.0)
        let result = tool.setParam(values: ["radius": 42.5, "showGrid": true])

        XCTAssertFalse(result.isError)
        let head = try XCTUnwrap(result.content.first?["text"] as? String)
        XCTAssertTrue(head.contains("revision 9"))
        XCTAssertTrue(head.contains("拒否された項目はありません"))

        // consumer が書いた set-request.json が契約どおりの形であること。
        let root = dir.appendingPathComponent(".metaphor/params")
        let request = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("set-request.json"))
        ) as? [String: Any]
        XCTAssertNotNil(request?["id"] as? String)
        let values = try XCTUnwrap(request?["values"] as? [String: Any])
        XCTAssertEqual(values["radius"] as? Double, 42.5)
        XCTAssertEqual(values["showGrid"] as? Bool, true)
        // アトミック書込の中間ファイルは rename で消えている。
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("set-request.json.tmp").path)
        )
    }

    /// `id` はリクエストごとに変える（producer は同一 id を再処理しない）。
    func testSetParamUsesFreshIDPerRequest() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)
        let root = dir.appendingPathComponent(".metaphor/params")
        let requestPath = root.appendingPathComponent("set-request.json")
        let tool = ParameterStoreTool(sketchDirectory: dir, timeout: 1.0)

        playSketch(in: dir)
        _ = tool.setParam(values: ["radius": 1])
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: requestPath)) as? [String: Any]

        playSketch(in: dir)
        _ = tool.setParam(values: ["radius": 2])
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: requestPath)) as? [String: Any]

        XCTAssertNotEqual(first?["id"] as? String, second?["id"] as? String)
    }

    /// 拒否（未知の名前・型不一致・choices 外）は producer が warnings に載せる。
    /// consumer は「書いたつもりで書けていない」を見逃さないようエラーとして返す。
    func testSetParamSurfacesWarningsAsError() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)
        playSketch(in: dir, warnings: ["unknown parameter 'radiuss'"])

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 3.0)
            .setParam(values: ["radiuss": 42])

        XCTAssertTrue(result.isError)
        let head = try XCTUnwrap(result.content.first?["text"] as? String)
        XCTAssertTrue(head.contains("radiuss"))
    }

    func testSetParamTimesOutWhenNothingApplies() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)   // ストアはあるが「スケッチ役」は居ない

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 1.0)
            .setParam(values: ["radius": 1])

        XCTAssertTrue(result.isError)
        let text = try XCTUnwrap(result.content.first?["text"] as? String)
        XCTAssertTrue(text.contains("タイムアウト"))
    }

    /// ストアが無ければ書いても誰も読まない。タイムアウトを待たず即座に知らせる。
    func testSetParamWithoutStoreFailsFastAndWritesNothing() throws {
        let dir = try makeTempDir()
        let started = Date()

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 5.0)
            .setParam(values: ["radius": 1])

        XCTAssertTrue(result.isError)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".metaphor/params/set-request.json").path
            )
        )
    }

    /// wire 形式（param-set-request.schema.json）に無い値の形は consumer 側で弾く。
    /// 書いてしまうと producer に無視されるだけで理由が残らないため。
    func testSetParamRejectsMalformedValueBeforeWriting() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 1.0)
            .setParam(values: ["origin": ["x": 1, "y": 2]])

        XCTAssertTrue(result.isError)
        let text = try XCTUnwrap(result.content.first?["text"] as? String)
        XCTAssertTrue(text.contains("origin"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".metaphor/params/set-request.json").path
            )
        )
    }

    func testSetParamAcceptsVectorValues() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)
        playSketch(in: dir)

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 3.0)
            .setParam(values: ["origin": [320, 180], "tint": [1, 0.5, 0.25, 1]])

        XCTAssertFalse(result.isError)
    }

    func testSetParamRejectsEmptyValues() throws {
        let dir = try makeTempDir()
        try writeParamsFile(in: dir)

        let result = ParameterStoreTool(sketchDirectory: dir, timeout: 1.0).setParam(values: [:])

        XCTAssertTrue(result.isError)
    }
}
