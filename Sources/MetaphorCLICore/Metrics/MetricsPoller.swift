import Foundation

/// `frame.json` の `performance` セクション（CONTRACT.md 契約点 4、schemaVersion 4 に
/// additive 追加。metaphor 0.7.0+ / Issue metaphor#271）。全フィールドが採取不能時に
/// 省略されうるため optional でデコードする。未知キーは無視（consumer 規約）。
public struct ProbePerformance: Decodable, Equatable {
    public struct FrameTime: Decodable, Equatable {
        public let mean: Double
        public let max: Double

        public init(mean: Double, max: Double) {
            self.mean = mean
            self.max = max
        }
    }

    /// 直近約 1 秒の実測 fps。noLoop 停止中・起動直後は省略。
    public let fps: Double?
    /// `frameRate()` / `METAPHOR_FPS` 解決後の設定値。
    public let targetFPS: Double?
    /// フレーム時間（ミリ秒）。`max` はスパイク検出用。
    public let frameTimeMs: FrameTime?
    /// phys_footprint（Activity Monitor の「メモリ」相当）。
    public let memoryMB: Double?
    /// 前回リクエストから今回までの平均 CPU 使用率（1 コア = 100%、`top` 互換）。
    public let cpuPercent: Double?
    /// `nominal` / `fair` / `serious` / `critical` / `unknown`。
    public let thermalState: String?

    public init(
        fps: Double? = nil,
        targetFPS: Double? = nil,
        frameTimeMs: FrameTime? = nil,
        memoryMB: Double? = nil,
        cpuPercent: Double? = nil,
        thermalState: String? = nil
    ) {
        self.fps = fps
        self.targetFPS = targetFPS
        self.frameTimeMs = frameTimeMs
        self.memoryMB = memoryMB
        self.cpuPercent = cpuPercent
        self.thermalState = thermalState
    }
}

/// `--metrics` ポーリング 1 サイクルの結果。
public enum MetricsSample: Equatable {
    /// 応答あり・`performance` あり。
    case metrics(ProbePerformance)
    /// 応答はあったが `performance` キーが無い（スケッチの metaphor が 0.7.0 未満）。
    case unsupported
    /// タイムアウト。スケッチ未起動・ビルド失敗・noLoop 停止中（producer は
    /// フレーム描画時にしか request.json を読まないため、停止中は応答しない）。
    case noResponse
    /// 他 consumer（`metaphor mcp` の snapshot / capture_sequence）へ譲った。
    /// 表示は前回値を維持するのが期待される扱い。
    case yielded
}

/// `--metrics` のコア: Probe ファイル契約（CONTRACT.md 契約点 4）を定期ポーリングし、
/// `performance` セクションを読み出す。
///
/// `request.json` は単一チャネルで `metaphor mcp` の snapshot / capture_sequence と
/// 共用のため、**非対称の調停**を行う — MCP はユーザー/AI の明示アクション、metrics は
/// 背景ポーリングなので、metrics 側だけが譲る:
///
/// 1. 書き込み前に他 consumer の未処理（pending）リクエストがあればサイクルをスキップ
/// 2. 自分の `id` の `frame.json` だけを読む（`ProbeSnapshotTool` と同型の id 突き合わせ）
/// 3. 応答待ち中に `request.json` が他 consumer に上書きされたら早期に諦める
///
/// 残る race は「MCP の write と本クラスの check-then-write の間」の数 ms のみ。
/// 負けた MCP snapshot は 1 回タイムアウトしうるが、再試行で回復可能として許容する
/// （Issue metaphor-cli#82 の設計判断）。
public final class MetricsPoller {
    private let probeRoot: URL          // <sketch>/.metaphor/probe
    private let requestPath: URL        // probeRoot/request.json
    private let frameJSONPath: URL      // probeRoot/current/frame.json
    private let sequenceJSONPath: URL   // probeRoot/current/sequence/sequence.json
    private let interval: TimeInterval
    private let responseTimeout: TimeInterval
    private let idPrefix: String
    private let onSample: (MetricsSample) -> Void
    private var counter = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "metaphor.metrics-poller")

    /// 出力画像の縮小率。metrics は数値だけ読むので PNG は最小コストでよい
    /// （Issue metaphor-cli#82 案 A: 画像なしリクエストの契約拡張は需要が出てから）。
    private let requestScale = 0.1

    /// - Parameters:
    ///   - interval: `start()` のポーリング間隔（秒）。
    ///   - responseTimeout: 1 サイクルの応答待ち上限。省略時は `max(interval, 2.0)`
    ///     （低 fps スケッチでも次フレームを待てるだけの余裕）。
    ///   - idPrefix: リクエスト id の接頭辞。省略時は pid 入り（複数プロセス併走でも
    ///     衝突しない）。テストが決定論的な id を注入するためのフック。
    ///   - onSample: サイクルごとの結果通知。ポーラーの内部キューから呼ばれる。
    public init(
        sketchDirectory: URL,
        interval: TimeInterval,
        responseTimeout: TimeInterval? = nil,
        idPrefix: String? = nil,
        onSample: @escaping (MetricsSample) -> Void
    ) {
        let root = sketchDirectory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("probe", isDirectory: true)
        self.probeRoot = root
        self.requestPath = root.appendingPathComponent("request.json")
        self.frameJSONPath = root.appendingPathComponent("current/frame.json")
        self.sequenceJSONPath = root.appendingPathComponent("current/sequence/sequence.json")
        self.interval = interval
        self.responseTimeout = responseTimeout ?? Swift.max(interval, 2.0)
        self.idPrefix = idPrefix ?? "metrics-\(ProcessInfo.processInfo.processIdentifier)"
        self.onSample = onSample
    }

    /// 定期ポーリングを開始する。1 サイクルは応答待ちでブロックするが内部シリアル
    /// キュー上なので、遅延した発火は DispatchSourceTimer が合体させる。
    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.onSample(self.pollOnce())
        }
        t.resume()
        timer = t
    }

    /// ポーリングを停止する。実行中のサイクルは完走する（次以降は発火しない）。
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - One cycle (synchronous, testable)

    /// 1 サイクルを同期実行する。`start()` のタイマーハンドラ本体だが、テストが
    /// タイマーを介さず直接呼べるよう分離してある。
    func pollOnce() -> MetricsSample {
        // 他 consumer（MCP）の未処理リクエストを潰さない（調停 1）。
        if hasForeignPendingRequest() {
            return .yielded
        }

        counter += 1
        let id = "\(idPrefix)-\(counter)"
        do {
            try writeRequest(id: id)
        } catch {
            // probe ディレクトリを作れない等。次サイクルで再試行するだけなので黙る。
            return .noResponse
        }

        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            if let envelope = readJSON(FrameEnvelope.self, at: frameJSONPath), envelope.id == id {
                if let performance = envelope.performance {
                    return .metrics(performance)
                }
                return .unsupported
            }
            // 応答待ち中に他 consumer が request.json を上書きしたら、producer は
            // もう自分の id を処理しないので待つだけ無駄。早期に譲る（調停 3）。
            if let current = readJSON(RequestEnvelope.self, at: requestPath), current.id != id {
                return .yielded
            }
            usleep(30_000)  // 30ms（ProbeSnapshotTool と同じ粒度）
        }
        return .noResponse
    }

    // MARK: - Private

    private struct RequestEnvelope: Decodable { let id: String }
    private struct FrameEnvelope: Decodable {
        let id: String
        let performance: ProbePerformance?
    }
    private struct SequenceEnvelope: Decodable { let id: String? }

    /// 他 consumer のリクエストが未処理（pending）のまま `request.json` に残っているか。
    /// 処理済みかは応答（`frame.json` / `sequence.json`）の id 一致で判定する。
    /// スケッチが長時間応答しない場合は pending が残り続け譲り続けるが、そのときは
    /// 自分が書いても応答は来ない（実質 noResponse と同じ）ので割り切る。
    private func hasForeignPendingRequest() -> Bool {
        guard let request = readJSON(RequestEnvelope.self, at: requestPath) else {
            return false  // 不在・読取失敗は pending なし扱い（自分が書いてよい）
        }
        if request.id.hasPrefix(idPrefix) { return false }  // 自分の前回分
        if let frame = readJSON(FrameEnvelope.self, at: frameJSONPath), frame.id == request.id {
            return false  // 単一フレーム経路で処理済み
        }
        if let sequence = readJSON(SequenceEnvelope.self, at: sequenceJSONPath),
           sequence.id == request.id {
            return false  // シーケンス経路で処理済み
        }
        return true
    }

    /// request.json を atomic（tmp → rename）に書く（CONTRACT.md 契約点 4 の consumer 規約）。
    private func writeRequest(id: String) throws {
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        let object: [String: Any] = ["id": id, "scale": requestScale]
        let data = try JSONSerialization.data(withJSONObject: object)
        let tmp = probeRoot.appendingPathComponent("request.json.tmp")
        try data.write(to: tmp)
        try ProbeAtomicFile.replace(tmp: tmp, final: requestPath)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
