import Foundation

/// `metaphor mcp` が公開する MCP ツール群。
///
/// - `snapshot`（観測）: 現在フレームの PNG と内部状態を返す。
/// - `input`（操作）: マウス/キーイベントを子スケッチの stdin へ転送する。
/// - `build_status`: 直近の `swift build` の成否とエラーを返す。
///
/// 副作用は注入されたクロージャ越しに行うのでユニットテスト可能。
public final class SketchToolHandler: MCPToolHandling {
    private let snapshotTool: ProbeSnapshotTool
    private let forwardInput: (String) -> Void
    private let buildStatusProvider: () -> BuildOutcome?

    public init(
        snapshotTool: ProbeSnapshotTool,
        forwardInput: @escaping (String) -> Void,
        buildStatusProvider: @escaping () -> BuildOutcome?
    ) {
        self.snapshotTool = snapshotTool
        self.forwardInput = forwardInput
        self.buildStatusProvider = buildStatusProvider
    }

    /// 子スケッチが受け取る入力イベント種別（stdin JSON Lines の `t`）。
    private static let inputTypes = [
        "mouseDown", "mouseUp", "mouseMove", "mouseDrag", "scroll", "keyDown", "keyUp",
    ]

    public var tools: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "snapshot",
                description: "動作中のスケッチの現在フレームを 1 枚撮り、PNG 画像と内部状態"
                    + "(frame.json: frameCount / time / probe() 値 / blank 警告)を返す。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "label": [
                            "type": "string",
                            "description": "任意のラベル。frame.json に記録される。",
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "このフレームを待つ最大秒数 (1〜60、既定15)。初回はスケッチの cold-start を待つため長めが安全。",
                        ],
                    ],
                ]
            ),
            MCPToolDefinition(
                name: "input",
                description: "マウス/キー入力を動作中のスケッチへ送る（キャンバス座標）。"
                    + "再ビルド中で子が居ない瞬間は黙って捨てられる。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": Self.inputTypes,
                                 "description": "イベント種別。"],
                        "x": ["type": "number", "description": "キャンバス X（mouse 系）。"],
                        "y": ["type": "number", "description": "キャンバス Y（mouse 系）。"],
                        "button": ["type": "integer", "description": "0=左 1=右 2=その他（mouse 系）。"],
                        "dx": ["type": "number", "description": "スクロール量 X（scroll）。"],
                        "dy": ["type": "number", "description": "スクロール量 Y（scroll）。"],
                        "code": ["type": "integer", "description": "キーコード（key 系）。"],
                        "chars": ["type": "string", "description": "入力文字（keyDown）。"],
                        "repeat": ["type": "boolean", "description": "リピートか（keyDown）。"],
                    ],
                    "required": ["type"],
                ]
            ),
            MCPToolDefinition(
                name: "build_status",
                description: "直近の `swift build` の成否・終了コード・エラー出力を返す。"
                    + "ソースを編集した後に、その編集がコンパイルできたかの確認に使う。",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
        ]
    }

    public func call(name: String, arguments: [String: Any]) -> MCPToolResult {
        switch name {
        case "snapshot":
            let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue
            return snapshotTool.snapshot(label: arguments["label"] as? String, timeoutOverride: timeout)
        case "input":
            return handleInput(arguments)
        case "build_status":
            return handleBuildStatus()
        default:
            return .text("unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - input

    private func handleInput(_ arguments: [String: Any]) -> MCPToolResult {
        guard let type = arguments["type"] as? String, Self.inputTypes.contains(type) else {
            return .text("input: 'type' が必要です (\(Self.inputTypes.joined(separator: ", ")))", isError: true)
        }

        // 子が期待する JSON Lines（キー `t` + 渡されたフィールドのみ）を組む。
        var event: [String: Any] = ["t": type]
        for key in ["x", "y", "dx", "dy"] {
            if let value = (arguments[key] as? NSNumber)?.doubleValue { event[key] = value }
        }
        for key in ["button", "code"] {
            if let value = (arguments[key] as? NSNumber)?.intValue { event[key] = value }
        }
        if let chars = arguments["chars"] as? String { event["chars"] = chars }
        if let isRepeat = arguments["repeat"] as? Bool { event["repeat"] = isRepeat }

        guard
            JSONSerialization.isValidJSONObject(event),
            let data = try? JSONSerialization.data(withJSONObject: event),
            let line = String(data: data, encoding: .utf8)
        else {
            return .text("input: イベントを直列化できませんでした", isError: true)
        }

        forwardInput(line)
        return .text("sent \(type)")
    }

    // MARK: - build_status

    private func handleBuildStatus() -> MCPToolResult {
        guard let outcome = buildStatusProvider() else {
            return .text("build_status: まだビルド結果がありません。")
        }
        let head = outcome.succeeded
            ? "build OK (exit \(outcome.exitCode))"
            : "build FAILED (exit \(outcome.exitCode))"
        let body = outcome.output.isEmpty ? "" : "\n\n\(outcome.output)"
        return MCPToolResult(
            content: [["type": "text", "text": head + body]],
            isError: !outcome.succeeded
        )
    }
}
