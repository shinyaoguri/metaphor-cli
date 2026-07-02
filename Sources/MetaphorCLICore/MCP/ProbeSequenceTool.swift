import Foundation

/// Probe の連続フレーム往復（`request.json`(frames>=2) → `current/sequence/`）を
/// 自動化し、MCP の `capture_sequence` ツールとして時間軸の観測を提供する。
///
/// `ProbeSnapshotTool` の連続フレーム版。子スケッチは `request.json` に `frames >= 2`
/// を見つけると、単一の `current/frame.{png,json}` ではなく `current/sequence/` 以下に
/// 連続フレーム列・contact sheet・manifest(`sequence.json`) を書き出す（CONTRACT.md 契約点 4）。
///
/// 完了規約（CONTRACT.md）: producer は `sequence.json` を **最後に** 原子的に書く。
/// したがって consumer は「`sequence.json` が存在し、`id` がリクエストと一致し、
/// `frames.count == frameCount`」で ready と判定する（単一フレームの mtime ポーリングと同型）。
public final class ProbeSequenceTool {
    private let probeRoot: URL          // <sketch>/.metaphor/probe
    private let requestPath: URL        // probeRoot/request.json
    private let sequenceDir: URL        // probeRoot/current/sequence
    private let manifestPath: URL       // sequenceDir/sequence.json
    private let timeout: TimeInterval
    private let pollInterval: useconds_t
    private let pidPrefix: String
    private var counter = 0

    /// `timeout` は 1 回の sequence 撮影の最大待ち時間。frames×every 枚ぶんの描画 +
    /// 初回 cold-start を見込んで、単一フレームより長めの既定にする。
    public init(sketchDirectory: URL, timeout: TimeInterval = 30.0) {
        let root = sketchDirectory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("probe", isDirectory: true)
        self.probeRoot = root
        self.requestPath = root.appendingPathComponent("request.json")
        self.sequenceDir = root.appendingPathComponent("current/sequence", isDirectory: true)
        self.manifestPath = sequenceDir.appendingPathComponent("sequence.json")
        self.timeout = timeout
        self.pollInterval = 50_000   // 50ms
        self.pidPrefix = "mcp-seq-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 連続フレーム列を撮って返す。contact sheet(PNG) と manifest(sequence.json) を content に詰める。
    /// `frames` は 2 以上（1 以下なら snapshot を案内）。`every`(>=1) は採取ストライド。
    /// `timeoutOverride` を渡すとこの呼び出しだけ待ち時間を変えられる（1〜120s にクランプ）。
    public func captureSequence(
        label: String?,
        frames: Int,
        every: Int?,
        timeoutOverride: TimeInterval? = nil
    ) -> MCPToolResult {
        guard frames >= 2 else {
            return .text(
                "capture_sequence: 'frames' は 2 以上にしてください（1 枚なら snapshot を使ってください）。",
                isError: true
            )
        }
        counter += 1
        let id = "\(pidPrefix)-\(counter)"
        let everyValue = max(1, every ?? 1)
        let effectiveTimeout = min(120.0, max(1.0, timeoutOverride ?? timeout))

        do {
            try writeRequest(id: id, label: label, frames: frames, every: everyValue)
        } catch {
            return .text("capture_sequence: request.json を書けませんでした: \(error)", isError: true)
        }

        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while Date() < deadline {
            if let manifest = readManifestIfReady(id: id) {
                return buildResult(manifest: manifest)
            }
            usleep(pollInterval)
        }
        return .text(
            "capture_sequence: タイムアウト (\(effectiveTimeout)s)。スケッチが描画中か、"
                + "METAPHOR_PROBE が有効か確認してください。noLoop スケッチは単一フレームへ degrade する場合があります。",
            isError: true
        )
    }

    // MARK: - Private

    /// request.json を atomic（tmp → rename）に書く（CONTRACT.md 契約点 4）。
    private func writeRequest(id: String, label: String?, frames: Int, every: Int) throws {
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        var object: [String: Any] = ["id": id, "frames": frames, "every": every]
        if let label { object["label"] = label }
        let data = try JSONSerialization.data(withJSONObject: object)

        let tmp = probeRoot.appendingPathComponent("request.json.tmp")
        try data.write(to: tmp)
        try ProbeAtomicFile.replace(tmp: tmp, final: requestPath)
    }

    /// sequence.json を読み、`id` 一致かつ `frames.count == frameCount` なら manifest を返す。
    /// producer は sequence.json を最後に原子的に書くため、この 3 条件で ready と判定できる。
    private func readManifestIfReady(id: String) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: manifestPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let manifestID = object["id"] as? String,
            manifestID == id,
            let frameCount = (object["frameCount"] as? NSNumber)?.intValue,
            let frames = object["frames"] as? [[String: Any]],
            frames.count == frameCount
        else {
            return nil
        }
        return object
    }

    private func buildResult(manifest: [String: Any]) -> MCPToolResult {
        var content: [[String: Any]] = []

        // contact sheet（一覧モンタージュ）を 1 枚の画像として返す。個々の
        // frame.NNNN.png は manifest 経由で参照でき、ペイロードを抑えるため既定では含めない。
        if let sheetName = manifest["contactSheet"] as? String {
            let sheetURL = sequenceDir.appendingPathComponent(sheetName)
            if let png = try? Data(contentsOf: sheetURL) {
                content.append([
                    "type": "image",
                    "data": png.base64EncodedString(),
                    "mimeType": "image/png",
                ])
            }
        }

        // manifest（frameCount / 各フレームの時刻・サイズ・ファイル名 / 警告）を text で返す。
        if
            JSONSerialization.isValidJSONObject(manifest),
            let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            content.append(["type": "text", "text": text])
        }

        if content.isEmpty {
            return .text("capture_sequence: sequence.json / contact sheet を読めませんでした", isError: true)
        }
        return MCPToolResult(content: content, isError: false)
    }
}
