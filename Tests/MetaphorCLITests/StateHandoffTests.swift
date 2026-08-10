import Foundation
@testable import MetaphorCLICore
import XCTest

// MARK: - 擬似 producer（子スケッチ役）

/// `save-request.json` を監視し、`state.json` を `savedRequestId` 付きで書く擬似 producer。
///
/// 本物の producer（metaphor の `StatePlugin`）と同じ振る舞い——id をエコーして
/// アトミックに書く——だけを再現する。cli 側のテストに Metal もスケッチも要らない。
private final class FakeStateProducer {
    private let stateRoot: URL
    private let queue = DispatchQueue(label: "fake-state-producer")
    private var running = false
    /// 応答した save-request の数。
    private(set) var responses = 0

    init(sketchDirectory: URL) {
        self.stateRoot = sketchDirectory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    func start() {
        running = true
        queue.async { [self] in
            var lastHandledId: String?
            while running {
                if let id = pendingRequestId(), id != lastHandledId {
                    lastHandledId = id
                    writeState(savedRequestId: id)
                    responses += 1
                }
                usleep(2_000)
            }
        }
    }

    func stop() { running = false }

    private func pendingRequestId() -> String? {
        let url = stateRoot.appendingPathComponent("save-request.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict["id"] as? String
    }

    private func writeState(savedRequestId: String) {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "savedRequestId": savedRequestId,
            "runtime": ["frameCount": 42, "elapsedSeconds": 1.5],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let final = stateRoot.appendingPathComponent("state.json")
        let tmp = stateRoot.appendingPathComponent("state.json.tmp")
        try? data.write(to: tmp)
        try? ProbeAtomicFile.replace(tmp: tmp, final: final)
    }
}

// MARK: - Tests

final class StateHandoffTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateRoot: URL {
        directory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    func testCaptureStateReturnsPathWhenProducerEchoesId() throws {
        let producer = FakeStateProducer(sketchDirectory: directory)
        producer.start()
        defer { producer.stop() }

        let handoff = StateHandoff(sketchDirectory: directory, timeout: 2.0)
        let path = handoff.captureState()

        XCTAssertEqual(path, stateRoot.appendingPathComponent("state.json").path)
        // save-request は {id} だけを持ち、アトミックに置かれる（.tmp を残さない）。
        let requestData = try Data(contentsOf: stateRoot.appendingPathComponent("save-request.json"))
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertNotNil(request["id"] as? String)
        XCTAssertEqual(request.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateRoot.appendingPathComponent("save-request.json.tmp").path
        ))
    }

    func testCaptureStateUsesNewIdEachTime() throws {
        let producer = FakeStateProducer(sketchDirectory: directory)
        producer.start()
        defer { producer.stop() }

        let handoff = StateHandoff(sketchDirectory: directory, timeout: 2.0)
        XCTAssertNotNil(handoff.captureState())
        let first = try requestId()
        XCTAssertNotNil(handoff.captureState())
        let second = try requestId()

        XCTAssertNotEqual(first, second)  // producer は同一 id を再処理しない
    }

    func testCaptureStateTimesOutWithoutProducer() {
        let handoff = StateHandoff(sketchDirectory: directory, timeout: 0.05)
        XCTAssertNil(handoff.captureState())
    }

    func testCaptureStateIgnoresStaleStateFile() throws {
        // 前回の実行が残した state.json（別の id）は「今回の応答」ではない。
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "savedRequestId": "stale-id",
            "runtime": ["frameCount": 1, "elapsedSeconds": 0.1],
        ]).write(to: stateRoot.appendingPathComponent("state.json"))

        let handoff = StateHandoff(sketchDirectory: directory, timeout: 0.05)
        XCTAssertNil(handoff.captureState())
    }

    func testEnvironmentAddsRestorePathOnlyWhenStateExists() {
        let handoff = StateHandoff(sketchDirectory: directory)
        let base = ["METAPHOR_VIEWER": "1"]

        XCTAssertEqual(handoff.environment(base: base, statePath: nil), base)

        let withState = handoff.environment(base: base, statePath: "/tmp/state.json")
        XCTAssertEqual(withState["METAPHOR_RESTORE_STATE"], "/tmp/state.json")
        XCTAssertEqual(withState["METAPHOR_VIEWER"], "1")
    }

    private func requestId() throws -> String {
        let data = try Data(contentsOf: stateRoot.appendingPathComponent("save-request.json"))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(dict["id"] as? String)
    }
}
