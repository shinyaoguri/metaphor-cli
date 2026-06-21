import Foundation

/// MCP ツール定義（`tools/list` で返す 1 エントリ）。
public struct MCPToolDefinition {
    public let name: String
    public let description: String
    /// JSON Schema（`inputSchema`）。JSONSerialization で直列化可能な値のみ。
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var json: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

/// `tools/call` の結果。`content` は MCP content block の配列
/// （`{"type":"text","text":...}` / `{"type":"image","data":<base64>,"mimeType":...}`）。
public struct MCPToolResult {
    public var content: [[String: Any]]
    public var isError: Bool

    public init(content: [[String: Any]], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// テキスト 1 ブロックだけの結果を作る便宜イニシャライザ。
    public static func text(_ message: String, isError: Bool = false) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": message]], isError: isError)
    }
}

/// ツール集合を公開し `tools/call` を捌くハンドラ。
public protocol MCPToolHandling {
    var tools: [MCPToolDefinition] { get }
    func call(name: String, arguments: [String: Any]) -> MCPToolResult
}
