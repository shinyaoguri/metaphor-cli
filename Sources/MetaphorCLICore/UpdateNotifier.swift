import Foundation

/// 非侵襲アップデート通知（#73）。
///
/// コマンドのたびに確認するのはローカルキャッシュだけで、そこに現行より新しい
/// リリースが記録されていれば stderr に 1〜2 行のヒントを出す。キャッシュが
/// `checkInterval` より古いときはコマンドの裏で最新リリースを取得し、取得できた
/// 時点でキャッシュを保存する（コマンド終了は待たせない。取得前にプロセスが
/// 終われば単に次回へ持ち越し）。ネットワーク失敗は黙って諦める。
///
/// 通知はユーザー体験の付け足しであってコマンドの一部ではないため、この型は
/// いかなる経路でも throw せず、コマンド本体の実行を妨げない。
public final class UpdateNotifier {
    public struct CachedCheck: Codable, Equatable {
        public var latestVersion: String
        public var checkedAt: Date

        public init(latestVersion: String, checkedAt: Date) {
            self.latestVersion = latestVersion
            self.checkedAt = checkedAt
        }
    }

    public static let checkInterval: TimeInterval = 24 * 60 * 60
    public static let optOutEnvironmentKey = "METAPHOR_NO_UPDATE_CHECK"

    /// 通知を出さないコマンド。`mcp` は stdio 上の JSON-RPC サーバなので stdout は
    /// もちろん stderr もクライアントのログを汚す（AI が最も頻繁に起動するコマンド
    /// でもある）。`update` は自ら最新版を扱い、`version` は出力が機械読み取り
    /// されうる。`__` 始まりの内部コマンドも対象外。
    static let excludedCommands: Set<String> = ["mcp", "update", "version", "--version"]

    private let releaseService: any ReleaseServicing
    private let cacheFileURL: URL
    private let currentVersion: String
    private let executablePaths: [String]
    private let environment: [String: String]
    private let isInteractive: Bool
    private let now: () -> Date
    private let refreshInFlight = DispatchGroup()

    public init(
        releaseService: any ReleaseServicing = GitHubReleaseService(),
        cacheFileURL: URL = UpdateNotifier.defaultCacheFileURL,
        currentVersion: String = BuildInfo.displayVersion,
        executablePaths: [String] = UpdateNotifier.defaultExecutablePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isInteractive: Bool = isatty(STDERR_FILENO) != 0,
        now: @escaping () -> Date = Date.init
    ) {
        self.releaseService = releaseService
        self.cacheFileURL = cacheFileURL
        self.currentVersion = currentVersion
        self.executablePaths = executablePaths
        self.environment = environment
        self.isInteractive = isInteractive
        self.now = now
    }

    public static var defaultCacheFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/metaphor/update-check.json")
    }

    /// 実行中バイナリのパス候補（symlink 解決前 → 解決後）。brew かどうかの判定に使う。
    public static var defaultExecutablePaths: [String] {
        var paths: [String] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            paths.append(URL(fileURLWithPath: argv0).standardizedFileURL.path)
        }
        if let resolved = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            paths.append(resolved.path)
        }
        return paths
    }

    public static func shouldRun(forCommand command: String?) -> Bool {
        guard let command else { return true } // 引数なし = ヘルプ表示
        return !excludedCommands.contains(command) && !command.hasPrefix("__")
    }

    /// キャッシュに基づいて通知し、キャッシュが古ければ裏で最新版の取得を開始する。
    public func begin(console: any Console) {
        guard isEnabled else { return }
        notifyFromCache(console: console)
        refreshCacheIfStale()
    }

    /// テスト用: 裏の取得（保存まで）が終わるのを待つ。取得が走っていなければ即返る。
    func waitForRefresh(timeout: TimeInterval = 5) {
        _ = refreshInFlight.wait(timeout: .now() + timeout)
    }

    private var isEnabled: Bool {
        if let optOut = environment[Self.optOutEnvironmentKey], !optOut.isEmpty { return false }
        guard isInteractive else { return false }
        // リリースビルド以外（`0.1.0-dev` や git describe の `0.3.0-5-gabc1234`）では
        // 沈黙する。ローカル開発版に「アップデートしろ」と言い続けないため。
        guard let current = SemanticVersion(currentVersion), current.prerelease == nil else { return false }
        return true
    }

    private func notifyFromCache(console: any Console) {
        guard let cache = readCache(),
              let latest = SemanticVersion(cache.latestVersion),
              let current = SemanticVersion(currentVersion),
              current < latest else { return }
        console.writeError("A new release of metaphor is available: \(currentVersion) → \(cache.latestVersion)")
        console.writeError("To upgrade, run: \(upgradeCommand)")
    }

    private func refreshCacheIfStale() {
        if let cache = readCache(), now().timeIntervalSince(cache.checkedAt) < Self.checkInterval {
            return
        }
        refreshInFlight.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.refreshInFlight.leave() }
            guard let release = try? self.releaseService.latestRelease(
                owner: BuildInfo.cliRepositoryOwner,
                repo: BuildInfo.cliRepositoryName
            ), !release.prerelease else { return }

            var tag = release.tagName
            if tag.hasPrefix("v") { tag.removeFirst() }
            guard SemanticVersion(tag) != nil else { return }
            Self.writeCache(CachedCheck(latestVersion: tag, checkedAt: self.now()), to: self.cacheFileURL)
        }
    }

    private var upgradeCommand: String {
        let isHomebrew = executablePaths.contains {
            $0.contains("/Cellar/metaphor/") || $0.contains("/Cellar/metaphor-cli/")
        }
        return isHomebrew ? "brew upgrade metaphor" : "metaphor update"
    }

    private func readCache() -> CachedCheck? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedCheck.self, from: data)
    }

    private static func writeCache(_ check: CachedCheck, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(check) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // watch と mcp の同時実行を想定し、アトミック書き込み（tmp → rename）で壊さない。
        try? data.write(to: url, options: [.atomic])
    }
}
