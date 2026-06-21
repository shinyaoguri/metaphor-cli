import Foundation

/// `metaphor mcp` が公開する MCP ツール群。
///
/// M1 は `snapshot`（観測）のみ。M2 で `input`（操作）と `build_status` を追加する。
public final class SketchToolHandler: MCPToolHandling {
    private let snapshotTool: ProbeSnapshotTool

    public init(snapshotTool: ProbeSnapshotTool) {
        self.snapshotTool = snapshotTool
    }

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
                    ],
                ]
            ),
        ]
    }

    public func call(name: String, arguments: [String: Any]) -> MCPToolResult {
        switch name {
        case "snapshot":
            return snapshotTool.snapshot(label: arguments["label"] as? String)
        default:
            return .text("unknown tool: \(name)", isError: true)
        }
    }
}
