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

        // api_reference 用: 依存先 metaphor の docs ルートを呼び出しごとに解決する
        // （初回ビルド後に出現する .build/checkouts も拾えるよう遅延評価）。
        let docsLocator = MetaphorDocsLocator()
        let docsRootProvider: () -> URL? = { docsLocator.resolve(sketchDirectory: directory) }

        let handler: SketchToolHandler

        if let manifest = SharedSession.liveManifest(for: directory) {
            // --- アタッチモード: 動作中の `metaphor watch` を共有 ---
            // 子を spawn せず・build せず、既存の Probe ファイルで観測する。
            // 編集は人間/AI がファイルを直接書き、watch が再ビルドする。
            installSignalHandlers(onStop: nil)
            if !manifest.probeEnabled {
                console.writeError(
                    "[mcp] 警告: アタッチ先セッションは Probe 無効（--no-probe）です。"
                        + "snapshot は失敗します。watch を --no-probe なしで再起動してください。"
                )
            }
            handler = SketchToolHandler(
                snapshotTool: ProbeSnapshotTool(sketchDirectory: directory),
                forwardInput: { _ in },   // 共有セッションでは AI 入力注入は対象外（操作はコード編集）
                buildStatusProvider: { SharedSession.readBuildStatus(for: directory) },
                inputAvailable: false,
                docsRootProvider: docsRootProvider
            )
            console.writeError(
                "[mcp] attached — 動作中の watch セッション (pid \(manifest.pid)) を観測します"
            )
        } else {
            // --- 単独モード（従来）: 自前で子をヘッドレス起動して所有する ---
            // Syphon は安定名（スケッチ名）で publish したまま維持する。AI が MCP で
            // 観測している最中も、人間が MadMapper 等で同じ出力を一覧から拾えるように
            // するため（per-pid の不安定名だと毎回選び直しになる）。
            let syphonName = SyphonName.stable(for: directory)
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
                ],
                captureBuildOutput: true   // build_status 用にビルド出力を捕捉
            )

            installSignalHandlers(onStop: { session.stop() })

            do {
                try session.start()
            } catch {
                console.writeError("[mcp] スケッチ起動に失敗: \(error)")
                throw CLIError("mcp: スケッチを起動できませんでした", exitCode: 1)
            }

            handler = SketchToolHandler(
                snapshotTool: ProbeSnapshotTool(sketchDirectory: directory),
                forwardInput: { [weak session] line in session?.forwardInput(line) },
                buildStatusProvider: { [weak session] in session?.lastBuildOutcome },
                docsRootProvider: docsRootProvider
            )
            // server.run() の後始末。単独モードのみ子を止める。
            defer { session.stop() }
            runServer(handler: handler, outputHandle: outputHandle, directory: directory)
            return
        }

        runServer(handler: handler, outputHandle: outputHandle, directory: directory)
    }

    /// MCP サーバ（stdio）を起動して stdin EOF までブロックする。
    private func runServer(handler: SketchToolHandler, outputHandle: FileHandle, directory: URL) {
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
    }

    /// SIGINT/SIGTERM で（必要なら子スケッチを止めてから）終了する。readLine が
    /// メインスレッドをブロックするため、シグナルは専用キューの DispatchSource で受ける。
    private func installSignalHandlers(onStop: (() -> Void)?) {
        let install: (Int32) -> Void = { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                onStop?()
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
      snapshot       現在フレームの PNG と内部状態(frame.json)を返す
      input          マウス/キー入力を動作中のスケッチへ送る
      build_status   直近の `swift build` の成否・エラーを返す
      api_reference  依存先 metaphor の API ドキュメント(llms.txt 等)を返す

    引数を省略するとカレントディレクトリのスケッチを対象にする。
    """
}

/// シグナルソースをプロセス寿命まで保持する。
private nonisolated(unsafe) var retainedMCPSignalSources: [DispatchSourceSignal] = []
