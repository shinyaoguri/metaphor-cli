import Darwin
import Foundation

// MARK: - Process launching (non-blocking)

/// 起動済みの子プロセスへのハンドル。`ProcessRunning` が完了まで待つのと違い、
/// `watch` はスケッチを動かしたまま次の変更で停止できる必要があるため分離している。
public protocol LaunchedProcess: AnyObject {
    /// プロセスがまだ実行中かどうか。
    var isRunning: Bool { get }
    /// プロセスに終了を要求し、終了まで待つ。
    func terminate()
    /// 子の stdin へ 1 行（末尾改行付き）書き込む。入力イベント（JSON Lines）の転送に使う。
    func sendLine(_ line: String)
}

/// 子プロセスを**ブロックせずに**起動する抽象。テストで差し替え可能。
public protocol ProcessLaunching {
    func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> any LaunchedProcess
}

/// `Foundation.Process` を `waitUntilExit()` せずに起動する実装。
public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> any LaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }
        // stdin は端末を継承させず**パイプ**にする。
        // 重要: 端末(TTY)を継承すると、バックグラウンドの子（ヘッドレス時の
        // InputInjectionPlugin が stdin を読む）が制御端末の読み取りで SIGTTIN を受けて
        // 停止し、レンダリング/フレーム publish が止まる（ビューア窓が黒くなる）。
        // 書き込み端は LaunchedProcess が保持して開いたままにする（将来の入力転送で使う）。
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe.fileHandleForReading
        // ログ/ウィンドウはそのまま端末へ。
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        return FoundationLaunchedProcess(process, stdinWrite: stdinPipe.fileHandleForWriting)
    }
}

/// `FoundationProcessLauncher` が返す `Process` ラッパー。
final class FoundationLaunchedProcess: LaunchedProcess {
    private let process: Process
    /// 子の stdin（パイプ書き込み端）。開いたまま保持し、将来の入力転送に使う。
    private let stdinWrite: FileHandle

    init(_ process: Process, stdinWrite: FileHandle) {
        self.process = process
        self.stdinWrite = stdinWrite
        // 書き込みをノンブロッキングにする。再起動直後の子が stdin を読み始める前は
        // パイプに空きが無くなりうるが、その際 sendLine が**メインスレッドでブロックして
        // ビューアごと固まる**のを防ぐ（満杯ならそのイベントを捨てる）。
        let flags = fcntl(stdinWrite.fileDescriptor, F_GETFL)
        if flags != -1 {
            _ = fcntl(stdinWrite.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        process.waitUntilExit()
        try? stdinWrite.close()
    }

    func sendLine(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        // ノンブロッキング書き込み。1 行は PIPE_BUF(512) 未満なので write はアトミック：
        // 空きが足りなければ EAGAIN で即返るので、その行は捨てる（入力はロスト許容）。
        // 子が消えていれば EPIPE。SIGPIPE はプロセス起動時に無視している（installSIGPIPEIgnore）。
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = Darwin.write(stdinWrite.fileDescriptor, base, raw.count)
        }
    }
}

/// 閉じたパイプ（終了した子の stdin）への書き込みで SIGPIPE に殺されないよう、
/// プロセス全体で SIGPIPE を無視する。入力転送を行う前に一度だけ呼ぶ。
public func installSIGPIPEIgnore() {
    signal(SIGPIPE, SIG_IGN)
}

// MARK: - File watching

/// ソース変更を通知する抽象。テストで手動発火できるよう分離。
public protocol FileWatching: AnyObject {
    /// 監視を開始する。変更検出のたびに `onChange` を呼ぶ。
    func start(onChange: @escaping () -> Void) throws
    /// 監視を停止する。
    func stop()
}

/// `Sources/**/*.swift` と `Package.swift` の更新時刻を定期的に走査し、
/// 署名（連結文字列）が変わったら通知するポーリング型ウォッチャ。
///
/// kqueue/vnode の再帰監視より単純で堅牢。ポーリング間隔が連続保存の
/// デバウンスも兼ねる。
public final class PollingFileWatcher: FileWatching {
    private let directory: URL
    private let interval: TimeInterval
    private let fileManager: FileManager
    private var timer: DispatchSourceTimer?
    private var lastSignature: String = ""

    public init(directory: URL, interval: TimeInterval = 0.4, fileManager: FileManager = .default) {
        self.directory = directory
        self.interval = interval
        self.fileManager = fileManager
    }

    public func start(onChange: @escaping () -> Void) throws {
        lastSignature = signature()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "org.metaphor.watch.poll")
        )
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.signature()
            if current != self.lastSignature {
                self.lastSignature = current
                onChange()
            }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 監視対象ファイルの「パス:更新時刻」を連結したソート済み署名。
    ///
    /// パッケージディレクトリ配下の全 `*.swift`（`Package.swift` 含む）を対象とし、
    /// レイアウト（慣習的な `Sources/` / カスタム `path:` のどちらでも）に依存しない。
    /// `.build` や `.git` などの隠しディレクトリは `.skipsHiddenFiles` で除外される。
    private func signature() -> String {
        var entries: [String] = []

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate {
                    entries.append("\(url.path):\(date.timeIntervalSince1970)")
                }
            }
        }

        return entries.sorted().joined(separator: "|")
    }
}

// MARK: - Watch session (testable core)

/// `metaphor watch` のコアロジック。ビルド・起動・再起動の制御のみを担い、
/// 実行ループやシグナル処理は ``WatchCommand`` 側に置く。注入された
/// ``ProcessRunning`` / ``ProcessLaunching`` / ``FileWatching`` により単体テスト可能。
public final class WatchSession {
    private let directory: URL
    private let swiftArguments: [String]
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let launcher: any ProcessLaunching
    private let watcher: any FileWatching
    private let binaryResolver: any SketchBinaryResolving
    private let extraEnvironment: [String: String]?

    /// 動作中の子スケッチ。再ビルド（バックグラウンドキュー）から書き換わり、
    /// 入力転送（メインスレッドの `forwardInput`）から読まれるため、頻発する
    /// マウス移動でのデータ競合を避けるようロックで保護する。getter は強参照を
    /// 返すので、読んだ直後に reload が走っても掴んだ子は有効なまま。
    private let currentLock = NSLock()
    private var _current: (any LaunchedProcess)?
    private var current: (any LaunchedProcess)? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); defer { currentLock.unlock() }; _current = newValue }
    }
    /// 解決済みの実行ファイルパス（初回解決後にキャッシュ）。
    private var resolvedBinary: String?

    /// 子スケッチを（再）起動したときに呼ばれる。ビューアが Syphon サーバーの
    /// 差し替え（同名・別 UUID）に追従するための通知に使う。バックグラウンドキューから
    /// 呼ばれうるので、受け手はメインスレッドへホップすること。
    public var onChildLaunched: (() -> Void)?

    public init(
        directory: URL,
        swiftArguments: [String],
        console: any Console,
        processRunner: any ProcessRunning,
        launcher: any ProcessLaunching,
        watcher: any FileWatching,
        binaryResolver: any SketchBinaryResolving = SwiftPMBinaryResolver(),
        extraEnvironment: [String: String]? = nil
    ) {
        self.directory = directory
        self.swiftArguments = swiftArguments
        self.console = console
        self.processRunner = processRunner
        self.launcher = launcher
        self.watcher = watcher
        self.binaryResolver = binaryResolver
        self.extraEnvironment = extraEnvironment
    }

    /// 初回ビルド+起動を行い、ファイル監視を開始する。
    public func start() throws {
        // どの CLI ビルドが動いているか毎回表示（古いインストールの取り違え防止）。
        // スケッチ子プロセスは自分で `[metaphor] <版>` を出すので、ここは CLI 版のみ。
        console.write("[watch] \(BuildInfo.cliIdentifier)")
        console.write("metaphor watch: \(directory.path)")
        console.write("[watch] Ctrl-C で停止")
        rebuildAndLaunch(initial: true)
        try watcher.start { [weak self] in
            self?.reload()
        }
    }

    /// 変更検出時の再ビルド+再起動。
    public func reload() {
        console.write("[watch] 変更を検出 — 再ビルド中…")
        rebuildAndLaunch(initial: false)
    }

    /// 監視と実行中スケッチを停止する。
    public func stop() {
        watcher.stop()
        current?.terminate()
        current = nil
    }

    /// 入力イベント（JSON Lines 1 行）を現在動作中の子スケッチへ転送する。
    /// 再ビルド中で子が居ない瞬間は黙って捨てる（次の子に引き継がない）。
    public func forwardInput(_ line: String) {
        current?.sendLine(line)
    }

    /// ビルドが通った場合のみ、前のスケッチを終了して新しく起動する。
    /// ビルド失敗時は動作中のスケッチを維持する（壊れた編集で窓を消さない）。
    private func rebuildAndLaunch(initial: Bool) {
        let build = (try? processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["swift", "build"] + swiftArguments,
            currentDirectory: directory,
            captureOutput: false
        )) ?? ProcessResult(exitCode: -1)

        guard build.exitCode == 0 else {
            if initial {
                console.writeError("[watch] 初回ビルド失敗 (exit \(build.exitCode)) — 変更を待機します")
            } else {
                console.writeError("[watch] ビルド失敗 (exit \(build.exitCode)) — 直前のスケッチを維持します")
            }
            return
        }

        current?.terminate()
        current = nil

        // ビルド済みバイナリを直接起動する（swift run はロック競合時に fork して
        // プロセスが二重化しうるため）。解決できなければ swift run にフォールバック。
        if resolvedBinary == nil {
            resolvedBinary = binaryResolver.resolve(directory: directory, swiftArguments: swiftArguments)
        }

        let executable: String
        let arguments: [String]
        if let binary = resolvedBinary {
            executable = binary
            arguments = []
        } else {
            executable = "/usr/bin/env"
            arguments = ["swift", "run", "--skip-build"] + swiftArguments
        }

        do {
            current = try launcher.launch(
                executable: executable,
                arguments: arguments,
                currentDirectory: directory,
                environment: extraEnvironment
            )
            console.write(initial ? "[watch] 実行中" : "[watch] リロードしました")
            onChildLaunched?()  // ビューアに Syphon サーバーの差し替え追従を促す。
        } catch {
            console.writeError("[watch] 起動失敗: \(error)")
        }
    }
}

/// `metaphor watch` 専用フラグを解釈した結果。
public struct ParsedWatchArguments: Equatable {
    /// `--syphon-name <name>` で指定された Syphon サーバー名（未指定なら nil）。
    public let syphonName: String?
    /// `watch` 専用フラグを除いた、swift build/run へ渡す引数。
    public let swiftArguments: [String]

    public init(syphonName: String?, swiftArguments: [String]) {
        self.syphonName = syphonName
        self.swiftArguments = swiftArguments
    }
}

/// `watch` の引数から `metaphor watch` 専用フラグを取り出し、残りを swift へ渡す引数として返す。
///
/// 取り除く専用フラグ:
/// - `--viewer` / `--no-viewer`（ビューア制御。`swift build --no-viewer` のような誤渡しを防ぐ）
/// - `--syphon-name <name>` / `--syphon-name=<name>`（Syphon サーバー名の指定。値ごと除去）
public func parseWatchArguments(_ args: [String]) -> ParsedWatchArguments {
    var syphonName: String?
    var swift: [String] = []
    let prefix = "--syphon-name="
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
        case arg == "--viewer", arg == "--no-viewer":
            break  // 何もしない（除去）
        default:
            swift.append(arg)
        }
        i += 1
    }
    // 空文字の名前は無効として無視（`--syphon-name ""` 等）。
    if let name = syphonName, name.isEmpty { syphonName = nil }
    return ParsedWatchArguments(syphonName: syphonName, swiftArguments: swift)
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
              metaphor watch [--no-viewer] [swift-build/run-arguments...]

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
        var environment: [String: String]?
        if let name = parsed.syphonName {
            environment = ["METAPHOR_SYPHON_NAME": name]
        }

        let session = WatchSession(
            directory: currentDirectory,
            swiftArguments: parsed.swiftArguments,
            console: console,
            processRunner: processRunner,
            launcher: FoundationProcessLauncher(),
            watcher: PollingFileWatcher(directory: currentDirectory),
            extraEnvironment: environment
        )

        try session.start()
        waitUntilInterrupted(session: session)
    }

    /// SIGINT/SIGTERM を待ち、受信したらスケッチを停止して終了する。
    /// `dispatchMain()` がファイル監視タイマーと子プロセスを生かしたまま回す。
    private func waitUntilInterrupted(session: WatchSession) -> Never {
        let console = self.console
        let install: (Int32) -> Void = { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
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
