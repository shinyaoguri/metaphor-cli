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
        // スケッチのウィンドウ/ログがそのまま端末に出るよう標準入出力を継承。
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        return FoundationLaunchedProcess(process)
    }
}

/// `FoundationProcessLauncher` が返す `Process` ラッパー。
final class FoundationLaunchedProcess: LaunchedProcess {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        process.waitUntilExit()
    }
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

    private var current: (any LaunchedProcess)?

    public init(
        directory: URL,
        swiftArguments: [String],
        console: any Console,
        processRunner: any ProcessRunning,
        launcher: any ProcessLaunching,
        watcher: any FileWatching
    ) {
        self.directory = directory
        self.swiftArguments = swiftArguments
        self.console = console
        self.processRunner = processRunner
        self.launcher = launcher
        self.watcher = watcher
    }

    /// 初回ビルド+起動を行い、ファイル監視を開始する。
    public func start() throws {
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

        do {
            current = try launcher.launch(
                executable: "/usr/bin/env",
                arguments: ["swift", "run", "--skip-build"] + swiftArguments,
                currentDirectory: directory,
                environment: nil
            )
            console.write(initial ? "[watch] 実行中" : "[watch] リロードしました")
        } catch {
            console.writeError("[watch] 起動失敗: \(error)")
        }
    }
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
              metaphor watch [swift-build/run-arguments...]

            ソース（Sources/**/*.swift, Package.swift）を監視し、変更のたびに
            再ビルドしてスケッチを再起動します。ビルドが失敗した場合は動作中の
            スケッチを維持します。Ctrl-C で停止します。

            注: 現状はスケッチ自身のウィンドウを再起動します（再起動時にウィンドウが
            一瞬閉じます）。ウィンドウを維持したままのライブビューアは今後追加予定です。
            """)
            return
        }

        let package = currentDirectory.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: package.path) else {
            throw CLIError("Package.swift が見つかりません (\(currentDirectory.path))。スケッチのディレクトリで実行してください。", exitCode: 2)
        }

        let session = WatchSession(
            directory: currentDirectory,
            swiftArguments: arguments,
            console: console,
            processRunner: processRunner,
            launcher: FoundationProcessLauncher(),
            watcher: PollingFileWatcher(directory: currentDirectory)
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
