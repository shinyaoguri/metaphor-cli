import XCTest
@testable import MetaphorCLICore

/// 親（viewer）側の slot 状態機械。子は 3 slot を回し、親が握ってよいのは
/// 「表示中 + 未表示の最新」の 2 枚まで（CONTRACT.md 契約点 5）。
final class ViewerSlotTrackerTests: XCTestCase {
    func testLatestWinsReleasesTheOvertakenPendingSlotImmediately() {
        var tracker = ViewerSlotTracker()
        XCTAssertEqual(tracker.frameArrived(slot: 0), [], "first frame: nothing to release")
        XCTAssertEqual(tracker.pending, 0)
        // slot 0 を表示する前に slot 1 が来た → 0 は一度も表示されずに追い越される。
        XCTAssertEqual(tracker.frameArrived(slot: 1), [0])
        XCTAssertEqual(tracker.pending, 1)
        XCTAssertEqual(tracker.held, [1])
    }

    func testDisplayedSlotIsNotReleasedWhileItIsOnScreen() {
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        let taken = tracker.takeForDisplay()
        XCTAssertEqual(taken?.slot, 0)
        XCTAssertEqual(taken?.releases, [])
        XCTAssertEqual(tracker.displayed, 0)
        XCTAssertNil(tracker.takeForDisplay(), "no new frame: window keeps the displayed one")
        // 毎フレーム同じ slot をサンプルしても、表示中の間は release しない。
        tracker.gpuReadBegan(slot: 0)
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [])
        XCTAssertEqual(tracker.held, [0])
    }

    func testPreviousSlotIsReleasedOnceItsLastGPUReadCompletes() {
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        _ = tracker.takeForDisplay()
        tracker.gpuReadBegan(slot: 0)  // 表示中の slot 0 を読む command buffer が in-flight

        _ = tracker.frameArrived(slot: 1)
        let switched = tracker.takeForDisplay()
        XCTAssertEqual(switched?.slot, 1)
        XCTAssertEqual(switched?.releases, [], "slot 0 still has a GPU read in flight")
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [0], "released exactly when the read completes")
        XCTAssertEqual(tracker.held, [1])
    }

    func testPreviousSlotIsReleasedAtSwitchWhenNothingIsInFlight() {
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        _ = tracker.takeForDisplay()
        _ = tracker.frameArrived(slot: 1)
        XCTAssertEqual(tracker.takeForDisplay()?.releases, [0])
    }

    func testParentNeverHoldsMoreThanTwoSlots() {
        var tracker = ViewerSlotTracker()
        var maxHeld = 0
        // 子が 3 slot を順に回し、親は 2 フレームに 1 回しか描画しない（受信が表示より速い）。
        var next = 0
        for step in 0..<30 {
            _ = tracker.frameArrived(slot: next)
            next = (next + 1) % 3
            maxHeld = max(maxHeld, tracker.heldCount)
            if step % 2 == 1, let taken = tracker.takeForDisplay() {
                tracker.gpuReadBegan(slot: taken.slot)
                _ = tracker.gpuReadEnded(slot: taken.slot)
            }
            maxHeld = max(maxHeld, tracker.heldCount)
        }
        XCTAssertLessThanOrEqual(maxHeld, 2)
    }

    func testEachSlotIsReleasedAtMostOnce() {
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        _ = tracker.takeForDisplay()
        tracker.gpuReadBegan(slot: 0)
        tracker.gpuReadBegan(slot: 0)
        _ = tracker.frameArrived(slot: 1)
        _ = tracker.takeForDisplay()
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [], "one read still outstanding")
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [0])
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [], "a stray completion must not release again")
    }

    func testResetForgetsTheOldGeneration() {
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        _ = tracker.takeForDisplay()
        tracker.gpuReadBegan(slot: 0)
        tracker.reset()
        XCTAssertNil(tracker.displayed)
        XCTAssertEqual(tracker.held, [])
        XCTAssertEqual(tracker.gpuReadEnded(slot: 0), [], "old generation's slots have no release target")
        // 新世代は 0 から通常どおり。
        XCTAssertEqual(tracker.frameArrived(slot: 0), [])
        XCTAssertEqual(tracker.takeForDisplay()?.slot, 0)
    }

    func testRewritingTheDisplayedSlotDoesNotLeaveItPending() {
        // 契約違反（release 前に表示中 slot を書く）でも壊れずに追従する。
        var tracker = ViewerSlotTracker()
        _ = tracker.frameArrived(slot: 0)
        _ = tracker.takeForDisplay()
        XCTAssertEqual(tracker.frameArrived(slot: 0), [])
        XCTAssertNil(tracker.pending)
        XCTAssertEqual(tracker.displayed, 0)
    }
}
