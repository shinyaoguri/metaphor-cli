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

    // MARK: - canvasCoordinate (view → canvas inverse transform)

    func testCanvasCoordinateExactAspectMapsLinearly() {
        // 余白なし（同アスペクト）: ビュー中心 → キャンバス中心。
        let c = canvasCoordinate(
            viewX: 800, viewYTopLeft: 450,
            viewWidth: 1600, viewHeight: 900,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertEqual(c.x, 640, accuracy: 0.001)
        XCTAssertEqual(c.y, 360, accuracy: 0.001)
    }

    func testCanvasCoordinateTopLeftCorner() {
        let c = canvasCoordinate(
            viewX: 0, viewYTopLeft: 0,
            viewWidth: 1600, viewHeight: 900,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertEqual(c.x, 0, accuracy: 0.001)
        XCTAssertEqual(c.y, 0, accuracy: 0.001)
    }

    func testCanvasCoordinateAccountsForPillarbox() {
        // 2:1 ビューに 16:9 を内接 → 左右に帯。内接矩形の中心はキャンバス中心へ、
        // 内接矩形の左端はキャンバス x=0。
        let fitX = (2000 - 1000.0 * 1280.0 / 720.0) / 2  // 内接矩形の左端
        let center = canvasCoordinate(
            viewX: 1000, viewYTopLeft: 500,
            viewWidth: 2000, viewHeight: 1000,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertEqual(center.x, 640, accuracy: 0.001)
        XCTAssertEqual(center.y, 360, accuracy: 0.001)

        // 内接矩形の左端はキャンバス x=0。
        let leftEdge = canvasCoordinate(
            viewX: fitX, viewYTopLeft: 500,
            viewWidth: 2000, viewHeight: 1000,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertEqual(leftEdge.x, 0, accuracy: 0.001)

        // 帯の中（内接矩形より左）はクランプせず負値（ネイティブ窓と同じ）。
        let inBar = canvasCoordinate(
            viewX: fitX / 2, viewYTopLeft: 500,
            viewWidth: 2000, viewHeight: 1000,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertLessThan(inBar.x, 0)
    }

    func testCanvasCoordinateDoesNotClampBeyondContent() {
        // ビュー右下を超える点 → キャンバス範囲外（>幅, >高さ）。ネイティブ窓と同じく頭打ちしない。
        let c = canvasCoordinate(
            viewX: 1600, viewYTopLeft: 900,
            viewWidth: 1600, viewHeight: 900,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertEqual(c.x, 1280, accuracy: 0.001)
        XCTAssertEqual(c.y, 720, accuracy: 0.001)

        let beyond = canvasCoordinate(
            viewX: 2000, viewYTopLeft: 1000,
            viewWidth: 1600, viewHeight: 900,
            contentWidth: 1280, contentHeight: 720
        )
        XCTAssertGreaterThan(beyond.x, 1280)
        XCTAssertGreaterThan(beyond.y, 720)
    }
}
