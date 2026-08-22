import AppKit
import Darwin
import Foundation
import Metal
import MetaphorCLICore

/// `metaphor watch --viewer`: 常設のライブビューア窓を保ちつつ、ソース変更で
/// 子スケッチ（ヘッドレス）だけを差し替える。
///
/// 子は `METAPHOR_VIEWER=1` + `METAPHOR_VIEWER_SOCKET=<path>` で起動し、frame IPC
/// （CONTRACT.md 契約点 5: Unix socket + 共有メモリ）でビューアへフレームを送る。
/// 再ビルド時は子だけを止めて起動し直し、ビューア窓はそのまま（直前フレームを表示し続ける）。
public func runViewerWatch(
    directory: URL,
    swiftArguments: [String],
    syphonName requestedSyphonName: String? = nil,
    probeEnabled: Bool = true,
    fps: Int? = nil,
    metricsEnabled: Bool = false,
    metricsInterval: Double? = nil,
    console: any Console
) throws {
    let package = directory.appendingPathComponent("Package.swift")
    guard FileManager.default.fileExists(atPath: package.path) else {
        throw CLIError(
            "Package.swift が見つかりません (\(directory.path))。スケッチのディレクトリで実行してください。",
            exitCode: 2
        )
    }

    // CLI 版バナーは WatchSession.start() が出す（viewer/非 viewer 共通の単一箇所）。

    // 終了した子の stdin（閉じたパイプ）へ入力転送を書き込んでも SIGPIPE で
    // ビューアが死なないようにする。
    installSIGPIPEIgnore()

    // フレーム転送の socket は子を起動する**前**に listen しておく（子は起動直後に connect する）。
    // 置き場は `.metaphor/` ではなく短い一時ディレクトリ（`sun_path` の上限と、同期フォルダを
    // 汚さないため。契約点 2）。
    guard let socketPath = ViewerSocketPath.make() else {
        throw CLIError("ビューアの socket パスが長すぎます（一時ディレクトリのパスが \(ViewerSocketPath.maximumLength) byte を超えています）", exitCode: 2)
    }
    let listener = try FrameIPCListener(path: socketPath)

    // Probe（既定 ON、--no-probe で OFF）を有効にすると、子が `.metaphor/probe/` に
    // フレーム+状態を書けるようになり、`metaphor mcp` がこのセッションへアタッチして
    // 観測できる（共有セッション）。人間はビューア窓で見つつ、AI は MCP で観測する。
    var childEnvironment = [
        "METAPHOR_VIEWER": "1",
        "METAPHOR_VIEWER_SOCKET": socketPath,
    ]
    // Syphon 名は `--syphon-name` で明示されたときだけ渡す（MadMapper 等への外部出力の要求。
    // 読むのは metaphor-syphon の provider）。既定では渡さない — ビューアへの転送には不要で、
    // provider 未リンクのスケッチで毎回診断が出るのを避ける。
    if let requestedSyphonName {
        childEnvironment["METAPHOR_SYPHON_NAME"] = requestedSyphonName
    }
    if probeEnabled || metricsEnabled {
        // --metrics はメトリクスの供給元として Probe を必要とする。--no-probe
        // 併用時も注入するが、shareSession（MCP アタッチ可否）は probeEnabled に従う。
        childEnvironment["METAPHOR_PROBE"] = "1"
    }
    // `--fps <n>` 指定時はレンダー FPS を子へ渡す（CONTRACT.md 契約点 2）。
    if let fps {
        childEnvironment["METAPHOR_FPS"] = String(fps)
    }
    // `.metaphor/` の基準ディレクトリを**解決済みの絶対パスで**子へ渡す（契約点 2）。
    // 子の cwd に依存せず producer と consumer が同じ場所を見るようにするため
    // （`.app` から起動すると cwd が `/` になる。metaphor#688 / #133）。
    childEnvironment["METAPHOR_STATE_DIR"] = MetaphorStateDirectory.base(for: directory).path

    let session = WatchSession(
        directory: directory,
        swiftArguments: swiftArguments,
        console: console,
        processRunner: FoundationProcessRunner(),
        launcher: FoundationProcessLauncher(),
        watcher: FSEventsFileWatcher(directory: directory),
        extraEnvironment: childEnvironment,
        shareSession: probeEnabled
    )

    // --metrics: 初回ビルド・起動が終わるまでは「応答待ち」表示になるだけなので、
    // アプリ起動前に開始してよい。
    let reporter: MetricsReporter? = metricsEnabled
        ? MetricsReporter(sketchDirectory: directory, interval: metricsInterval)
        : nil
    reporter?.start()

    // ウィンドウ/MTKView は applicationDidFinishLaunching の中で作る（CLI ツールから
    // GUI を使う場合の正準パターン。アプリ起動前に窓を作ると WindowServer が Metal
    // レイヤーを合成せず中身が黒くなることがある）。
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ViewerWatchDelegate(
        listener: listener,
        title: "metaphor watch — \(directory.lastPathComponent)",
        directory: directory,
        session: session,
        console: console,
        reporter: reporter
    )
    app.delegate = delegate

    installViewerSignalHandlers(session: session, listener: listener, reporter: reporter, console: console)
    app.run()
}

/// ライブビューア + watch supervisor を束ねるアプリデリゲート。
private final class ViewerWatchDelegate: NSObject, NSApplicationDelegate {
    private let listener: FrameIPCListener
    private let title: String
    private let directory: URL
    private let session: WatchSession
    private let console: any Console
    private let reporter: MetricsReporter?
    private var viewer: ViewerWindow?
    private var source: FrameIPCSource?
    /// 子の起動ごとに +1。`hello` 待ちタイマーが古い起動のものでないことを確かめる。
    private var launchSerial = 0

    init(
        listener: FrameIPCListener,
        title: String,
        directory: URL,
        session: WatchSession,
        console: any Console,
        reporter: MetricsReporter?
    ) {
        self.listener = listener
        self.title = title
        self.directory = directory
        self.session = session
        self.console = console
        self.reporter = reporter
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリ完全起動後にウィンドウ/MTKView を生成して表示。フレームの供給元（frame IPC）
        // と窓は同じ Metal device を共有させる（供給元の texture を窓がサンプルするため）。
        guard let device = MTLCreateSystemDefaultDevice() else {
            console.writeError("error: Metal device を取得できません（ビューア窓を作成できません）")
            NSApp.terminate(nil)
            return
        }
        let source = FrameIPCSource(listener: listener, device: device)
        guard let viewer = ViewerWindow(source: source, device: device, title: title) else {
            console.writeError("error: ビューア窓を作成できませんでした")
            NSApp.terminate(nil)
            return
        }
        self.source = source
        self.viewer = viewer

        // ビューア上のマウス/キー入力を、動作中の子スケッチの stdin へ転送する。
        viewer.onInput = { [weak session] line in
            session?.forwardInput(line)
        }

        // 子の（再）起動時に、ビューアの供給元を新しい世代（新しい子の接続）へ切り替えさせ、
        // 状態を「起動・フレーム待ち」へ進める。コールバックはバックグラウンドキューから
        // 来るのでメインへホップ。`hello` が一定時間来ず子が生きていれば、スケッチの metaphor が
        // frame IPC を知らない（古い）と判断して案内を出す。
        session.onChildLaunched = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launchSerial += 1
                let serial = self.launchSerial
                viewer.notifyChildRelaunched()
                viewer.setState(.launching)
                DispatchQueue.main.asyncAfter(deadline: .now() + FrameIPCSource.helloTimeout) { [weak self] in
                    self?.checkHelloTimeout(serial: serial)
                }
            }
        }

        // ビルド開始/終了を窓のローディング表示へ反映する（黒い窓の解消・失敗の可視化）。
        session.onBuildWillStart = { [weak viewer] _ in
            DispatchQueue.main.async { viewer?.setState(.building) }
        }
        session.onBuildFinished = { [weak viewer] outcome in
            guard !outcome.succeeded else { return }  // 成功時は続く onChildLaunched に任せる
            let message = Self.firstErrorLine(outcome.output)
            DispatchQueue.main.async { viewer?.setState(.buildFailed(message: message)) }
        }

        // 現世代の接続が閉じた = 子が終了した。リロード中（`.building`）の EOF は旧子を
        // 止めた通常経路なので、起動後〜描画中に閉じたときだけ「終了」と見せる。
        source.onDisconnected = { [weak self] in
            guard let self, let viewer = self.viewer else { return }
            switch viewer.currentState {
            case .launching, .rendering, .unsupportedLibrary:
                viewer.setState(.childExited)
            default:
                break
            }
        }

        viewer.show()

        // 起動前に分かる「本体が古い」: Package.resolved の版が frame IPC 以前なら、
        // ビルドを待たずに案内する（ビルド中のオーバーレイより優先して見せる）。
        if case .resolved(let version) = EnvironmentVersions.resolve(in: directory).library,
           let resolved = SemanticVersion(version),
           let minimum = SemanticVersion(BuildInfo.minimumMetaphorVersionForViewer),
           resolved < minimum {
            console.writeError(
                "[viewer] スケッチの metaphor \(version) はビューアへのフレーム転送に対応していません"
                + "（\(BuildInfo.minimumMetaphorVersionForViewer) 以上が必要）。Package.swift の版を上げて再ビルドしてください"
            )
        }

        // 初回ビルド+起動と監視はバックグラウンドで（UI を止めない）。
        let session = self.session
        let console = self.console
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try session.start()
            } catch {
                console.writeError("[watch] \(error)")
            }
        }
    }

    /// 子の起動から `helloTimeout` 経っても `hello` が来ていなければ、子が生きている限り
    /// 「本体が古い」と判断して案内する（子が既に死んでいれば `onDisconnected` が扱う）。
    private func checkHelloTimeout(serial: Int) {
        guard serial == launchSerial, let source, let viewer,
              !source.hasReceivedHello, session.isChildRunning else { return }
        if case .launching = viewer.currentState {
            viewer.setState(.unsupportedLibrary(required: BuildInfo.minimumMetaphorVersionForViewer))
            console.writeError(
                "[viewer] 子スケッチは動いていますが \(Int(FrameIPCSource.helloTimeout)) 秒たっても接続してきません。"
                + "スケッチの metaphor が \(BuildInfo.minimumMetaphorVersionForViewer) 未満だとビューアへフレームを送れません"
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        reporter?.stop()
        session.stop()
        listener.stop()
    }

    /// ビルド出力からエラー要約の 1 行を取り出す。`error:` を含む最初の行を優先し、
    /// 無ければ最後の非空行。出力が空（`--no-probe` 等で未捕捉）なら nil。
    static func firstErrorLine(_ output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first(where: { $0.contains("error:") }) ?? lines.last
    }
}

/// SIGINT/SIGTERM で子スケッチを止め、socket を片付けてからプロセス終了する。
private func installViewerSignalHandlers(
    session: WatchSession,
    listener: FrameIPCListener,
    reporter: MetricsReporter?,
    console: any Console
) {
    let install: (Int32) -> Void = { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            // 先にステータスライン行を確定させ、停止ログと混ざらないようにする。
            reporter?.stop()
            console.write("\n[watch] 停止します…")
            session.stop()
            listener.stop()
            Foundation.exit(0)
        }
        source.resume()
        retainedViewerSignalSources.append(source)
    }
    install(SIGINT)
    install(SIGTERM)
}

/// シグナルソースをプロセス寿命まで保持する。
private nonisolated(unsafe) var retainedViewerSignalSources: [DispatchSourceSignal] = []
