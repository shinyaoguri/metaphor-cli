import AppKit
import Darwin
import Foundation
import MetaphorCLICore

/// `metaphor watch --viewer`: 常設のライブビューア窓を保ちつつ、ソース変更で
/// 子スケッチ（ヘッドレス）だけを差し替える。
///
/// 子は `METAPHOR_VIEWER=1` + `METAPHOR_SYPHON_NAME=<name>` で起動し、ビューアは
/// その名前の Syphon サーバーに接続する。再ビルド時は子だけを止めて起動し直し、
/// ビューア窓はそのまま（直前フレームを表示し続ける）。
public func runViewerWatch(
    directory: URL,
    swiftArguments: [String],
    console: any Console
) throws {
    let package = directory.appendingPathComponent("Package.swift")
    guard FileManager.default.fileExists(atPath: package.path) else {
        throw CLIError(
            "Package.swift が見つかりません (\(directory.path))。スケッチのディレクトリで実行してください。",
            exitCode: 2
        )
    }

    // どのビルドが動いているか毎回表示（古いインストールの取り違え防止）。
    console.write("[viewer] \(BuildInfo.fullIdentifier)")

    // このプロセス固有の Syphon 名（同一マシンで複数 watch しても衝突しない）。
    let syphonName = "metaphor-watch-\(ProcessInfo.processInfo.processIdentifier)"

    let session = WatchSession(
        directory: directory,
        swiftArguments: swiftArguments,
        console: console,
        processRunner: FoundationProcessRunner(),
        launcher: FoundationProcessLauncher(),
        watcher: PollingFileWatcher(directory: directory),
        extraEnvironment: [
            "METAPHOR_VIEWER": "1",
            "METAPHOR_SYPHON_NAME": syphonName,
        ]
    )

    // ウィンドウ/MTKView は applicationDidFinishLaunching の中で作る（CLI ツールから
    // GUI を使う場合の正準パターン。アプリ起動前に窓を作ると WindowServer が Metal
    // レイヤーを合成せず中身が黒くなることがある）。
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ViewerWatchDelegate(
        syphonName: syphonName,
        title: "metaphor watch — \(directory.lastPathComponent)",
        session: session,
        console: console
    )
    app.delegate = delegate

    installViewerSignalHandlers(session: session, console: console)
    app.run()
}

/// ライブビューア + watch supervisor を束ねるアプリデリゲート。
private final class ViewerWatchDelegate: NSObject, NSApplicationDelegate {
    private let syphonName: String
    private let title: String
    private let session: WatchSession
    private let console: any Console
    private var viewer: ViewerWindow?

    init(syphonName: String, title: String, session: WatchSession, console: any Console) {
        self.syphonName = syphonName
        self.title = title
        self.session = session
        self.console = console
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリ完全起動後にウィンドウ/MTKView を生成して表示。
        guard let viewer = ViewerWindow(serverName: syphonName, title: title) else {
            console.writeError("error: ビューア窓を作成できませんでした")
            NSApp.terminate(nil)
            return
        }
        self.viewer = viewer
        viewer.show()

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }
}

/// SIGINT/SIGTERM で子スケッチを止めてからプロセス終了する。
private func installViewerSignalHandlers(session: WatchSession, console: any Console) {
    let install: (Int32) -> Void = { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            console.write("\n[watch] 停止します…")
            session.stop()
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
