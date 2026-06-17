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
