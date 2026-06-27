import Foundation

/// ライブビューア窓が今どの段階にいるかを表す。フレームが届く前の「真っ黒な窓」を
/// 解消し、何が起きているか（ビルド中／失敗／起動待ち）を窓自身に表示するために使う。
///
/// 表示の出し分けは状態と「これまでにフレームを描いたか（`hasRenderedFrame`）」の
/// 組み合わせで決まる。まだ一度も描いていなければ全面オーバーレイ、既に描いていれば
/// （リロード中などは）直前の絵を覆わないよう右下の控えめなバッジにする。
public enum ViewerState: Equatable {
    /// `swift build` 実行中。
    case building
    /// ビルド失敗。`message` はエラー要約（先頭行など、無ければ nil）。
    case buildFailed(message: String?)
    /// 子スケッチ起動済み・最初の（新しい）フレーム待ち。
    case launching
    /// フレーム描画中（オーバーレイは出さない）。
    case rendering
}
