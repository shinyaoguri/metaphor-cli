import Darwin
import Foundation
import MetaphorCLICore
import MetaphorViewer

@main
enum MetaphorCLIEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // 内部コマンド（ビューア関連）。Syphon/Metal/AppKit を要するため、
        // 純粋ロジックの MetaphorCLICore ではなく実行ファイル側で処理する。
        if let first = arguments.first, first.hasPrefix("__") {
            handleInternalCommand(first, Array(arguments.dropFirst()))
            return
        }

        let tool = CommandLineTool()
        do {
            try tool.run(arguments: arguments)
        } catch let error as CLIError {
            StandardConsole().writeError("error: \(error.message)")
            exit(error.exitCode)
        } catch {
            StandardConsole().writeError("error: \(error)")
            exit(1)
        }
    }

    /// 開発/検証用の内部コマンド。ユーザー向けには表に出さない。
    private static func handleInternalCommand(_ command: String, _ rest: [String]) {
        switch command {
        case "__view":
            // metaphor __view <serverName> [title]
            guard let serverName = rest.first else {
                StandardConsole().writeError("usage: metaphor __view <serverName> [title]")
                exit(2)
            }
            let title = rest.count >= 2 ? rest[1] : serverName
            runViewer(serverName: serverName, title: title)
        case "__capture":
            // metaphor __capture <serverName> <outputPath> [timeoutSeconds]
            guard rest.count >= 2 else {
                StandardConsole().writeError("usage: metaphor __capture <serverName> <outputPath> [timeout]")
                exit(2)
            }
            let timeout = rest.count >= 3 ? (Double(rest[2]) ?? 8.0) : 8.0
            let ok = captureSyphonFrame(serverName: rest[0], outputPath: rest[1], timeout: timeout)
            if ok {
                StandardConsole().write("captured \(rest[0]) -> \(rest[1])")
            } else {
                StandardConsole().writeError("capture failed for server '\(rest[0])'")
                exit(1)
            }
        default:
            StandardConsole().writeError("unknown internal command: \(command)")
            exit(2)
        }
    }
}
