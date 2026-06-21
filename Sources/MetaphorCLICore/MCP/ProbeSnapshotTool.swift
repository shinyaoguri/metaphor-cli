import Foundation

/// Probe プラグインのファイル往復（`request.json` → `current/frame.{png,json}`）を
/// 自動化し、MCP の `snapshot` ツールとして 1 フレームを撮る。
///
/// 子スケッチは `METAPHOR_PROBE=1` で起動され、`request.json` の mtime 変化を見て
/// 次フレームで `current/frame.png` と `frame.json`（撮影時の `id` を含む）を
/// atomic に書き出す。本クラスは新しい `id` でリクエストを書き、その `id` の
/// `frame.json` が現れるまでポーリングする。
///
/// パスは `MetaphorProbeConfig` の既定（`.metaphor/probe/`）に合わせている。
public final class ProbeSnapshotTool {
    private let probeRoot: URL          // <sketch>/.metaphor/probe
    private let requestPath: URL        // probeRoot/request.json
    private let frameJSONPath: URL      // probeRoot/current/frame.json
    private let framePNGPath: URL       // probeRoot/current/frame.png
    private let timeout: TimeInterval
    private let pollInterval: useconds_t
    private let pidPrefix: String
    private var counter = 0

    public init(sketchDirectory: URL, timeout: TimeInterval = 5.0) {
        let root = sketchDirectory
            .appendingPathComponent(".metaphor", isDirectory: true)
            .appendingPathComponent("probe", isDirectory: true)
        self.probeRoot = root
        self.requestPath = root.appendingPathComponent("request.json")
        self.frameJSONPath = root.appendingPathComponent("current/frame.json")
        self.framePNGPath = root.appendingPathComponent("current/frame.png")
        self.timeout = timeout
        self.pollInterval = 30_000   // 30ms
        self.pidPrefix = "mcp-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 1 フレームを撮って返す。画像(PNG)と内部状態(frame.json)を content に詰める。
    public func snapshot(label: String?) -> MCPToolResult {
        counter += 1
        let id = "\(pidPrefix)-\(counter)"

        do {
            try writeRequest(id: id, label: label)
        } catch {
            return .text("snapshot: request.json を書けませんでした: \(error)", isError: true)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let metadata = readFrameMetadataIfMatches(id: id) {
                return buildResult(metadata: metadata)
            }
            usleep(pollInterval)
        }
        return .text(
            "snapshot: タイムアウト (\(timeout)s)。スケッチが描画中か、METAPHOR_PROBE が有効か確認してください。",
            isError: true
        )
    }

    // MARK: - Private

    /// request.json を atomic（tmp → rename）に書く。
    private func writeRequest(id: String, label: String?) throws {
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        var object: [String: Any] = ["id": id]
        if let label { object["label"] = label }
        let data = try JSONSerialization.data(withJSONObject: object)

        let tmp = probeRoot.appendingPathComponent("request.json.tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: requestPath.path) {
            try FileManager.default.removeItem(at: requestPath)
        }
        try FileManager.default.moveItem(at: tmp, to: requestPath)
    }

    /// frame.json を読み、その `id` がリクエストと一致すればメタデータを返す。
    private func readFrameMetadataIfMatches(id: String) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: frameJSONPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let frameID = object["id"] as? String,
            frameID == id
        else {
            return nil
        }
        return object
    }

    private func buildResult(metadata: [String: Any]) -> MCPToolResult {
        var content: [[String: Any]] = []

        if let png = try? Data(contentsOf: framePNGPath) {
            content.append([
                "type": "image",
                "data": png.base64EncodedString(),
                "mimeType": "image/png",
            ])
        }

        // frame.json を text としても返す（frameCount/time/probe値/警告をエージェントが読む）。
        if
            JSONSerialization.isValidJSONObject(metadata),
            let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            content.append(["type": "text", "text": text])
        }

        if content.isEmpty {
            return .text("snapshot: frame.png / frame.json を読めませんでした", isError: true)
        }
        return MCPToolResult(content: content, isError: false)
    }
}
