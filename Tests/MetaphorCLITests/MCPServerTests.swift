import XCTest
@testable import MetaphorCLICore

final class MCPServerTests: XCTestCase {

    /// 呼び出しを記録するだけのツールハンドラ。
    private final class StubHandler: MCPToolHandling {
        private(set) var calls: [(name: String, arguments: [String: Any])] = []

        var tools: [MCPToolDefinition] {
            [MCPToolDefinition(name: "snapshot", description: "d", inputSchema: ["type": "object"])]
        }

        func call(name: String, arguments: [String: Any]) -> MCPToolResult {
            calls.append((name, arguments))
            return .text("ok")
        }
    }

    /// I/O を捕捉する MCPServer を作る。返り値の getter で送信メッセージ列を読む。
    private func makeServer(
        handler: any MCPToolHandling
    ) -> (server: MCPServer, sent: () -> [[String: Any]]) {
        final class Box { var messages: [String] = [] }
        let box = Box()
        let server = MCPServer(
            serverName: "metaphor",
            serverVersion: "test",
            handler: handler,
            readLine: { nil },
            writeMessage: { box.messages.append($0) }
        )
        let getter: () -> [[String: Any]] = {
            box.messages.compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        return (server, getter)
    }

    func testInitializeReturnsServerInfo() {
        let (server, sent) = makeServer(handler: StubHandler())
        server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)

        let messages = sent()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["id"] as? Int, 1)
        let result = messages[0]["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "metaphor")
        XCTAssertEqual(info?["version"] as? String, "test")
    }

    func testToolsListReturnsRegisteredTools() {
        let (server, sent) = makeServer(handler: StubHandler())
        server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)

        let result = sent().first?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "snapshot")
    }

    func testToolsCallInvokesHandler() {
        let handler = StubHandler()
        let (server, sent) = makeServer(handler: handler)
        server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snapshot","arguments":{"label":"x"}}}"#)

        XCTAssertEqual(handler.calls.count, 1)
        XCTAssertEqual(handler.calls.first?.name, "snapshot")
        XCTAssertEqual(handler.calls.first?.arguments["label"] as? String, "x")

        let result = sent().first?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertEqual(result?["isError"] as? Bool, false)
    }

    func testNotificationProducesNoResponse() {
        let (server, sent) = makeServer(handler: StubHandler())
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertTrue(sent().isEmpty)
    }

    func testUnknownMethodReturnsMethodNotFound() {
        let (server, sent) = makeServer(handler: StubHandler())
        server.handle(#"{"jsonrpc":"2.0","id":9,"method":"bogus"}"#)

        let error = sent().first?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    func testRunDrainsLinesUntilEOF() {
        final class Box { var messages: [String] = [] }
        let box = Box()
        var input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            "",   // 空行はスキップ
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].makeIterator()
        let server = MCPServer(
            serverName: "metaphor", serverVersion: "test", handler: StubHandler(),
            readLine: { input.next() },
            writeMessage: { box.messages.append($0) }
        )
        server.run()
        XCTAssertEqual(box.messages.count, 2)
    }
}
