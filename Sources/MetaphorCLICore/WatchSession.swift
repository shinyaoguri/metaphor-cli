import Foundation

// MARK: - Watch session (testable core)

/// `metaphor watch` のコアロジック。ビルド・起動・再起動の制御のみを担い、
/// 実行ループやシグナル処理は ``WatchCommand`` 側に置く。注入された
/// ``ProcessRunning`` / ``ProcessLaunching`` / ``FileWatching`` により単体テスト可能。
/// `swift build` の結果サマリ。`metaphor mcp` の `build_status` などが参照する。
public struct BuildOutcome: Equatable, Codable {
    public let succeeded: Bool
    public let exitCode: Int32
    /// ビルド出力（stderr 中心）。`captureBuildOutput=true` のときだけ中身が入る。
    public let output: String
    /// 初回ビルドか（reload ではなく start 時）。
    public let initial: Bool

    public init(succeeded: Bool, exitCode: Int32, output: String, initial: Bool) {
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.output = output
        self.initial = initial
    }
}

public final class WatchSession {
    private let directory: URL
    private let swiftArguments: [String]
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let launcher: any ProcessLaunching
    private let watcher: any FileWatching
    private let binaryResolver: any SketchBinaryResolving
    private let extraEnvironment: [String: String]?
    /// true のとき `swift build` の出力を捕捉して `lastBuildOutcome` に残す
    /// （`metaphor mcp` の `build_status` 用）。false（既定 = `watch`）では従来どおり
    /// 端末へ素通しし、出力テキストは記録しない。
    private let captureBuildOutput: Bool
    /// true のとき共有セッション（`metaphor mcp` がアタッチして観測する）として動作する。
    /// 起動時に `.metaphor/session.json` を、毎ビルドで `.metaphor/build-status.json` を
    /// 書き、停止時にマニフェストを削除する。出力テキストも必要なので捕捉を強制する。
    private let shareSession: Bool

    private let buildLock = NSLock()
    private var _lastBuildOutcome: BuildOutcome?
    /// 直近の `swift build` の結果。`captureBuildOutput=true` のときだけ `output` に
    /// ビルド出力（エラー含む）が入る。
    public var lastBuildOutcome: BuildOutcome? {
        buildLock.lock(); defer { buildLock.unlock() }; return _lastBuildOutcome
    }

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

    /// `swift build` を始める直前に呼ばれる（`initial` = 初回ビルドかどうか）。
    /// ビューアが「ビルド中…」のローディング表示へ切り替えるための通知。
    /// `onChildLaunched` 同様バックグラウンドキューから呼ばれうるので、受け手は
    /// メインスレッドへホップすること。
    public var onBuildWillStart: ((_ initial: Bool) -> Void)?

    /// `swift build` が終わった直後に、結果（`BuildOutcome`）とともに呼ばれる。
    /// ビューアがビルド失敗を可視化するための通知。成功時は続けて
    /// `onChildLaunched` が呼ばれる。バックグラウンドキューから呼ばれうる。
    public var onBuildFinished: ((BuildOutcome) -> Void)?

    public init(
        directory: URL,
        swiftArguments: [String],
        console: any Console,
        processRunner: any ProcessRunning,
        launcher: any ProcessLaunching,
        watcher: any FileWatching,
        binaryResolver: (any SketchBinaryResolving)? = nil,
        extraEnvironment: [String: String]? = nil,
        captureBuildOutput: Bool = false,
        shareSession: Bool = false
    ) {
        self.directory = directory
        self.swiftArguments = swiftArguments
        self.console = console
        self.processRunner = processRunner
        self.launcher = launcher
        self.watcher = watcher
        // 既定の解決器には console を渡し、解決失敗（swift run への低速フォールバック）を
        // 黙らせず一度だけ通知する。テストはカスタム解決器を注入できる。
        self.binaryResolver = binaryResolver ?? SwiftPMBinaryResolver(console: console)
        self.extraEnvironment = extraEnvironment
        // 共有セッションでは build-status.json にエラー文も載せたいので捕捉を強制する。
        self.captureBuildOutput = captureBuildOutput || shareSession
        self.shareSession = shareSession
    }

    /// 初回ビルド+起動を行い、ファイル監視を開始する。
    public func start() throws {
        // どの CLI ビルドが動いているか毎回表示（古いインストールの取り違え防止）。
        // スケッチ子プロセスは自分で `[metaphor] <版>` を出すので、ここは CLI 版のみ。
        console.write("[watch] \(BuildInfo.cliIdentifier)")
        console.write("metaphor watch: \(directory.path)")
        console.write("[watch] Ctrl-C で停止")
        if shareSession {
            publishManifest()
        }
        rebuildAndLaunch(initial: true)
        try watcher.start { [weak self] in
            self?.reload()
        }
    }

    /// 共有セッションのマニフェスト（`.metaphor/session.json`）を書き出す。
    private func publishManifest() {
        let manifest = SharedSession.Manifest(
            pid: ProcessInfo.processInfo.processIdentifier,
            sketchPath: directory.path,
            syphonName: extraEnvironment?["METAPHOR_SYPHON_NAME"],
            probeEnabled: extraEnvironment?["METAPHOR_PROBE"] == "1",
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        SharedSession.writeManifest(manifest, for: directory)
        console.write("[watch] 共有セッション: metaphor mcp からアタッチ観測できます")
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
        if shareSession {
            SharedSession.removeManifest(for: directory)
        }
    }

    /// 入力イベント（JSON Lines 1 行）を現在動作中の子スケッチへ転送する。
    /// 再ビルド中で子が居ない瞬間は黙って捨てる（次の子に引き継がない）。
    public func forwardInput(_ line: String) {
        current?.sendLine(line)
    }

    /// 直近ビルドの結果を記録し、その `BuildOutcome` を返す。
    /// `captureBuildOutput=false` のときは出力テキストは空。
    @discardableResult
    private func recordBuildOutcome(_ result: ProcessResult, initial: Bool) -> BuildOutcome {
        let output = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let outcome = BuildOutcome(
            succeeded: result.exitCode == 0,
            exitCode: result.exitCode,
            output: output,
            initial: initial
        )
        buildLock.lock()
        _lastBuildOutcome = outcome
        buildLock.unlock()

        if shareSession {
            SharedSession.writeBuildStatus(outcome, for: directory)
        }
        return outcome
    }

    /// ビルドが通った場合のみ、前のスケッチを終了して新しく起動する。
    /// ビルド失敗時は動作中のスケッチを維持する（壊れた編集で窓を消さない）。
    private func rebuildAndLaunch(initial: Bool) {
        onBuildWillStart?(initial)

        let build: ProcessResult
        do {
            build = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: ["swift", "build"] + swiftArguments,
                currentDirectory: directory,
                captureOutput: captureBuildOutput
            )
        } catch {
            // `swift build` の起動自体に失敗（env/swift 不在、権限など）。通常のビルド
            // 失敗(exit!=0)と区別がつくよう必ずログし、合成の失敗結果で続行する。
            console.writeError("[watch] ビルド実行エラー: \(error)")
            build = ProcessResult(exitCode: -1)
        }

        let outcome = recordBuildOutcome(build, initial: initial)
        onBuildFinished?(outcome)

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

