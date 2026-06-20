import Foundation

/// レターボックス計算の結果（ピクセル座標の矩形）。
public struct FitRect: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// `contentWidth x contentHeight` のコンテンツを `drawable` 矩形にアスペクト比を保って
/// 内接させた矩形（レターボックス/ピラーボックス）を返す。
///
/// ビューアがキャンバスをウィンドウに表示する際、およびウィンドウ座標→キャンバス座標の
/// 逆変換（入力転送）の双方で使う純粋関数。
public func aspectFitRect(
    drawableWidth: Double,
    drawableHeight: Double,
    contentWidth: Int,
    contentHeight: Int
) -> FitRect {
    guard drawableWidth > 0, drawableHeight > 0, contentWidth > 0, contentHeight > 0 else {
        return FitRect(x: 0, y: 0, width: max(0, drawableWidth), height: max(0, drawableHeight))
    }
    let contentAspect = Double(contentWidth) / Double(contentHeight)
    let drawableAspect = drawableWidth / drawableHeight

    if drawableAspect > contentAspect {
        // ドローアブルが横長 → 左右をピラーボックス
        let w = drawableHeight * contentAspect
        return FitRect(x: (drawableWidth - w) / 2, y: 0, width: w, height: drawableHeight)
    } else {
        // 縦長 → 上下をレターボックス
        let h = drawableWidth / contentAspect
        return FitRect(x: 0, y: (drawableHeight - h) / 2, width: drawableWidth, height: h)
    }
}

/// ビュー上の点（**左上原点**）を、レターボックス表示されたキャンバスの座標へ逆変換する。
///
/// 入力転送（ビューア上のマウス位置 → 子スケッチのキャンバス座標）で使う純粋関数。
/// ``aspectFitRect`` でキャンバスが内接表示される矩形を求め、その中での相対位置を
/// キャンバス解像度にスケールする。レターボックスの帯に外れた点は範囲内へクランプする
/// （Processing と同様、マウスはキャンバス端で頭打ちになる）。
///
/// - Parameters:
///   - viewX: ビュー上の x（左上原点・ポイント単位。バッキングスケールは不要）。
///   - viewYTopLeft: ビュー上の y（**左上原点**。AppKit の左下原点からは呼び出し側で反転しておく）。
///   - viewWidth/viewHeight: ビューのサイズ（ポイント単位）。
///   - contentWidth/contentHeight: キャンバス（Syphon テクスチャ）の解像度。
/// - Returns: キャンバス座標 `(x, y)`（左上原点、`0...content` にクランプ済み）。
public func canvasCoordinate(
    viewX: Double,
    viewYTopLeft: Double,
    viewWidth: Double,
    viewHeight: Double,
    contentWidth: Int,
    contentHeight: Int
) -> (x: Double, y: Double) {
    let fit = aspectFitRect(
        drawableWidth: viewWidth, drawableHeight: viewHeight,
        contentWidth: contentWidth, contentHeight: contentHeight
    )
    guard fit.width > 0, fit.height > 0 else { return (0, 0) }
    let cx = (viewX - fit.x) / fit.width * Double(contentWidth)
    let cy = (viewYTopLeft - fit.y) / fit.height * Double(contentHeight)
    return (
        x: min(max(cx, 0), Double(contentWidth)),
        y: min(max(cy, 0), Double(contentHeight))
    )
}
