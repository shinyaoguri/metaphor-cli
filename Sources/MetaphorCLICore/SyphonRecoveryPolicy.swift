import Foundation

/// ``SyphonRecoveryPolicy/plan(now:candidates:clientIsValid:lastFrameAt:)`` が返す指示。
/// 呼び出し側はここに書かれた動作を**必ず実行する**（policy は実行された前提で状態を進める）。
public struct SyphonRecoveryPlan: Equatable {
    /// 張り替え先サーバーの UUID。nil なら張り替え無し（現状維持）。
    public var bindTo: String?
    /// 再アナウンス要求（`ServerAnnounceRequest`）をブロードキャストするか。
    public var requestAnnounce: Bool
    /// 待機が長引いている（＝利用者に「再接続を試行中」と見せるべき）か。
    public var isStalled: Bool

    public init(bindTo: String? = nil, requestAnnounce: Bool = false, isStalled: Bool = false) {
        self.bindTo = bindTo
        self.requestAnnounce = requestAnnounce
        self.isStalled = isStalled
    }
}

/// 名前付き Syphon サーバーへの接続・張り替えを、時計と候補 UUID 一覧だけで決める状態機械。
///
/// Syphon にも Metal にも依存しない純粋なロジックなので、単体テストで全分岐を検証できる
/// （実際の接続は ``SyphonFrameSource`` が担う）。
///
/// ## なぜ「待つだけ」では駄目なのか（Issue #139）
///
/// `SyphonServerDirectory` は announce / update / retire の**通知ベース**で、公開 API に
/// 再スキャン手段が無い。したがって announce 通知を一度取りこぼすと、そのプロセスは新しい
/// サーバーの存在に永久に気付けない。`watch` のホットリロードを繰り返すと実際にこれが起き、
/// ビューアが「新しいフレームを待機中…」のまま戻らなくなる。
///
/// そこでこの policy は、待つだけでなく
///
/// 1. 新サーバーが現れないまま ``announceDelay`` を過ぎたら、``announceInterval`` ごとに
///    **再アナウンス要求**を促す（生きているサーバーが応じて再アナウンスし、ディレクトリに載る）
/// 2. 張り替えた先が ``livenessTimeout`` の間フレームを 1 枚も寄越さなければ、その UUID を
///    **降格**して次の候補へ移る（死んだサーバー＝ゾンビを掴んだまま抜け出せなくなるのを防ぐ）
/// 3. ``stalledAfter`` を超えた待機を ``SyphonRecoveryPlan/isStalled`` で外に伝える（可視化）
///
/// を指示する。
public final class SyphonRecoveryPolicy {
    /// 新サーバーが現れないとき、再アナウンス要求を始めるまでの待ち時間。
    private let announceDelay: TimeInterval
    /// 再アナウンス要求の再送間隔。
    private let announceInterval: TimeInterval
    /// 張り替え後、フレームが 1 枚も来ないまま「死んでいる」と判断するまでの時間。
    private let livenessTimeout: TimeInterval
    /// この時間を超えて待機したら `isStalled` を立てる（UI 表示用）。
    private let stalledAfter: TimeInterval
    /// 降格した候補しか残っていないとき、降格を解除して再試行するまでの時間。
    private let demotionRetryAfter: TimeInterval

    /// 現在接続していると見なしている UUID。
    private var connectedUUID: String?
    /// `connectedUUID` へ張り替えた時刻（生存判定の起点）。
    private var boundAt: TimeInterval = 0

    /// 子スケッチの差し替え待ち。`true` の間は「直前とは別 UUID」の同名サーバーを探す。
    private var awaitingSwap = false
    /// 差し替え時に避けるべき UUID（＝再起動前の、もう死んでいるはずのサーバー）。
    private var swapFromUUID: String?

    /// 掴んでもフレームが来なかった UUID と、その降格時刻。
    private var demoted: [String: TimeInterval] = [:]

    /// 使える候補が無い状態が始まった時刻。
    private var waitingSince: TimeInterval?
    /// 直近で再アナウンス要求を出した時刻。
    private var lastAnnounceAt: TimeInterval?

    public init(
        announceDelay: TimeInterval = 1.5,
        announceInterval: TimeInterval = 1.0,
        // 掴んだ先の生存確認は、重いスケッチの初回フレームが遅れても誤検知しないよう
        // 再アナウンス要求（新サーバー待ちの主経路）より長めに取る。
        livenessTimeout: TimeInterval = 3.0,
        stalledAfter: TimeInterval = 3.0,
        demotionRetryAfter: TimeInterval = 5.0
    ) {
        self.announceDelay = announceDelay
        self.announceInterval = announceInterval
        self.livenessTimeout = livenessTimeout
        self.stalledAfter = stalledAfter
        self.demotionRetryAfter = demotionRetryAfter
    }

    /// 子スケッチが（再）起動したことを通知する。以降 ``plan(now:candidates:clientIsValid:lastFrameAt:)``
    /// は「直前とは別 UUID の候補」を探し、見つかるまでは現在の接続（＝直前の絵）を保つ。
    public func expectNewServer() {
        awaitingSwap = true
        swapFromUUID = connectedUUID
    }

    /// 毎フレーム呼ぶ。現在の状況から次に取るべき動作を返す。
    ///
    /// - Parameters:
    ///   - now: 単調増加する現在時刻（秒）。
    ///   - candidates: 接続先名に一致するサーバーの UUID 一覧（ディレクトリ順）。
    ///   - clientIsValid: 現在のクライアントが有効か（未接続なら false）。
    ///   - lastFrameAt: 現在の接続で最後にフレームを受け取った時刻（一度も来ていなければ nil）。
    ///     `now` と同じ時計であること。
    /// - Returns: 実行すべき動作。呼び出し側は `bindTo` / `requestAnnounce` を必ず実行する。
    public func plan(
        now: TimeInterval,
        candidates: [String],
        clientIsValid: Bool,
        lastFrameAt: TimeInterval?
    ) -> SyphonRecoveryPlan {
        // 0) ディレクトリから消えた UUID の降格記録は捨てる（降格リストを候補数以内に保つ）。
        //    消えたサーバーが再アナウンスで戻ってきたら、それは生きているので再試行してよい。
        demoted = demoted.filter { candidates.contains($0.key) }

        // 1) ゾンビ検出。張り替えてから livenessTimeout の間フレームが 1 枚も来ていない接続は
        //    死んだサーバーとみなし、降格して未接続へ戻す。一度でもフレームを受けた接続は
        //    対象外（`noLoop()` で publish が止まるスケッチを誤って切らないため）。
        if let connected = connectedUUID,
           !hasFrameSinceBind(lastFrameAt),
           now - boundAt >= livenessTimeout {
            demoted[connected] = now
            connectedUUID = nil
        }

        // 2) 通常の切断検出。差し替え待ちの間は旧クライアントの状態を見ない（現在の絵を保つ）。
        if connectedUUID != nil, !awaitingSwap, !clientIsValid {
            connectedUUID = nil
        }

        // 3) 張り替え先が要るか。差し替え待ち中は接続済みでも「別 UUID」を探し続ける。
        guard awaitingSwap || connectedUUID == nil else {
            waitingSince = nil
            return SyphonRecoveryPlan()
        }

        if let next = nextCandidate(now: now, candidates: candidates) {
            // 差し替えが成った時点で、直前の世代のサーバーは死んでいる（子が再起動した）。
            // ディレクトリに残っていても掴みに行かないよう降格しておく。
            if let previous = swapFromUUID {
                demoted[previous] = now
            }
            connectedUUID = next
            boundAt = now
            awaitingSwap = false
            swapFromUUID = nil
            waitingSince = nil
            demoted[next] = nil
            return SyphonRecoveryPlan(bindTo: next)
        }

        // 4) 使える候補が無い。待機を続けつつ、一定時間を過ぎたら再アナウンスを促す。
        let since = waitingSince ?? now
        waitingSince = since
        let waited = now - since

        var plan = SyphonRecoveryPlan(isStalled: waited >= stalledAfter)
        if waited >= announceDelay, now - (lastAnnounceAt ?? -.greatestFiniteMagnitude) >= announceInterval {
            plan.requestAnnounce = true
            lastAnnounceAt = now
        }
        return plan
    }

    // MARK: - Private

    /// 現在の接続で、張り替え後にフレームを受け取れているか。
    private func hasFrameSinceBind(_ lastFrameAt: TimeInterval?) -> Bool {
        guard let lastFrameAt else { return false }
        return lastFrameAt >= boundAt
    }

    /// 次に掴むべき候補。無ければ nil。
    ///
    /// 「差し替え前の UUID」と「降格中の UUID」を除いた先頭を選ぶ。降格中しか残っていない
    /// ときは、``demotionRetryAfter`` を過ぎたものから降格を解除して再試行する（起動が遅かった
    /// だけの生きたサーバーを永久に捨てないため）。
    private func nextCandidate(now: TimeInterval, candidates: [String]) -> String? {
        let avoid = awaitingSwap ? swapFromUUID : nil
        let usable = candidates.filter { $0 != avoid && $0 != connectedUUID }

        if let fresh = usable.first(where: { demoted[$0] == nil }) {
            return fresh
        }
        return usable.first { uuid in
            guard let demotedAt = demoted[uuid] else { return true }
            return now - demotedAt >= demotionRetryAfter
        }
    }
}
