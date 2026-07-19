import XCTest
@testable import MetaphorCLICore

final class MetricsPollerTests: XCTestCase {
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
            .appendingPathComponent("metrics-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makePoller(
        in dir: URL,
        responseTimeout: TimeInterval = 0.2
    ) -> MetricsPoller {
        MetricsPoller(
            sketchDirectory: dir,
            interval: 1.0,
            responseTimeout: responseTimeout,
            idPrefix: "metrics-test",
            onSample: { _ in }
        )
    }

    private func probeRoot(of dir: URL) -> URL {
        dir.appendingPathComponent(".metaphor/probe")
    }

    private func writeProbeFile(_ object: [String: Any], to relativePath: String, in dir: URL) throws {
        let url = probeRoot(of: dir).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    private func readRequestJSON(in dir: URL) throws -> [String: Any] {
        let url = probeRoot(of: dir).appendingPathComponent("request.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - pollOnce: 応答の読み取り

    func testPollOnceParsesPerformanceResponse() throws {
        let dir = try makeTempDir()
        // idPrefix と counter は決定論的なので、初回リクエスト id の応答を先置きできる。
        // frameTimeMs は producer が書くが consumer は使わない（未知キー同様に無視）。
        try writeProbeFile(
            [
                "id": "metrics-test-1",
                "schemaVersion": 4,
                "performance": [
                    "fps": 59.8,
                    "targetFPS": 60,
                    "frameTimeMs": ["mean": 4.2, "max": 9.1],
                    "memoryMB": 141.0,
                    "cpuPercent": 23.4,
                    "thermalState": "nominal",
                ],
            ],
            to: "current/frame.json", in: dir
        )

        let sample = makePoller(in: dir).pollOnce()

        guard case .metrics(let perf) = sample else {
            return XCTFail("expected .metrics, got \(sample)")
        }
        XCTAssertEqual(perf.fps, 59.8)
        XCTAssertEqual(perf.targetFPS, 60)
        XCTAssertEqual(perf.memoryMB, 141.0)
        XCTAssertEqual(perf.cpuPercent, 23.4)
        XCTAssertEqual(perf.thermalState, "nominal")
    }

    func testPollOnceReportsUnsupportedWhenPerformanceMissing() throws {
        let dir = try makeTempDir()
        // metaphor < 0.7.0 の frame.json（performance キーなし）。
        try writeProbeFile(["id": "metrics-test-1", "schemaVersion": 4], to: "current/frame.json", in: dir)

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .unsupported)
    }

    func testPollOnceTimesOutWithoutProducer() throws {
        let dir = try makeTempDir()

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .noResponse)
        // タイムアウトしてもリクエスト自体は書かれている（次の起動フレームで処理される）。
        let request = try readRequestJSON(in: dir)
        XCTAssertEqual(request["id"] as? String, "metrics-test-1")
    }

    func testRequestContainsScaleAndFreshIDPerCycle() throws {
        let dir = try makeTempDir()
        let poller = makePoller(in: dir, responseTimeout: 0.05)

        _ = poller.pollOnce()
        let first = try readRequestJSON(in: dir)
        _ = poller.pollOnce()
        let second = try readRequestJSON(in: dir)

        // PNG 書き出しコスト軽減の scale 付き（Issue #82 案 A）。
        XCTAssertEqual(first["scale"] as? Double, 0.1)
        // id はリクエストごとに必ず変える（CONTRACT.md: producer は同一 id を再処理しない）。
        XCTAssertEqual(first["id"] as? String, "metrics-test-1")
        XCTAssertEqual(second["id"] as? String, "metrics-test-2")
    }

    // MARK: - pollOnce: MCP との調停（metrics 側が譲る）

    func testPollOnceYieldsToForeignPendingRequest() throws {
        let dir = try makeTempDir()
        // MCP の snapshot リクエストが未処理（frame.json の id と不一致）。
        try writeProbeFile(["id": "mcp-999-1"], to: "request.json", in: dir)
        try writeProbeFile(["id": "older-response"], to: "current/frame.json", in: dir)

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .yielded)
        // 譲ったので MCP のリクエストを上書きしていない。
        let request = try readRequestJSON(in: dir)
        XCTAssertEqual(request["id"] as? String, "mcp-999-1")
    }

    func testPollOnceProceedsWhenForeignRequestAlreadyHandled() throws {
        let dir = try makeTempDir()
        // MCP のリクエストは処理済み（frame.json の id が一致）→ 上書きしてよい。
        try writeProbeFile(["id": "mcp-999-1"], to: "request.json", in: dir)
        try writeProbeFile(["id": "mcp-999-1"], to: "current/frame.json", in: dir)

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .noResponse)
        let request = try readRequestJSON(in: dir)
        XCTAssertEqual(request["id"] as? String, "metrics-test-1")
    }

    func testPollOnceProceedsWhenForeignSequenceAlreadyHandled() throws {
        let dir = try makeTempDir()
        // capture_sequence 完了後: 応答は sequence.json 側にあり frame.json は古いまま。
        try writeProbeFile(["id": "mcp-999-2"], to: "request.json", in: dir)
        try writeProbeFile(["id": "stale"], to: "current/frame.json", in: dir)
        try writeProbeFile(["id": "mcp-999-2"], to: "current/sequence/sequence.json", in: dir)

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .noResponse)
        let request = try readRequestJSON(in: dir)
        XCTAssertEqual(request["id"] as? String, "metrics-test-1")
    }

    func testPollOnceOverwritesOwnPreviousRequest() throws {
        let dir = try makeTempDir()
        // 自分の前回リクエストが残っている（producer 不在でタイムアウトした後）
        // のは pending ではない → 新しい id で上書きして続行する。
        try writeProbeFile(["id": "metrics-test-99"], to: "request.json", in: dir)

        XCTAssertEqual(makePoller(in: dir).pollOnce(), .noResponse)
        let request = try readRequestJSON(in: dir)
        XCTAssertEqual(request["id"] as? String, "metrics-test-1")
    }

    func testPollOnceAbortsEarlyWhenOverwrittenByForeignRequest() throws {
        let dir = try makeTempDir()
        let poller = makePoller(in: dir, responseTimeout: 5.0)

        // 応答待ち中に MCP が request.json を上書きするのを模擬。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            try? writeProbeFile(["id": "mcp-999-7"], to: "request.json", in: dir)
        }

        let started = Date()
        let sample = poller.pollOnce()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(sample, .yielded)
        // タイムアウト（5s）まで待たずに譲っている。
        XCTAssertLessThan(elapsed, 3.0)
    }
}

// MARK: - Formatter

final class MetricsFormatterTests: XCTestCase {
    func testFullLine() {
        let line = MetricsFormatter.line(ProbePerformance(
            fps: 59.8,
            targetFPS: 60,
            memoryMB: 141.2,
            cpuPercent: 23.4,
            thermalState: "nominal"
        ))
        XCTAssertEqual(line, "fps 59.8/60 │ mem 141MB │ cpu 23% │ thermal nominal")
    }

    func testMissingFPSFallsBackToDashes() {
        // noLoop 停止中・起動直後は fps が省略される契約（CONTRACT.md）。
        let line = MetricsFormatter.line(ProbePerformance(
            fps: nil,
            targetFPS: 60,
            thermalState: "nominal"
        ))
        XCTAssertEqual(line, "fps --/60 │ thermal nominal")
    }

    func testAllMissingProducesMinimalLine() {
        XCTAssertEqual(MetricsFormatter.line(ProbePerformance()), "fps --/--")
    }

    func testNonIntegerTargetFPSKeepsDecimal() {
        let line = MetricsFormatter.line(ProbePerformance(fps: 29.9, targetFPS: 29.97))
        XCTAssertEqual(line, "fps 29.9/30.0")
    }
}

// MARK: - Status line

final class MetricsStatusLineTests: XCTestCase {
    func testTTYRewritesCurrentLine() {
        var written: [String] = []
        let statusLine = MetricsStatusLine(isTTY: true, write: { written.append($0) })

        statusLine.update("a")
        statusLine.update("a")  // TTY は同一内容でも再描画（子出力で乱れた行の回復）
        statusLine.update("b")
        statusLine.finish()

        XCTAssertEqual(written, ["\r\u{1B}[2Ka", "\r\u{1B}[2Ka", "\r\u{1B}[2Kb", "\n"])
    }

    func testNonTTYLogsOnlyOnChange() {
        var written: [String] = []
        let statusLine = MetricsStatusLine(isTTY: false, write: { written.append($0) })

        statusLine.update("a")
        statusLine.update("a")
        statusLine.update("b")
        statusLine.finish()  // 非 TTY では何も出さない

        XCTAssertEqual(written, ["[metrics] a\n", "[metrics] b\n"])
    }

    func testFinishWithoutRenderWritesNothing() {
        var written: [String] = []
        MetricsStatusLine(isTTY: true, write: { written.append($0) }).finish()
        XCTAssertEqual(written, [])
    }
}
