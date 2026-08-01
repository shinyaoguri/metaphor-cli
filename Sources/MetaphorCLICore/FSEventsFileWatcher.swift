import CoreServices
import Foundation

/// FSEvents ベースのウォッチャ。変更イベント駆動で検知遅延を抑える
/// （ポーリング 0.4s の平均 ~200ms 待ちに対し、イベント合流 `latency` ≈ 0.1s）。
///
/// 発火のたびに ``swiftSourceSignature(in:)`` を照合するので、`.build` への
/// ビルド書き込みなどソース以外のイベントでは再ビルドしない（主要な生成物
/// ディレクトリはカーネル段階でも除外する）。FSEvents が届かないボリューム
/// （ネットワークマウント等）でも取りこぼさないよう、低頻度の安全ポーリングを
/// 併走させる。判定はどちらの経路も同じ署名照合なので二重発火はしない。
public final class FSEventsFileWatcher: FileWatching {
    private let directory: URL
    private let latency: TimeInterval
    private let safetyInterval: TimeInterval
    private var stream: FSEventStreamRef?
    private var safetyTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "org.metaphor.watch.fsevents")
    private var lastSignature: String = ""
    private var onChange: (() -> Void)?

    public init(
        directory: URL,
        latency: TimeInterval = 0.1,
        safetyInterval: TimeInterval = 2.0
    ) {
        self.directory = directory
        self.latency = latency
        self.safetyInterval = safetyInterval
    }

    public func start(onChange: @escaping () -> Void) throws {
        self.onChange = onChange
        lastSignature = swiftSourceSignature(in: directory)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsFileWatcher>.fromOpaque(info).takeUnretainedValue().evaluate()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            throw CLIError("FSEvents ストリームを作成できません: \(directory.path)")
        }
        // ビルド生成物・Probe 出力・git のイベントはカーネル段階で除外する
        // （署名照合でも弾けるが、ビルド中の無駄な走査を減らす）。
        FSEventStreamSetExclusionPaths(stream, [
            directory.appendingPathComponent(".build").path,
            directory.appendingPathComponent(".metaphor").path,
            directory.appendingPathComponent(".git").path,
        ] as CFArray)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream

        // FSEvents が届かない環境の安全網。
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval)
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        safetyTimer = timer
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        safetyTimer?.cancel()
        safetyTimer = nil
    }

    /// 署名を照合し、変わっていたら通知する（FSEvents/安全ポーリング共通・`queue` 上で実行）。
    private func evaluate() {
        let current = swiftSourceSignature(in: directory)
        if current != lastSignature {
            lastSignature = current
            onChange?()
        }
    }
}
