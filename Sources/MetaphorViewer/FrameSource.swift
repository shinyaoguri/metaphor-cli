import Foundation
import Metal

/// ライブビューア窓（``ViewerWindow``）へフレームを供給する側の抽象。
///
/// 窓は「最新フレームのテクスチャを毎フレーム取りに行き、接続状態に応じて
/// ローディング表示とログを出す」ことしか知らない。供給元がどの転送路で
/// フレームを受け取るかはこの protocol の後ろに隠し、転送路を差し替えても窓側を
/// 触らなくて済むようにする（metaphor#792 — 現在の実装は frame IPC の ``FrameIPCSource``）。
///
/// すべてのメソッドはメインスレッド（`MTKViewDelegate.draw(in:)`）から呼ばれる。
/// ``onFrame`` だけは供給元のスレッドから呼ばれうるので、受け手がメインへホップする。
public protocol FrameSource: AnyObject {
    /// 新フレーム到着時に呼ばれる（供給元のスレッドから呼ばれうる）。
    var onFrame: (() -> Void)? { get set }

    /// 現在の接続状態。表示文言は窓側が決める（供給元は状態だけを返す）。
    var status: FrameSourceStatus { get }

    /// 毎フレーム呼ぶ。接続・子プロセス差し替えの検知・復帰動作をまとめて行う。
    func poll()

    /// 最新フレームのテクスチャ（`bgra8Unorm`、row 0 = top）。まだ無ければ nil。
    /// nil の間、窓は直前のフレームを描き続ける。
    func currentTexture() -> MTLTexture?

    /// 子スケッチが（再）起動したことを親から通知する。以降は「再起動後の子」からの
    /// フレームへ切り替え、それが現れるまでは現在の表示を保つ。
    func expectNewGeneration()

    /// 窓が `texture` をサンプルする command buffer を commit する直前に呼ぶ。
    /// 供給元は完了ハンドラを登録し、GPU 読みが終わった slot を子へ `release` できる。
    /// 必要の無い供給元は何もしなくてよい（既定実装）。
    func noteSampling(of texture: MTLTexture, in commandBuffer: MTLCommandBuffer)
}

public extension FrameSource {
    func noteSampling(of texture: MTLTexture, in commandBuffer: MTLCommandBuffer) {}
}

/// ``FrameSource`` の接続状態。
public enum FrameSourceStatus: Equatable {
    /// 供給元（子スケッチの出力）が現れるのを待っている。
    /// `since` は待ち始めた時刻（`CACurrentMediaTime()` 基準の秒）。
    case waitingForConnection(since: TimeInterval)
    /// 供給元に接続済み。`width` / `height` はフレームのピクセルサイズ。
    case connected(width: Int, height: Int)
    /// 接続の合図（`hello`）が一定時間来なかった。子が生きているなら本体の版が古い
    /// （frame IPC を知らない）可能性が高い。判断は窓側（子の生死を知っている）が行う。
    case helloTimedOut
    /// 切断された（子の終了・クラッシュ）。
    case disconnected
}
