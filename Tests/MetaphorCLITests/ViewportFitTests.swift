import Foundation
@testable import MetaphorCLICore
import XCTest

final class ViewportFitTests: XCTestCase {

    func testExactAspectFillsEntirely() {
        // 16:9 コンテンツを 16:9 ドローアブルへ → 全面、余白なし
        let fit = aspectFitRect(drawableWidth: 1600, drawableHeight: 900, contentWidth: 1280, contentHeight: 720)
        XCTAssertEqual(fit, FitRect(x: 0, y: 0, width: 1600, height: 900))
    }

    func testWiderDrawablePillarboxes() {
        // 16:9 コンテンツを 2:1（横長）ドローアブルへ → 左右に余白
        let fit = aspectFitRect(drawableWidth: 2000, drawableHeight: 1000, contentWidth: 1280, contentHeight: 720)
        // 高さ基準: w = 1000 * (1280/720) = 1777.78、x = (2000-1777.78)/2
        XCTAssertEqual(fit.height, 1000, accuracy: 0.001)
        XCTAssertEqual(fit.width, 1000.0 * 1280.0 / 720.0, accuracy: 0.001)
        XCTAssertEqual(fit.y, 0, accuracy: 0.001)
        XCTAssertEqual(fit.x, (2000 - 1000.0 * 1280.0 / 720.0) / 2, accuracy: 0.001)
    }

    func testTallerDrawableLetterboxes() {
        // 16:9 コンテンツを 1:1 ドローアブルへ → 上下に余白
        let fit = aspectFitRect(drawableWidth: 1000, drawableHeight: 1000, contentWidth: 1280, contentHeight: 720)
        XCTAssertEqual(fit.width, 1000, accuracy: 0.001)
        XCTAssertEqual(fit.height, 1000.0 * 720.0 / 1280.0, accuracy: 0.001)
        XCTAssertEqual(fit.x, 0, accuracy: 0.001)
        XCTAssertEqual(fit.y, (1000 - 1000.0 * 720.0 / 1280.0) / 2, accuracy: 0.001)
    }

    func testZeroSizeReturnsSafeRect() {
        let fit = aspectFitRect(drawableWidth: 0, drawableHeight: 0, contentWidth: 1280, contentHeight: 720)
        XCTAssertEqual(fit, FitRect(x: 0, y: 0, width: 0, height: 0))
    }
}
