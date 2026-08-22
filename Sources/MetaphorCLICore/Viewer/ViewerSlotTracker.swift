import Foundation

/// 親（viewer）側の slot の状態機械。Metal にもソケットにも依存しない純粋ロジック。
///
/// 子は 3 枚の slot を回し、親が `release` を返すまでその slot へは書かない
/// （CONTRACT.md 契約点 5）。親が握ってよいのは**表示中の 1 枚 + まだ表示していない最新の
/// 1 枚**まで。それ以上受け取ったら古い方を追い越して即 release する（latest-wins）。
/// 表示中の slot は、表示が切り替わり、その slot をサンプルした GPU の command buffer が
/// すべて完了してから release する（完了前に release すると子が上書きして絵が裂ける）。
public struct ViewerSlotTracker: Equatable {
    /// 現在表示している slot。
    public private(set) var displayed: Int?
    /// 受信済みでまだ表示していない最新の slot。
    public private(set) var pending: Int?
    /// `frame` で受け取ってまだ `release` していない slot。
    public private(set) var held: Set<Int> = []
    /// slot ごとの未完了の GPU 読み（`gpuReadBegan` − `gpuReadEnded`）。
    private var inFlight: [Int: Int] = [:]

    public init() {}

    /// 子から `frame` が届いた。返り値は**今すぐ release すべき slot**（追い越された pending）。
    public mutating func frameArrived(slot: Int) -> [Int] {
        var releases: [Int] = []
        if let previous = pending, previous != slot {
            pending = nil
            releases += releasable(previous)
        }
        held.insert(slot)
        if slot == displayed {
            // 表示中の slot を子が書き直した（release 前に書くのは契約違反だが、壊れずに追従する）。
            pending = nil
        } else {
            pending = slot
        }
        return releases
    }

    /// 窓が描画の直前に呼ぶ。新しいフレームがあればそれを表示中にして返す（無ければ nil）。
    /// 返り値には、表示を外れた旧 slot のうち今すぐ release できるものも含む。
    public mutating func takeForDisplay() -> (slot: Int, releases: [Int])? {
        guard let next = pending else { return nil }
        pending = nil
        let previous = displayed
        displayed = next
        var releases: [Int] = []
        if let previous, previous != next {
            releases += releasable(previous)
        }
        return (next, releases)
    }

    /// slot をサンプルする command buffer を commit した。
    public mutating func gpuReadBegan(slot: Int) {
        inFlight[slot, default: 0] += 1
    }

    /// slot をサンプルした command buffer が完了した。返り値は release すべき slot。
    public mutating func gpuReadEnded(slot: Int) -> [Int] {
        let count = max(0, (inFlight[slot] ?? 0) - 1)
        inFlight[slot] = count == 0 ? nil : count
        return releasable(slot)
    }

    /// 世代が切り替わった（新しい子の world）。旧世代の slot は release 先が無いので忘れる。
    public mutating func reset() {
        displayed = nil
        pending = nil
        held = []
        inFlight = [:]
    }

    /// 親が握っている slot の数（表示中 + 未表示の最新 + GPU 完了待ち）。
    public var heldCount: Int { held.count }

    /// `slot` が「握っているが、表示中でも未表示の最新でもなく、GPU 読みも残っていない」なら
    /// held から外して返す（= release を 1 度だけ送る）。
    private mutating func releasable(_ slot: Int) -> [Int] {
        guard held.contains(slot), slot != displayed, slot != pending,
              (inFlight[slot] ?? 0) == 0 else { return [] }
        held.remove(slot)
        return [slot]
    }
}
