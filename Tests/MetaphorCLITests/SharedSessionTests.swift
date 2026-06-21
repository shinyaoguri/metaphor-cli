import XCTest
@testable import MetaphorCLICore

final class SharedSessionTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shared-session-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testManifestRoundTrip() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = SharedSession.Manifest(
            pid: 4242,
            sketchPath: dir.path,
            syphonName: "metaphor-watch-1",
            probeEnabled: true,
            startedAt: "2026-06-22T00:00:00Z"
        )
        SharedSession.writeManifest(manifest, for: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: SharedSession.manifestURL(for: dir).path))
        let read = SharedSession.readManifest(for: dir)
        XCTAssertEqual(read, manifest)
        XCTAssertEqual(read?.schemaVersion, SharedSession.schemaVersion)
    }

    func testRemoveManifest() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SharedSession.writeManifest(
            .init(pid: 1, sketchPath: dir.path, syphonName: nil, probeEnabled: true, startedAt: "t"),
            for: dir
        )
        SharedSession.removeManifest(for: dir)
        XCTAssertNil(SharedSession.readManifest(for: dir))
    }

    func testReadMissingManifestIsNil() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SharedSession.readManifest(for: dir))
        XCTAssertNil(SharedSession.liveManifest(for: dir))
    }

    func testLiveManifestRequiresAlivePid() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Our own pid is alive → liveManifest returns it.
        let selfPid = ProcessInfo.processInfo.processIdentifier
        SharedSession.writeManifest(
            .init(pid: selfPid, sketchPath: dir.path, syphonName: nil, probeEnabled: true, startedAt: "t"),
            for: dir
        )
        XCTAssertNotNil(SharedSession.liveManifest(for: dir))

        // A pid that does not exist → stale → liveManifest returns nil.
        SharedSession.writeManifest(
            .init(pid: 999_999, sketchPath: dir.path, syphonName: nil, probeEnabled: true, startedAt: "t"),
            for: dir
        )
        XCTAssertNil(SharedSession.liveManifest(for: dir))
        // readManifest still returns the (stale) record.
        XCTAssertNotNil(SharedSession.readManifest(for: dir))
    }

    func testIsProcessAlive() {
        XCTAssertTrue(SharedSession.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(SharedSession.isProcessAlive(999_999))
        XCTAssertFalse(SharedSession.isProcessAlive(0))
        XCTAssertFalse(SharedSession.isProcessAlive(-1))
    }

    func testBuildStatusRoundTrip() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = BuildOutcome(succeeded: false, exitCode: 1, output: "error: boom", initial: false)
        SharedSession.writeBuildStatus(outcome, for: dir)

        let read = SharedSession.readBuildStatus(for: dir)
        XCTAssertEqual(read, outcome)
    }

    func testReadMissingBuildStatusIsNil() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SharedSession.readBuildStatus(for: dir))
    }
}
