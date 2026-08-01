import Foundation
@testable import MetaphorCLICore
import XCTest

/// `FSEventsFileWatcher` の実ファイルシステム統合テスト。
/// FSEvents の配送は非同期なので expectation + 余裕のあるタイムアウトで待つ。
final class FileWatchingTests: XCTestCase {

    private var directory: URL!
    private var watcher: FSEventsFileWatcher?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "let a = 1\n".write(
            to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testDetectsSwiftEdit() throws {
        let fired = expectation(description: "変更検知")
        fired.assertForOverFulfill = false  // 連続イベントの合流は環境依存
        let watcher = FSEventsFileWatcher(directory: directory)
        self.watcher = watcher
        try watcher.start { fired.fulfill() }

        // ストリーム開始後の編集だけを検知対象にしたいので一拍置く。
        Thread.sleep(forTimeInterval: 0.3)
        try "let a = 2\n".write(
            to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 5.0)
    }

    func testDetectsNewSwiftFile() throws {
        let fired = expectation(description: "新規ファイル検知")
        fired.assertForOverFulfill = false
        let watcher = FSEventsFileWatcher(directory: directory)
        self.watcher = watcher
        try watcher.start { fired.fulfill() }

        Thread.sleep(forTimeInterval: 0.3)
        try "let b = 2\n".write(
            to: directory.appendingPathComponent("Extra.swift"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 5.0)
    }

    func testIgnoresBuildDirectoryChanges() throws {
        // `.build` 配下（ビルド生成物）の変化では再ビルドを発火しない。
        let buildDir = directory.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let fired = expectation(description: "発火しないこと")
        fired.isInverted = true
        let watcher = FSEventsFileWatcher(directory: directory)
        self.watcher = watcher
        try watcher.start { fired.fulfill() }

        Thread.sleep(forTimeInterval: 0.3)
        try "generated\n".write(
            to: buildDir.appendingPathComponent("Generated.swift"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 1.5)
    }

    func testSafetyPollDetectsChangeWithoutEvents() throws {
        // FSEvents が届かない環境の安全網（低頻度ポーリング）だけでも検知できる。
        // イベント経路を通さない再現は難しいので、安全網の間隔を短くして
        // 「イベント + 安全網のどちらでも同じ署名照合で検知される」ことを確認する。
        let fired = expectation(description: "安全網検知")
        fired.assertForOverFulfill = false
        let watcher = FSEventsFileWatcher(directory: directory, latency: 0.05, safetyInterval: 0.3)
        self.watcher = watcher
        try watcher.start { fired.fulfill() }

        Thread.sleep(forTimeInterval: 0.2)
        try "let a = 3\n".write(
            to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 5.0)
    }

    func testStopPreventsFurtherNotifications() throws {
        let fired = expectation(description: "停止後は発火しないこと")
        fired.isInverted = true
        let watcher = FSEventsFileWatcher(directory: directory)
        self.watcher = watcher
        try watcher.start { fired.fulfill() }
        watcher.stop()

        try "let a = 4\n".write(
            to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 1.0)
    }
}
