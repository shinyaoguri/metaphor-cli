import Foundation
@testable import MetaphorCLICore
import XCTest

/// 非侵襲アップデート通知（#73）のテスト。
/// 通知はキャッシュのみで判断し、ネットワーク取得は裏で走ってキャッシュを温める。
final class UpdateNotifierTests: XCTestCase {
    private var cacheURL: URL!

    override func setUp() {
        super.setUp()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-cli-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("update-check.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeNotifier(
        releaseService: any ReleaseServicing = StubReleaseService(),
        currentVersion: String = "0.3.0",
        executablePaths: [String] = ["/opt/homebrew/Cellar/metaphor/0.3.0/bin/metaphor"],
        environment: [String: String] = [:],
        isInteractive: Bool = true,
        now: @escaping () -> Date = Date.init
    ) -> UpdateNotifier {
        UpdateNotifier(
            releaseService: releaseService,
            cacheFileURL: cacheURL,
            currentVersion: currentVersion,
            executablePaths: executablePaths,
            environment: environment,
            isInteractive: isInteractive,
            now: now
        )
    }

    private func writeCache(latestVersion: String, checkedAt: Date) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cache = UpdateNotifier.CachedCheck(latestVersion: latestVersion, checkedAt: checkedAt)
        try encoder.encode(cache).write(to: cacheURL)
    }

    private func readCache() -> UpdateNotifier.CachedCheck? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateNotifier.CachedCheck.self, from: data)
    }

    func testNotifiesOnStderrWhenCachedLatestIsNewer() throws {
        try writeCache(latestVersion: "0.4.0", checkedAt: Date())
        let console = BufferedConsole()

        makeNotifier().begin(console: console)

        XCTAssertTrue(console.output.isEmpty, "notification must not pollute stdout")
        XCTAssertEqual(console.errors.count, 2)
        XCTAssertTrue(console.errors[0].contains("0.3.0 → 0.4.0"))
        XCTAssertTrue(console.errors[1].contains("brew upgrade metaphor"))
    }

    func testSuggestsMetaphorUpdateForNonHomebrewInstall() throws {
        try writeCache(latestVersion: "0.4.0", checkedAt: Date())
        let console = BufferedConsole()

        makeNotifier(executablePaths: ["/Users/tester/.local/libexec/metaphor/metaphor"])
            .begin(console: console)

        XCTAssertTrue(console.errors.last?.contains("metaphor update") == true)
    }

    func testStaysQuietWhenUpToDate() throws {
        try writeCache(latestVersion: "0.3.0", checkedAt: Date())
        let console = BufferedConsole()

        makeNotifier().begin(console: console)

        XCTAssertTrue(console.errors.isEmpty)
    }

    func testStaysQuietForDevBuilds() throws {
        try writeCache(latestVersion: "9.9.9", checkedAt: Date())
        let console = BufferedConsole()

        // git describe の中間ビルド（direnv でのローカル開発版）では鳴らさない。
        makeNotifier(currentVersion: "0.3.0-5-gabc1234").begin(console: console)

        XCTAssertTrue(console.errors.isEmpty)
    }

    func testStaysQuietWhenOptedOutViaEnvironment() throws {
        try writeCache(latestVersion: "9.9.9", checkedAt: Date())
        let console = BufferedConsole()

        makeNotifier(environment: [UpdateNotifier.optOutEnvironmentKey: "1"]).begin(console: console)

        XCTAssertTrue(console.errors.isEmpty)
    }

    func testStaysQuietWhenNotInteractive() throws {
        try writeCache(latestVersion: "9.9.9", checkedAt: Date())
        let console = BufferedConsole()

        makeNotifier(isInteractive: false).begin(console: console)

        XCTAssertTrue(console.errors.isEmpty)
    }

    func testRefreshesStaleCacheInBackground() throws {
        try writeCache(latestVersion: "0.3.0", checkedAt: Date(timeIntervalSinceNow: -2 * UpdateNotifier.checkInterval))
        let service = StubReleaseService()
        service.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v0.4.0", name: nil, prerelease: false, assets: []
        )
        let notifier = makeNotifier(releaseService: service)

        notifier.begin(console: BufferedConsole())
        notifier.waitForRefresh()

        XCTAssertEqual(readCache()?.latestVersion, "0.4.0")
    }

    func testMissingCacheTriggersRefreshWithoutNotifying() {
        let service = StubReleaseService()
        service.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v0.4.0", name: nil, prerelease: false, assets: []
        )
        let console = BufferedConsole()
        let notifier = makeNotifier(releaseService: service)

        notifier.begin(console: console)
        notifier.waitForRefresh()

        // 初回は既知の最新版が無いので黙ってキャッシュだけ温める。通知は次回から。
        XCTAssertTrue(console.errors.isEmpty)
        XCTAssertEqual(readCache()?.latestVersion, "0.4.0")
    }

    func testFreshCacheSkipsNetworkRefresh() throws {
        let checkedAt = Date(timeIntervalSinceNow: -60)
        try writeCache(latestVersion: "0.3.0", checkedAt: checkedAt)
        let service = CountingReleaseService()
        let notifier = makeNotifier(releaseService: service)

        notifier.begin(console: BufferedConsole())
        notifier.waitForRefresh()

        XCTAssertEqual(service.latestReleaseCallCount, 0)
    }

    func testPrereleaseLatestIsNotCached() throws {
        try writeCache(latestVersion: "0.3.0", checkedAt: Date(timeIntervalSinceNow: -2 * UpdateNotifier.checkInterval))
        let service = StubReleaseService()
        service.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v0.4.0-rc.1", name: nil, prerelease: true, assets: []
        )
        let notifier = makeNotifier(releaseService: service)

        notifier.begin(console: BufferedConsole())
        notifier.waitForRefresh()

        XCTAssertEqual(readCache()?.latestVersion, "0.3.0", "prerelease must not overwrite the cache")
    }

    func testNetworkFailureLeavesCacheUntouched() throws {
        let staleDate = Date(timeIntervalSinceNow: -2 * UpdateNotifier.checkInterval)
        try writeCache(latestVersion: "0.3.0", checkedAt: staleDate)
        // StubReleaseService は未設定リポジトリで throw する = ネットワーク失敗相当。
        let notifier = makeNotifier(releaseService: StubReleaseService())

        notifier.begin(console: BufferedConsole())
        notifier.waitForRefresh()

        XCTAssertEqual(readCache()?.latestVersion, "0.3.0")
    }

    func testShouldRunExcludesProtocolAndInternalCommands() {
        XCTAssertFalse(UpdateNotifier.shouldRun(forCommand: "mcp"), "mcp is a stdio JSON-RPC server")
        XCTAssertFalse(UpdateNotifier.shouldRun(forCommand: "update"))
        XCTAssertFalse(UpdateNotifier.shouldRun(forCommand: "version"))
        XCTAssertFalse(UpdateNotifier.shouldRun(forCommand: "--version"))
        XCTAssertFalse(UpdateNotifier.shouldRun(forCommand: "__view"))

        XCTAssertTrue(UpdateNotifier.shouldRun(forCommand: "new"))
        XCTAssertTrue(UpdateNotifier.shouldRun(forCommand: "watch"))
        XCTAssertTrue(UpdateNotifier.shouldRun(forCommand: "doctor"))
        XCTAssertTrue(UpdateNotifier.shouldRun(forCommand: nil), "no-argument help may notify")
    }
}

/// latestRelease が呼ばれた回数だけを記録するスタブ（fresh キャッシュ時の抑止検証用）。
private final class CountingReleaseService: ReleaseServicing {
    private(set) var latestReleaseCallCount = 0

    func latestRelease(owner: String, repo: String) throws -> GitHubRelease {
        latestReleaseCallCount += 1
        throw CLIError("not stubbed")
    }

    func download(from url: URL) throws -> Data {
        throw CLIError("not stubbed")
    }
}
