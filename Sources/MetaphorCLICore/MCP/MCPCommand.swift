import Darwin
import Foundation

/// `metaphor mcp [sketch-dir]`: AI エージェント向けのローカル MCP サーバ。
///
/// 既存の `WatchSession` を再利用してスケッチをヘッドレス + Probe 付きで起動し、
/// 自身の stdin/stdout で MCP(JSON-RPC/stdio) を喋る。
///
/// **stdout 衛生**: stdout は JSON-RPC 専用なので、CLI ログ・`swift build` 出力・
/// 子プロセスの出力が混ざると壊れる。起動直後に fd 1 を fd 2(stderr) へ向け替え、
/// 本物の stdout は退避して JSON-RPC 用にだけ使う。これにより WatchSession /
/// launcher / processRunner を一切改修せずに stdout を保護できる（子は dup2 後の
/// fd 1 = stderr を継承するので、子の stdout も stderr へ流れる）。
public struct MCPCommand {
    private let console: any Console
    private let currentDirectory: URL

    public init(console: any Console, currentDirectory: URL) {
        self.console = console
        self.currentDirectory = currentDirectory
    }

    public func run(arguments: [String]) throws {
        let options = try OptionParser.parse(arguments)
        if options.flag("help", "h") {
            console.write(Self.helpText)
            return
        }

        let directory: URL = options.positionals.first
            .map { PathResolver.url(from: $0, relativeTo: currentDirectory) }
            ?? currentDirectory

        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw CLIError(
                "Package.swift が見つかりません (\(directory.path))。"
                    + "スケッチのディレクトリで実行するか、パスを指定してください。",
                exitCode: 2
            )
        }

        // --- stdout 衛生: fd 1 を stderr へ向け替え、本物の stdout を退避 ---
        let realStdout = dup(1)
        dup2(2, 1)
        let outputHandle = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)

        // 子の stdin パイプが閉じても SIGPIPE で死なないように。
        installSIGPIPEIgnore()

        let syphonName = "metaphor-mcp-\(ProcessInfo.processInfo.processIdentifier)"
        let session = WatchSession(
            directory: directory,
            swiftArguments: [],
            console: console,   // print は dup2 により stderr に出る
            processRunner: FoundationProcessRunner(),
            launcher: FoundationProcessLauncher(),
            watcher: PollingFileWatcher(directory: directory),
            extraEnvironment: [
                "METAPHOR_VIEWER": "1",   // ヘッドレス + タイマー駆動
                "METAPHOR_PROBE": "1",    // Probe を自動登録
                "METAPHOR_SYPHON_NAME": syphonName,
            ]
        )

        installSignalHandlers(session: session)

        do {
            try session.start()
        } catch {
            console.writeError("[mcp] スケッチ起動に失敗: \(error)")
            throw CLIError("mcp: スケッチを起動できませんでした", exitCode: 1)
        }

        let handler = SketchToolHandler(
            snapshotTool: ProbeSnapshotTool(sketchDirectory: directory)
        )
        let server = MCPServer(
            serverName: "metaphor",
            serverVersion: BuildInfo.version,
            handler: handler,
            readLine: { Swift.readLine(strippingNewline: true) },
            writeMessage: { message in
                guard let data = (message + "\n").data(using: .utf8) else { return }
                outputHandle.write(data)
            }
        )

        console.writeError("[mcp] ready — sketch: \(directory.lastPathComponent)")
        server.run()   // stdin EOF までブロック
        session.stop()
    }

    /// SIGINT/SIGTERM で子スケッチを止めてから終了する。readLine がメインスレッドを
    /// ブロックするため、シグナルは専用キューの DispatchSource で受ける。
    private func installSignalHandlers(session: WatchSession) {
        let install: (Int32) -> Void = { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                session.stop()
                Foundation.exit(0)
            }
            source.resume()
            retainedMCPSignalSources.append(source)
        }
        install(SIGINT)
        install(SIGTERM)
    }

    public static let helpText = """
    metaphor mcp [sketch-dir]

    AI エージェント向けのローカル MCP サーバ。スケッチをヘッドレス + Probe 付きで
    起動し、stdin/stdout で MCP(JSON-RPC/stdio) を喋る。

    Tools:
      snapshot  現在フレームの PNG と内部状態(frame.json)を返す

    引数を省略するとカレントディレクトリのスケッチを対象にする。
    """
}

/// シグナルソースをプロセス寿命まで保持する。
private nonisolated(unsafe) var retainedMCPSignalSources: [DispatchSourceSignal] = []
