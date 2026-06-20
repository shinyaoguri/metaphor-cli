import Foundation
import Metal
import Syphon

/// 名前付き Syphon サーバーに接続し、最新フレームの `MTLTexture` を提供する。
///
/// metaphor のヘッドレスモード（`METAPHOR_VIEWER=1`）が `METAPHOR_SYPHON_NAME`
/// で publish するサーバーに、ビューアが接続するために使う。サーバーは子プロセスの
/// 起動タイミング次第で後から現れるため、見つかるまでポーリングで待つ。
///
/// ## 子プロセス差し替え（リロード）への対応
///
/// `watch` の再ビルドで子スケッチが再起動すると、**同名だが UUID の異なる**新しい
/// Syphon サーバーになる。このとき旧サーバーに張り付いたクライアントは（`isValid` が
/// すぐに false にならない場合があり）新フレームを受け取れず、ビューアが古い絵のまま
/// 固まる。これを避けるため、親（`WatchSession`）が子を起動し直したら
/// ``expectNewServer()`` を呼び、次に現れる「直前とは別 UUID の同名サーバー」へ
/// 確実に張り替える。`noLoop()` 中（publish が止まる）でも、フレーム途絶ではなく
/// **UUID の変化**で判定するため誤発火しない。
public final class SyphonFrameSource {
    private let device: MTLDevice
    private let serverName: String
    private var client: SyphonMetalClient?

    /// 現在接続しているサーバーの UUID。差し替え時に「別 UUID」を選ぶのに使う。
    private var connectedUUID: String?

    /// 子の差し替え待ち。`true` の間は、直前とは別 UUID の同名サーバーが現れたら張り替える。
    private var awaitingSwap = false
    /// 差し替え時に避けるべき UUID（＝再起動前の、もう死んでいるサーバー）。
    private var swapFromUUID: String?

    /// 新フレーム到着時に呼ばれる（Syphon の別スレッドから呼ばれうる）。
    public var onFrame: (() -> Void)?

    /// サーバーへ接続済みかつ有効かどうか。
    public var isConnected: Bool { client?.isValid == true }

    public init(device: MTLDevice, serverName: String) {
        self.device = device
        self.serverName = serverName
    }

    /// 子スケッチが（再）起動したことを親から通知する。次に現れる「直前とは別 UUID の
    /// 同名サーバー」へ ``poll()`` で張り替える。新サーバーが現れるまでは現在の表示を保つ。
    public func expectNewServer() {
        awaitingSwap = true
        swapFromUUID = connectedUUID
    }

    /// 毎フレーム呼ぶ。接続・差し替え検知をまとめて行う。
    public func poll() {
        if awaitingSwap {
            // 直前とは別 UUID の同名サーバー（＝再起動後の新しい子）が現れたら張り替える。
            // まだ無ければ現状維持（古いフレームを表示し続けたまま待つ）。
            if let description = sameNameServers().first(where: { uuid(of: $0) != swapFromUUID }) {
                bind(to: description)
                awaitingSwap = false
                swapFromUUID = nil
            }
            return
        }

        // 通常時: 未接続なら同名サーバーを探して接続。クライアントが無効化されたら張り替える。
        if let client {
            if !client.isValid, let description = sameNameServers().first {
                bind(to: description)
            }
        } else if let description = sameNameServers().first {
            bind(to: description)
        }
    }

    /// 最新フレームのテクスチャ（無ければ nil）。呼ぶたびに最新を取得する。
    public func currentTexture() -> MTLTexture? {
        client?.newFrameImage()
    }

    public func stop() {
        client?.stop()
        client = nil
        connectedUUID = nil
    }

    // MARK: - Private

    /// 指定のサーバー記述へ接続し直す（既存クライアントは破棄）。
    private func bind(to description: [String: Any]) {
        client?.stop()
        connectedUUID = uuid(of: description)
        client = SyphonMetalClient(
            serverDescription: description,
            device: device,
            options: nil,
            newFrameHandler: { [weak self] _ in
                self?.onFrame?()
            }
        )
    }

    /// `serverName` に**完全一致**するサーバー記述だけを返す。
    ///
    /// フォールバック（最初に見つかった任意のサーバー）は使わない。過去の実行で残った
    /// 死んだ Syphon サーバー（ゾンビ）への誤接続を防ぐため、全サーバーを走査して厳密一致のみ。
    private func sameNameServers() -> [[String: Any]] {
        SyphonServerDirectory.shared().servers.filter {
            ($0[SyphonServerDescriptionNameKey] as? String) == serverName
        }
    }

    private func uuid(of description: [String: Any]) -> String? {
        description[SyphonServerDescriptionUUIDKey] as? String
    }
}
