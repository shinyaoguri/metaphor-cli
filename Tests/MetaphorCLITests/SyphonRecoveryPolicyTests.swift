import Foundation
@testable import MetaphorCLICore
import XCTest

/// ``SyphonRecoveryPolicy`` の分岐を、時計を注入して検証する（Issue #139）。
///
/// 実際の Syphon は絡まない。「候補 UUID の一覧・クライアントの有効性・最後にフレームを
/// 受け取った時刻」から、張り替え／再アナウンス要求／可視化フラグが正しく出るかだけを見る。
final class SyphonRecoveryPolicyTests: XCTestCase {

    private func makePolicy(
        announceDelay: TimeInterval = 1.5,
        announceInterval: TimeInterval = 1.0,
        livenessTimeout: TimeInterval = 2.0,
        stalledAfter: TimeInterval = 3.0,
        demotionRetryAfter: TimeInterval = 5.0
    ) -> SyphonRecoveryPolicy {
        SyphonRecoveryPolicy(
            announceDelay: announceDelay,
            announceInterval: announceInterval,
            livenessTimeout: livenessTimeout,
            stalledAfter: stalledAfter,
            demotionRetryAfter: demotionRetryAfter
        )
    }

    /// 接続済み・フレーム受信中まで進めた policy を作る（多くのテストの出発点）。
    private func connected(
        _ policy: SyphonRecoveryPolicy,
        to uuid: String,
        at now: TimeInterval
    ) {
        let plan = policy.plan(now: now, candidates: [uuid], clientIsValid: false, lastFrameAt: nil)
        XCTAssertEqual(plan.bindTo, uuid, "最初のサーバーには即座に接続するはず")
    }

    // MARK: - 通常の接続・張り替え

    func testBindsToFirstServerWhenItAppears() {
        let policy = makePolicy()

        // まだ誰も publish していない: 張り替え先は無い。
        let empty = policy.plan(now: 0, candidates: [], clientIsValid: false, lastFrameAt: nil)
        XCTAssertNil(empty.bindTo)

        // 現れたら掴む。
        let found = policy.plan(now: 0.5, candidates: ["a"], clientIsValid: false, lastFrameAt: nil)
        XCTAssertEqual(found.bindTo, "a")
    }

    func testSwapsToNewUUIDAfterReload() {
        let policy = makePolicy()
        connected(policy, to: "old", at: 0)
        _ = policy.plan(now: 0.1, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)

        policy.expectNewServer()

        // 旧サーバーしか見えない間は張り替えない（直前の絵を保つ）。
        let waiting = policy.plan(now: 0.2, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertNil(waiting.bindTo)

        // 別 UUID が現れたら張り替える。
        let swapped = policy.plan(now: 0.3, candidates: ["old", "new"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertEqual(swapped.bindTo, "new")
    }

    func testRebindsWhenClientBecomesInvalid() {
        let policy = makePolicy()
        connected(policy, to: "a", at: 0)
        _ = policy.plan(now: 0.1, candidates: ["a"], clientIsValid: true, lastFrameAt: 0.1)

        // isValid が落ちたら、同じ名前で見えているサーバーへ繋ぎ直す。
        let plan = policy.plan(now: 0.2, candidates: ["a"], clientIsValid: false, lastFrameAt: 0.1)
        XCTAssertEqual(plan.bindTo, "a")
    }

    // MARK: - 再アナウンス要求（提案 1）

    func testRequestsAnnounceOnlyAfterDelayAndThenAtInterval() {
        let policy = makePolicy(announceDelay: 1.5, announceInterval: 1.0)
        connected(policy, to: "old", at: 0)
        _ = policy.plan(now: 0.1, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        policy.expectNewServer()

        // 待機時間は「張り替え先が無いと最初に気付いた poll」から数える（実機では 60fps で
        // 回るのでリロード直後）。
        _ = policy.plan(now: 0.15, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)

        // 新サーバーが現れないまま待つ。announceDelay までは要求しない。
        let early = policy.plan(now: 1.0, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertFalse(early.requestAnnounce)

        // 超えたら要求する。
        let first = policy.plan(now: 1.8, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertTrue(first.requestAnnounce)

        // 間隔内は再送しない（60fps ぶんの連打を防ぐ）。
        let tooSoon = policy.plan(now: 2.4, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertFalse(tooSoon.requestAnnounce)

        // 間隔を空ければまた要求する。
        let retry = policy.plan(now: 2.9, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertTrue(retry.requestAnnounce)
    }

    func testRequestsAnnounceWhenNoServerEverAppears() {
        // 初回起動でも（子の announce を取りこぼしていれば）要求で救えるので出す。
        let policy = makePolicy(announceDelay: 1.5)
        XCTAssertFalse(policy.plan(now: 0, candidates: [], clientIsValid: false, lastFrameAt: nil).requestAnnounce)
        XCTAssertTrue(policy.plan(now: 2.0, candidates: [], clientIsValid: false, lastFrameAt: nil).requestAnnounce)
    }

    // MARK: - 可視化（提案 3）

    func testStalledFlagRaisesAfterThresholdAndClearsOnSwap() {
        let policy = makePolicy(stalledAfter: 3.0)
        connected(policy, to: "old", at: 0)
        _ = policy.plan(now: 0.1, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)
        policy.expectNewServer()
        _ = policy.plan(now: 0.15, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1)

        XCTAssertFalse(policy.plan(now: 2.9, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1).isStalled)
        XCTAssertTrue(policy.plan(now: 3.2, candidates: ["old"], clientIsValid: true, lastFrameAt: 0.1).isStalled)

        // 張り替えが成れば表示は元に戻る。
        let swapped = policy.plan(now: 3.3, candidates: ["old", "new"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertEqual(swapped.bindTo, "new")
        XCTAssertFalse(swapped.isStalled)
    }

    // MARK: - 張り替え先の生存確認（提案 2）

    func testMovesOnWhenBoundServerNeverDeliversFrame() {
        let policy = makePolicy(livenessTimeout: 2.0)
        // ゾンビ（死んだサーバー）を掴んでしまう。
        let first = policy.plan(now: 0, candidates: ["zombie", "live"], clientIsValid: false, lastFrameAt: nil)
        XCTAssertEqual(first.bindTo, "zombie")

        // isValid はすぐ false にならないので、フレームが来ないことで見切る。
        XCTAssertNil(policy.plan(now: 1.0, candidates: ["zombie", "live"], clientIsValid: true, lastFrameAt: nil).bindTo)

        let recovered = policy.plan(now: 2.1, candidates: ["zombie", "live"], clientIsValid: true, lastFrameAt: nil)
        XCTAssertEqual(recovered.bindTo, "live", "フレームを寄越さない候補は降格して次へ移るはず")
    }

    func testKeepsQuietServerThatAlreadyDeliveredAFrame() {
        // `noLoop()` のスケッチは 1 枚描いたあと publish が止まる。フレーム途絶を理由に
        // 切ってしまうと、絵が出ているのに再接続を繰り返すことになる。
        let policy = makePolicy(livenessTimeout: 2.0)
        let bind = policy.plan(now: 0, candidates: ["quiet"], clientIsValid: false, lastFrameAt: nil)
        XCTAssertEqual(bind.bindTo, "quiet")

        // 0.1 秒に 1 枚だけ受け取り、以後 30 秒沈黙。その間ずっと（実機と同じく毎フレーム）
        // 判定しても、掴み直しも再アナウンス要求も再接続表示も起きてはならない。
        for step in 1...600 {
            let now = Double(step) * 0.05
            let plan = policy.plan(now: now, candidates: ["quiet"], clientIsValid: true, lastFrameAt: 0.1)
            XCTAssertNil(plan.bindTo, "t=\(now) で掴み直している")
            XCTAssertFalse(plan.requestAnnounce, "t=\(now) で再アナウンスを要求している")
            XCTAssertFalse(plan.isStalled, "t=\(now) で再接続表示になっている")
        }
    }

    func testRetriesDemotedCandidateWhenItIsTheOnlyOneLeft() {
        // 降格した候補しか無いなら、起動が遅かっただけの可能性を残して再試行する。
        let policy = makePolicy(livenessTimeout: 2.0, demotionRetryAfter: 5.0)
        XCTAssertEqual(policy.plan(now: 0, candidates: ["slow"], clientIsValid: false, lastFrameAt: nil).bindTo, "slow")

        // フレームが来ないまま降格。
        XCTAssertNil(policy.plan(now: 2.1, candidates: ["slow"], clientIsValid: true, lastFrameAt: nil).bindTo)
        XCTAssertNil(policy.plan(now: 5.0, candidates: ["slow"], clientIsValid: false, lastFrameAt: nil).bindTo)

        // 猶予を過ぎたら掴み直す。
        XCTAssertEqual(
            policy.plan(now: 7.2, candidates: ["slow"], clientIsValid: false, lastFrameAt: nil).bindTo,
            "slow"
        )
    }

    func testDoesNotFallBackToThePreviousGenerationServer() {
        // リロード後に旧サーバーがディレクトリに残っていても、掴み直さない
        // （retire 通知が飛ばずゾンビが残るケース。metaphor#715）。
        let policy = makePolicy(livenessTimeout: 2.0)
        connected(policy, to: "gen1", at: 0)
        _ = policy.plan(now: 0.1, candidates: ["gen1"], clientIsValid: true, lastFrameAt: 0.1)

        policy.expectNewServer()
        XCTAssertEqual(
            policy.plan(now: 0.3, candidates: ["gen1", "gen2"], clientIsValid: true, lastFrameAt: 0.1).bindTo,
            "gen2"
        )

        // 新サーバーもフレームを寄越さない場合でも、旧世代へは戻らない。
        let afterTimeout = policy.plan(now: 2.5, candidates: ["gen1", "gen2"], clientIsValid: true, lastFrameAt: 0.1)
        XCTAssertNil(afterTimeout.bindTo)
    }
}
