import Darwin
import Foundation

public struct ParsedWatchArguments: Equatable {
    /// `--syphon-name <name>` で指定された Syphon サーバー名（未指定なら nil）。
    public let syphonName: String?
    /// Probe を子で有効化するか（既定 true）。`--no-probe` で false。
    /// 有効だと `metaphor mcp` がアタッチして観測できる（共有セッション）。
    public let probeEnabled: Bool
    /// `--fps <n>` で指定されたレンダー FPS（未指定なら nil＝スケッチの config.fps）。
    /// 子へ `METAPHOR_FPS` 環境変数として渡す（CONTRACT.md 契約点 2）。
    public let fps: Int?
    /// `--metrics` でターミナルへのメトリクスライブ表示を有効化（既定 false）。
    /// 有効時は `--no-probe` に関わらず子へ `METAPHOR_PROBE=1` を渡す（供給元のため）。
    public let metricsEnabled: Bool
    /// `--metrics-interval <sec>` のポーリング間隔（未指定なら nil＝既定 1s）。
    /// 指定は `--metrics` を含意する。
    public let metricsInterval: Double?
    /// `watch` 専用フラグを除いた、swift build/run へ渡す引数。
    public let swiftArguments: [String]

    public init(
        syphonName: String?,
        probeEnabled: Bool = true,
        fps: Int? = nil,
        metricsEnabled: Bool = false,
        metricsInterval: Double? = nil,
        swiftArguments: [String]
    ) {
        self.syphonName = syphonName
        self.probeEnabled = probeEnabled
        self.fps = fps
        self.metricsEnabled = metricsEnabled
        self.metricsInterval = metricsInterval
        self.swiftArguments = swiftArguments
    }
}

/// `watch` の引数から `metaphor watch` 専用フラグを取り出し、残りを swift へ渡す引数として返す。
///
/// 取り除く専用フラグ:
/// - `--viewer` / `--no-viewer`（ビューア制御。`swift build --no-viewer` のような誤渡しを防ぐ）
/// - `--syphon-name <name>` / `--syphon-name=<name>`（Syphon サーバー名の指定。値ごと除去）
/// - `--fps <n>` / `--fps=<n>`（レンダー FPS の指定。値ごと除去。非数値・0 以下は無視）
/// - `--metrics` / `--metrics-interval <sec>`（メトリクスライブ表示。値ごと除去）
public func parseWatchArguments(_ args: [String]) -> ParsedWatchArguments {
    var syphonName: String?
    var probeEnabled = true
    var fps: Int?
    var metricsEnabled = false
    var metricsInterval: Double?
    var swift: [String] = []
    let prefix = "--syphon-name="
    let fpsPrefix = "--fps="
    let metricsIntervalPrefix = "--metrics-interval="
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch true {
        case arg == "--syphon-name":
            // 次のトークンを名前として取り込む（無ければ無視）。
            if i + 1 < args.count {
                syphonName = args[i + 1]
                i += 1
            }
        case arg.hasPrefix(prefix):
            syphonName = String(arg.dropFirst(prefix.count))
        case arg == "--fps":
            // 次のトークンを FPS として取り込む（無ければ無視）。
            if i + 1 < args.count {
                fps = Int(args[i + 1])
                i += 1
            }
        case arg.hasPrefix(fpsPrefix):
            fps = Int(arg.dropFirst(fpsPrefix.count))
        case arg == "--metrics":
            metricsEnabled = true
        case arg == "--metrics-interval":
            // 次のトークンを間隔（秒）として取り込む（無ければ無視）。
            if i + 1 < args.count {
                metricsInterval = Double(args[i + 1])
                i += 1
            }
        case arg.hasPrefix(metricsIntervalPrefix):
            metricsInterval = Double(arg.dropFirst(metricsIntervalPrefix.count))
        case arg == "--viewer", arg == "--no-viewer":
            break  // 何もしない（除去）
        case arg == "--no-probe":
            probeEnabled = false  // 共有セッションを無効化（除去）
        default:
            swift.append(arg)
        }
        i += 1
    }
    // 空文字の名前は無効として無視（`--syphon-name ""` 等）。
    if let name = syphonName, name.isEmpty { syphonName = nil }
    // 0 以下の FPS は無効として無視。
    if let value = fps, value <= 0 { fps = nil }
    // 0 以下・非数値の interval は無効として無視。interval 指定は --metrics を含意。
    if let value = metricsInterval, value <= 0 { metricsInterval = nil }
    metricsEnabled = metricsEnabled || metricsInterval != nil
    return ParsedWatchArguments(
        syphonName: syphonName,
        probeEnabled: probeEnabled,
        fps: fps,
        metricsEnabled: metricsEnabled,
        metricsInterval: metricsInterval,
        swiftArguments: swift
    )
}

// MARK: - Watch command (entry point + run loop)

public struct WatchCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL
    private let fileManager: FileManager

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    public func run(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            console.write("""
            Usage:
              metaphor watch [--no-viewer] [--syphon-name <name>] [--fps <n>] [--metrics] [swift-build/run-arguments...]

            ソース（Sources/**/*.swift, Package.swift）を監視し、変更のたびに
            再ビルドします。ビルドが失敗した場合は動作中のスケッチを維持します。
            Ctrl-C で停止します。

            既定（ライブビューア）:
              常設のライブビューア窓を開き、再ビルド時はスケッチ（子プロセス）だけを
              差し替えます。ウィンドウは閉じず、再ビルド中は直前のフレームを表示し
              続けます。マウス/キー入力はビューアからスケッチへ転送されます。
              （スケッチは Syphon 経由のヘッドレスで動作。スケッチ側の設定は不要）

            --no-viewer:
              ビューアを使わず、スケッチ自身のウィンドウを再起動します
              （再起動時にウィンドウが一瞬閉じます）。実際の窓そのままで確認したい、
              Syphon を経由したくない、といった場合に使います。

            --syphon-name <name>:
              既定（ビューア）モードで publish する Syphon サーバー名を固定します。
              未指定だと watch プロセスごとに変わる名前（衝突しないが毎回変わる）に
              なります。MadMapper 等へ安定した名前で送りたいときに使います。

            --fps <n>:
              スケッチのレンダー FPS を上書きします（子へ METAPHOR_FPS を渡す）。
              未指定だとスケッチの config.fps が使われます。ビューア／--no-viewer の
              どちらのモードでも有効です。

            --metrics:
              fps・フレーム時間・メモリ・CPU・thermal をターミナル最下行へライブ
              表示します（Probe の performance を定期ポーリング。MCP 不要）。
              --no-probe と併用した場合も子へ METAPHOR_PROBE=1 は渡します
              （メトリクスの供給元のため。MCP アタッチ用の session.json は書かない）。

            --metrics-interval <sec>:
              --metrics のポーリング間隔（既定 1 秒、下限 0.2 秒）。--metrics を
              含意します。
            """)
            return
        }

        let package = currentDirectory.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: package.path) else {
            throw CLIError("Package.swift が見つかりません (\(currentDirectory.path))。スケッチのディレクトリで実行してください。", exitCode: 2)
        }

        // watch 専用フラグ（ビューア制御・--syphon-name）は swift へ渡さない。
        let parsed = parseWatchArguments(arguments)

        // --no-viewer（このパス）でも、子へ Syphon 名を環境変数で渡しておく。実際に
        // ウィンドウモードで publish するにはスケッチ側の Syphon 有効化が必要。
        // Probe（既定 ON、--no-probe で OFF）を有効にすると `metaphor mcp` から
        // アタッチして観測できる（共有セッション）。
        var environment: [String: String] = [:]
        if let name = parsed.syphonName {
            environment["METAPHOR_SYPHON_NAME"] = name
        }
        if parsed.probeEnabled || parsed.metricsEnabled {
            // --metrics はメトリクスの供給元として Probe を必要とする。--no-probe
            // 併用時も注入するが、shareSession（MCP アタッチ可否）は probeEnabled に従う。
            environment["METAPHOR_PROBE"] = "1"
        }
        if let fps = parsed.fps {
            environment["METAPHOR_FPS"] = String(fps)
        }

        let session = WatchSession(
            directory: currentDirectory,
            swiftArguments: parsed.swiftArguments,
            console: console,
            processRunner: processRunner,
            launcher: FoundationProcessLauncher(),
            watcher: PollingFileWatcher(directory: currentDirectory),
            extraEnvironment: environment.isEmpty ? nil : environment,
            shareSession: parsed.probeEnabled
        )

        var reporter: MetricsReporter?
        if parsed.metricsEnabled {
            reporter = MetricsReporter(
                sketchDirectory: currentDirectory, interval: parsed.metricsInterval
            )
        }

        try session.start()
        reporter?.start()
        waitUntilInterrupted(session: session, reporter: reporter)
    }

    /// SIGINT/SIGTERM を待ち、受信したらスケッチを停止して終了する。
    /// `dispatchMain()` がファイル監視タイマーと子プロセスを生かしたまま回す。
    private func waitUntilInterrupted(session: WatchSession, reporter: MetricsReporter?) -> Never {
        let console = self.console
        let install: (Int32) -> Void = { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                // 先にステータスライン行を確定させ、停止ログと混ざらないようにする。
                reporter?.stop()
                console.write("\n[watch] 停止します…")
                session.stop()
                Foundation.exit(0)
            }
            source.resume()
            // dispatchMain() は戻らないため、source はプロセス寿命まで保持される。
            Self.retainedSignalSources.append(source)
        }
        install(SIGINT)
        install(SIGTERM)
        dispatchMain()
    }

    /// シグナルソースの解放を防ぐための保持先（プロセス寿命）。
    nonisolated(unsafe) private static var retainedSignalSources: [DispatchSourceSignal] = []
}
