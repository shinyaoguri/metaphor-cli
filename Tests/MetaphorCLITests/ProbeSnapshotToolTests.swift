import XCTest
@testable import MetaphorCLICore

final class ProbeSnapshotToolTests: XCTestCase {
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
            .appendingPathComponent("probe-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func testTimeoutReturnsErrorAndWritesRequest() throws {
        let dir = try makeTempDir()
        let tool = ProbeSnapshotTool(sketchDirectory: dir, timeout: 0.2)

        let result = tool.snapshot(label: nil)

        XCTAssertTrue(result.isError)
        let request = dir.appendingPathComponent(".metaphor/probe/request.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path))
        let data = try Data(contentsOf: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(object?["id"] as? String)
    }

    func testSuccessReturnsImageAndState() throws {
        let dir = try makeTempDir()
        let probeRoot = dir.appendingPathComponent(".metaphor/probe")
        let tool = ProbeSnapshotTool(sketchDirectory: dir, timeout: 3.0)

        // 別スレッドで「スケッチ役」を演じる: request.json の id を読んで frame を書く。
        DispatchQueue.global().async {
            let requestPath = probeRoot.appendingPathComponent("request.json")
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if
                    let data = try? Data(contentsOf: requestPath),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let id = object["id"] as? String
                {
                    let current = probeRoot.appendingPathComponent("current")
                    try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
                    try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: current.appendingPathComponent("frame.png"))
                    let metadata: [String: Any] = ["id": id, "frame": 1, "warnings": [String]()]
                    if let encoded = try? JSONSerialization.data(withJSONObject: metadata) {
                        try? encoded.write(to: current.appendingPathComponent("frame.json"))
                    }
                    return
                }
                usleep(5_000)
            }
        }

        let result = tool.snapshot(label: "test")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content.first?["type"] as? String, "image")
        XCTAssertEqual(result.content.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(result.content.last?["type"] as? String, "text")
    }
}
