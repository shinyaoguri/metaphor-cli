import Foundation
import Metal
import Syphon

/// 名前付き Syphon サーバーに接続し、最新フレームの `MTLTexture` を提供する。
///
/// metaphor のヘッドレスモード（`METAPHOR_VIEWER=1`）が `METAPHOR_SYPHON_NAME`
/// で publish するサーバーに、ビューアが接続するために使う。サーバーは子プロセスの
/// 起動タイミング次第で後から現れるため、見つかるまでポーリングで待つ。
public final class SyphonFrameSource {
    private let device: MTLDevice
    private let serverName: String
    private var client: SyphonMetalClient?

    /// 新フレーム到着時に呼ばれる（Syphon の別スレッドから呼ばれうる）。
    public var onFrame: (() -> Void)?

    /// サーバーへ接続済みかつ有効かどうか。子プロセス再起動でサーバーが retire すると
    /// `isValid` が false になるため、これを接続判定に使う。
    public var isConnected: Bool { client?.isValid == true }

    public init(device: MTLDevice, serverName: String) {
        self.device = device
        self.serverName = serverName
    }

    /// サーバーを探して接続する。既存クライアントが無効（サーバー retire）なら破棄して
    /// 同名の新サーバーに接続し直す。見つかれば `true`。
    @discardableResult
    public func connectIfAvailable() -> Bool {
        if let existing = client {
            if existing.isValid { return true }
            existing.stop()
            client = nil
        }
        guard let description = matchingServerDescription() else { return false }

        client = SyphonMetalClient(
            serverDescription: description,
            device: device,
            options: nil,
            newFrameHandler: { [weak self] _ in
                self?.onFrame?()
            }
        )
        return client?.isValid == true
    }

    /// 最新フレームのテクスチャ（無ければ nil）。呼ぶたびに最新を取得する。
    public func currentTexture() -> MTLTexture? {
        client?.newFrameImage()
    }

    public func stop() {
        client?.stop()
        client = nil
    }

    /// `serverName` に一致するサーバー記述を返す。
    private func matchingServerDescription() -> [String: Any]? {
        let directory = SyphonServerDirectory.shared()
        let matches = directory.servers(matchingName: serverName, appName: nil)
        // 名前一致を優先。無ければ最初のサーバー（名前未設定でも拾えるように）。
        for server in matches {
            if let name = server[SyphonServerDescriptionNameKey] as? String, name == serverName {
                return server
            }
        }
        return matches.first
    }
}
