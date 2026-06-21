import Foundation

/// 最小の MCP (Model Context Protocol) stdio サーバ。
///
/// MCP の stdio トランスポートは実質「改行区切りの JSON-RPC 2.0」。本実装は
/// `initialize` / `notifications/*` / `tools/list` / `tools/call` のみを扱い、
/// 外部依存を持たず Foundation の JSONSerialization だけで完結する
/// （metaphor-cli の「依存ゼロ・手書き dispatch」方針に合わせる）。
///
/// I/O は注入可能で、テストではメモリ上の行供給/収集に差し替えられる。
public final class MCPServer {
    private let protocolVersion = "2024-11-05"
    private let serverName: String
    private let serverVersion: String
    private let handler: any MCPToolHandling
    private let readLine: () -> String?
    private let writeMessage: (String) -> Void

    public init(
        serverName: String,
        serverVersion: String,
        handler: any MCPToolHandling,
        readLine: @escaping () -> String?,
        writeMessage: @escaping (String) -> Void
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.handler = handler
        self.readLine = readLine
        self.writeMessage = writeMessage
    }

    /// stdin が閉じる（EOF）まで 1 行ずつ処理する。
    public func run() {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            handle(trimmed)
        }
    }

    /// 1 メッセージ（JSON-RPC 1 行）を処理する。テストから直接呼べる。
    public func handle(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? [String: Any],
            let method = message["method"] as? String
        else {
            // 不正な行は黙って無視（id も取れないため応答もできない）。
            return
        }

        let id = message["id"]   // notification の場合は nil
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            sendResult(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ])
        case let m where m.hasPrefix("notifications/"):
            break   // 通知には応答しない
        case "tools/list":
            sendResult(id: id, result: ["tools": handler.tools.map { $0.json }])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = handler.call(name: name, arguments: arguments)
            sendResult(id: id, result: [
                "content": result.content,
                "isError": result.isError,
            ])
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Response helpers

    private func sendResult(id: Any?, result: [String: Any]) {
        guard let id else { return }   // notification には応答しない
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ object: [String: Any]) {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else { return }
        writeMessage(string)
    }
}
