import Foundation
import Metal
import MetaphorCLICore
import QuartzCore
import Syphon

/// 名前付き Syphon サーバーに接続し、最新フレームの `MTLTexture` を提供する
/// ``FrameSource`` 実装。
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
/// ``expectNewGeneration()`` を呼び、次に現れる「直前とは別 UUID の同名サーバー」へ
/// 確実に張り替える。`noLoop()` 中（publish が止まる）でも、フレーム途絶ではなく
/// **UUID の変化**で判定するため誤発火しない。
///
/// ## 自力復帰（Issue #139）
///
/// `SyphonServerDirectory` は通知ベースで再スキャン API を持たないため、announce 通知を
/// 一度取りこぼすと新サーバーの存在に永久に気付けない。判断は ``SyphonRecoveryPolicy`` に
/// 任せ、この型はその指示（張り替え・再アナウンス要求）を実行するだけにしている。
/// 復帰の材料になるのは次の 2 つ:
///
/// - **再アナウンス要求**: 新サーバーが現れないまま一定時間が過ぎたら
///   `ServerAnnounceRequest` をブロードキャストし、生きているサーバーに再アナウンスさせる
/// - **張り替え先の生存確認**: 掴んだ先からフレームが来なければ policy が降格し、次の候補へ移る
///   （そのための「最後にフレームを受け取った時刻」をこの型が記録する）
public final class SyphonFrameSource: FrameSource {
    private let device: MTLDevice
    private let serverName: String
    private var client: SyphonMetalClient?

    /// 接続・張り替え・再アナウンス要求の判断（純粋ロジック。時計と候補一覧だけで決まる）。
    private let policy: SyphonRecoveryPolicy

    /// 現在接続しているサーバーの記述（UUID → 記述の対応付けに使う）。
    private var connectedUUID: String?

    /// 現在の接続で最後にフレームを受け取った時刻（``CACurrentMediaTime()``）と、
    /// 張り替えごとに +1 する世代番号。世代は、旧クライアントから遅れて届くコールバックを
    /// 「新しい接続でフレームを受け取れている」と誤判定しないために使う。
    /// どちらも Syphon の別スレッドとメインスレッドの両方から触るのでロックで守る。
    private var lastFrameAt: TimeInterval?
    private var generation: UInt64 = 0
    private let frameLock = NSLock()

    /// 待機が長引いているか（``status`` の `.helloTimedOut` の材料。policy の判断）。
    private var isStalled = false

    /// 現在の接続で最後に受け取ったフレームのピクセルサイズ（`.connected` の材料）。
    /// 張り替えのたびに nil へ戻す。メインスレッドからしか触らない。
    private var lastFrameSize: (width: Int, height: Int)?

    /// 有効な接続が無い状態が始まった時刻（`.waitingForConnection(since:)` の材料）。
    /// 生成直後から「待ち」なので初期値は生成時刻。
    private var waitingSince: TimeInterval? = CACurrentMediaTime()

    /// ``stop()`` 済みか。
    private var isStopped = false

    /// 新フレーム到着時に呼ばれる（Syphon の別スレッドから呼ばれうる）。
    public var onFrame: (() -> Void)?

    /// 接続状態を ``FrameSourceStatus`` へ写す。frame IPC（metaphor#792）の語彙に
    /// Syphon の状況を対応付けている:
    ///
    /// - `.helloTimedOut`: 新サーバーが現れないまま待機が長引き、再アナウンス要求で
    ///   復帰を試みている（Syphon では announce が hello に相当する）
    /// - `.connected`: クライアントが有効で、この接続でフレームを受け取れている
    /// - `.waitingForConnection`: 上記以外の待ち（未接続、張り替え直後でフレーム未着）
    /// - `.disconnected`: ``stop()`` 後
    public var status: FrameSourceStatus {
        if isStopped {
            return .disconnected
        }
        if isStalled {
            return .helloTimedOut
        }
        if client?.isValid == true, let size = lastFrameSize {
            return .connected(width: size.width, height: size.height)
        }
        return .waitingForConnection(since: waitingSince ?? CACurrentMediaTime())
    }

    public init(
        device: MTLDevice,
        serverName: String,
        policy: SyphonRecoveryPolicy = SyphonRecoveryPolicy()
    ) {
        self.device = device
        self.serverName = serverName
        self.policy = policy
    }

    /// 子スケッチが（再）起動したことを親から通知する。次に現れる「直前とは別 UUID の
    /// 同名サーバー」へ ``poll()`` で張り替える。新サーバーが現れるまでは現在の表示を保つ。
    public func expectNewGeneration() {
        policy.expectNewServer()
    }

    /// 毎フレーム呼ぶ。接続・差し替え検知・復帰動作をまとめて行う。
    public func poll() {
        let now = CACurrentMediaTime()
        // 「有効な接続が無い」期間の始まりを覚えておく（status の since 用）。
        if client?.isValid == true {
            waitingSince = nil
        } else if waitingSince == nil {
            waitingSince = now
        }
        let servers = sameNameServers()
        // UUID の無い記述は同一性を追えないので候補から外す（Syphon は通常必ず付ける）。
        var byUUID: [String: [String: Any]] = [:]
        var order: [String] = []
        for server in servers {
            guard let uuid = uuid(of: server), byUUID[uuid] == nil else { continue }
            byUUID[uuid] = server
            order.append(uuid)
        }

        let plan = policy.plan(
            now: now,
            candidates: order,
            clientIsValid: client?.isValid == true,
            lastFrameAt: currentLastFrameAt()
        )

        if let target = plan.bindTo, let description = byUUID[target] {
            bind(to: description)
        }
        if plan.requestAnnounce {
            requestServerAnnounce()
        }
        isStalled = plan.isStalled
    }

    /// 最新フレームのテクスチャ（無ければ nil）。呼ぶたびに最新を取得する。
    public func currentTexture() -> MTLTexture? {
        let texture = client?.newFrameImage()
        // 生存確認の材料。コールバックが来ない実装/経路でも、絵が取れているなら生きている。
        // （張り替えと同じメインスレッドから呼ばれるので世代の取り違えは起きない）
        if let texture {
            noteFrame()
            lastFrameSize = (texture.width, texture.height)
        }
        return texture
    }

    public func stop() {
        client?.stop()
        client = nil
        connectedUUID = nil
        lastFrameSize = nil
        isStopped = true
    }

    // MARK: - Private

    /// 指定のサーバー記述へ接続し直す（既存クライアントは破棄）。
    private func bind(to description: [String: Any]) {
        client?.stop()
        connectedUUID = uuid(of: description)
        lastFrameSize = nil  // 新しい接続のサイズは最初のフレームで分かる。
        frameLock.lock()
        generation &+= 1
        let generation = self.generation
        lastFrameAt = nil  // 生存判定は張り替えのたびにやり直す。
        frameLock.unlock()
        client = SyphonMetalClient(
            serverDescription: description,
            device: device,
            options: nil,
            newFrameHandler: { [weak self] _ in
                self?.noteFrame(generation: generation)
                self?.onFrame?()
            }
        )
    }

    /// フレームを受け取ったことを記録する。旧世代（張り替え前のクライアント）からの
    /// 呼び出しは無視する。`generation` 省略時は現在の世代として記録する。
    private func noteFrame(generation: UInt64? = nil) {
        frameLock.lock()
        defer { frameLock.unlock() }
        if let generation, generation != self.generation { return }
        lastFrameAt = CACurrentMediaTime()
    }

    private func currentLastFrameAt() -> TimeInterval? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastFrameAt
    }

    /// 生きている Syphon サーバーに再アナウンスを促す。
    ///
    /// `SyphonServerDirectory` は初期化時にこの要求をブロードキャストし、各サーバーが
    /// announce で応じることでディレクトリが埋まる。通知を取りこぼして自分のディレクトリに
    /// エントリが載っていないとき、これを自分から投げれば載せ直せる（Issue #139 の復帰経路）。
    ///
    /// 通知名は Syphon が**プロセス間**でやり取りする内部定数（`SyphonPrivate.h` の
    /// `SyphonServerAnnounceRequest`）で、公開ヘッダには無い。公開されている
    /// `NSNotification.Name.SyphonServerAnnounce` はプロセス内通知用の別物なので、
    /// そこからは組み立てられず、文字列で持つしかない（Syphon 3.x で不変）。
    /// 万一 Syphon 側で名前が変われば、誰も購読しない通知が飛ぶだけで無害に劣化する。
    private func requestServerAnnounce() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("info.v002.Syphon.ServerAnnounceRequest"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
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
