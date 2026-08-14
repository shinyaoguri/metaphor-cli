import Foundation

// MARK: - File watching

/// ソース変更を通知する抽象。テストで手動発火できるよう分離。
public protocol FileWatching: AnyObject {
    /// 監視を開始する。変更検出のたびに `onChange` を呼ぶ。
    func start(onChange: @escaping () -> Void) throws
    /// 監視を停止する。
    func stop()
}

/// 監視対象ファイルの「パス:更新時刻」を連結したソート済み署名。
///
/// パッケージディレクトリ配下の全 `*.swift`（`Package.swift` 含む）を対象とし、
/// レイアウト（慣習的な `Sources/` / カスタム `path:` のどちらでも）に依存しない。
/// `.build` や `.git` などの隠しディレクトリは `.skipsHiddenFiles` で除外される。
/// ``PollingFileWatcher`` と ``FSEventsFileWatcher`` が変更判定に共用する。
///
/// - Important: これは**リビルドの引き金**であって provenance ではない。`.metal` は
///   metaphor 側がプロセス内でホットリロードするので、ここに足すと再ビルド＋再起動に
///   化けてホットリロードの価値が消える。刻印（`.swift` + `.metal`）の側は
///   ``WatchSession/computeSourceStamp()`` が別に持つ。集合を揃えないこと。
func swiftSourceSignature(in directory: URL, fileManager: FileManager = .default) -> String {
    var entries: [String] = []

    if let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let date = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate {
                entries.append("\(url.path):\(date.timeIntervalSince1970)")
            }
        }
    }

    return entries.sorted().joined(separator: "|")
}

/// `Sources/**/*.swift` と `Package.swift` の更新時刻を定期的に走査し、
/// 署名（連結文字列）が変わったら通知するポーリング型ウォッチャ。
///
/// 既定では ``FSEventsFileWatcher`` を使う。本実装はその安全網と同じ判定を
/// 全面ポーリングで行う予備実装で、テストや FSEvents を避けたい場合に使う。
public final class PollingFileWatcher: FileWatching {
    private let directory: URL
    private let interval: TimeInterval
    private let fileManager: FileManager
    private var timer: DispatchSourceTimer?
    private var lastSignature: String = ""

    public init(directory: URL, interval: TimeInterval = 0.4, fileManager: FileManager = .default) {
        self.directory = directory
        self.interval = interval
        self.fileManager = fileManager
    }

    public func start(onChange: @escaping () -> Void) throws {
        lastSignature = signature()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "org.metaphor.watch.poll")
        )
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.signature()
            if current != self.lastSignature {
                self.lastSignature = current
                onChange()
            }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func signature() -> String {
        swiftSourceSignature(in: directory, fileManager: fileManager)
    }
}
