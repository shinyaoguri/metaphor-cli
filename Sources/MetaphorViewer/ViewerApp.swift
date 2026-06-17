import AppKit

/// 名前付き Syphon サーバーに接続するライブビューアを単体で起動する。
///
/// `NSApplication` を立ち上げてウィンドウを表示し、ウィンドウが閉じられるまで実行する。
/// `metaphor watch` のビューア統合（後続フェーズ）でも、この窓表示部分を再利用する。
public func runViewer(serverName: String, title: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    guard let viewer = ViewerWindow(serverName: serverName, title: title) else {
        FileHandle.standardError.write("failed to create viewer window\n".data(using: .utf8)!)
        exit(1)
    }

    let delegate = ViewerAppDelegate(viewer: viewer)
    app.delegate = delegate
    app.run()
}

private final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    private let viewer: ViewerWindow

    init(viewer: ViewerWindow) {
        self.viewer = viewer
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
