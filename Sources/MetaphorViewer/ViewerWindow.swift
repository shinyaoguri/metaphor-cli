import AppKit
import MetalKit
import Metal
import MetaphorCLICore
import QuartzCore

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

/// 名前付き Syphon サーバーのフレームをウィンドウに表示するライブビューア。
///
/// `MTKView` に Syphon の最新テクスチャをアスペクト比保持（レターボックス）で
/// 表示する。フレームは ``SyphonFrameSource`` から取得し、metaphor が flipped:true で
/// publish するため、サンプリング時に上下反転する。
public final class ViewerWindow: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let source: SyphonFrameSource

    private let window: NSWindow
    private let view: MTKView

    /// Syphon フレームをアスペクト比保持で描くオフスクリーンテクスチャ（ドローアブル相当サイズ）。
    /// これをドローアブルへ blit してから present する。
    private var offscreen: MTLTexture?

    /// 最後に受信した Syphon フレーム。フレームが来ないフレーム（newFrameImage が nil）
    /// でも直前の画を出し続けるために保持する。Syphon テクスチャは bgra8Unorm なので
    /// そのままサンプルすれば色は正しい。
    private var lastFrame: MTLTexture?

    /// キャプチャした入力イベント（JSON Lines 1 行）の送出先。
    /// `ViewerWatch` が子スケッチの stdin へ転送するようつなぐ。未設定なら入力は捨てる。
    public var onInput: ((String) -> Void)?

    /// ローカル NSEvent モニタ（マウス/キー捕捉）。deinit で解除する。
    private var eventMonitor: Any?

    /// 現在の段階。`setState(_:)` で更新し、`refreshOverlay()` が見た目へ反映する。
    /// 既定は `.building`（窓が開いた瞬間から「ビルド中…」を出す）。
    private var state: ViewerState = .building

    /// 一度でもフレームを描いたか。全面オーバーレイか右下バッジかの出し分けに使う。
    private var hasRenderedFrame = false

    /// 全面ローディング表示（フレーム未取得時）。
    private var fullOverlay: StatusOverlayView?
    /// 右下の控えめなバッジ（フレーム取得済みのリロード中など）。
    private var badge: StatusBadgeView?

    /// - Parameters:
    ///   - serverName: 接続する Syphon サーバー名（子プロセスの METAPHOR_SYPHON_NAME）。
    ///   - title: ウィンドウタイトル。
    ///   - width/height: 初期ウィンドウサイズ。
    public init?(serverName: String, title: String, width: Int = 960, height: Int = 540) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.source = SyphonFrameSource(device: device, serverName: serverName)

        guard let pipeline = ViewerWindow.makeBlitPipeline(device: device) else {
            return nil
        }
        self.pipeline = pipeline

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        self.window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.view = MTKView(frame: rect, device: device)

        super.init()

        window.title = title
        window.center()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // ドローアブルへ blit コピーするため framebufferOnly を無効化する。
        // （ドローアブルへ直接テクスチャをサンプル描画すると画面が黒くなる環境への回避策）
        view.framebufferOnly = false
        view.delegate = self
        view.preferredFramesPerSecond = 60
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        // ローディング/状態オーバーレイを MTKView の上に重ねる（Metal レイヤーの上に
        // Core Animation が合成する）。純粋な装飾なのでヒットテストは透過させ、
        // 入力捕捉（ローカル NSEvent モニタ）やライブ表示の操作を妨げない。
        let full = StatusOverlayView(frame: view.bounds)
        full.autoresizingMask = [.width, .height]
        view.addSubview(full)
        self.fullOverlay = full

        let badge = StatusBadgeView()
        view.addSubview(badge)
        self.badge = badge
        positionBadge()
        refreshOverlay()

        // 新フレーム到着で確実に再描画（連続描画もしているため保険）。
        source.onFrame = { [weak view] in
            DispatchQueue.main.async { view?.needsDisplay = true }
        }
    }

    /// 右下バッジを MTKView の右下隅へ置き直す。リサイズに追従させるため
    /// `autoresizingMask` で左マージン/上マージンを可変にする。
    private func positionBadge() {
        guard let badge else { return }
        badge.layoutImmediately()
        let margin: CGFloat = 12
        let size = badge.fittingSize
        badge.frame = NSRect(
            x: view.bounds.width - size.width - margin,
            y: margin,
            width: size.width,
            height: size.height
        )
        badge.autoresizingMask = [.minXMargin, .maxYMargin]
    }

    /// ウィンドウを表示し前面に出す。
    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitor()
    }

    /// 子スケッチが（再）起動したことを通知する。次に現れる別 UUID の同名サーバー
    /// （＝再起動後の子）へ張り替える。メインスレッドから呼ぶこと。
    public func notifyChildRelaunched() {
        source.expectNewServer()
    }

    /// ビューアの段階を更新し、ローディング/状態表示へ反映する。**メインスレッドから
    /// 呼ぶこと**（`ViewerWatch` がバックグラウンドのコールバックからメインへホップして呼ぶ）。
    /// `.rendering` への遷移は最初のフレーム描画時に内部で行うため、通常ここへは
    /// `.building` / `.buildFailed` / `.launching` が渡る。
    public func setState(_ newState: ViewerState) {
        state = newState
        refreshOverlay()
    }

    /// 現在の `state` と `hasRenderedFrame` から、全面オーバーレイと右下バッジの
    /// 表示内容・表示/非表示を決める。
    private func refreshOverlay() {
        guard let fullOverlay, let badge else { return }

        // フレームを一度も描いていなければ全面オーバーレイ、描いていれば（直前の絵を
        // 覆わないよう）右下バッジに出す。`.rendering` ではどちらも隠す。
        switch state {
        case .rendering:
            fullOverlay.isHidden = true
            badge.isHidden = true

        case .building:
            if hasRenderedFrame {
                fullOverlay.isHidden = true
                badge.isHidden = false
                badge.configure(spinning: true, text: "再ビルド中…")
            } else {
                badge.isHidden = true
                fullOverlay.isHidden = false
                fullOverlay.configure(mode: .loading, title: "ビルド中…", detail: "初回ビルドには少し時間がかかります")
            }

        case .launching:
            if hasRenderedFrame {
                fullOverlay.isHidden = true
                badge.isHidden = false
                badge.configure(spinning: true, text: "新しいフレームを待機中…")
            } else {
                badge.isHidden = true
                fullOverlay.isHidden = false
                fullOverlay.configure(mode: .loading, title: "スケッチを起動中…", detail: "Syphon 出力を待機しています")
            }

        case .buildFailed(let message):
            if hasRenderedFrame {
                fullOverlay.isHidden = true
                badge.isHidden = false
                badge.configure(spinning: false, text: "⚠ ビルド失敗 — 直前の表示を維持")
            } else {
                badge.isHidden = true
                fullOverlay.isHidden = false
                fullOverlay.configure(mode: .failed, title: "ビルド失敗", detail: message ?? "変更を保存すると再ビルドします")
            }
        }

        positionBadge()
    }

    // MARK: - Input capture

    /// このウィンドウ宛のマウス/キーイベントを捕捉し、キャンバス座標へ変換して送出する。
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        // ドラッグ無しのマウス移動も取るためウィンドウに mouseMoved を有効化。
        window.acceptsMouseMovedEvents = true

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp,
        ]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event  // イベントは通常どおり伝播させる（ビューア窓のUI操作を妨げない）。
        }
    }

    /// 捕捉した NSEvent を JSON Lines に変換して ``onInput`` へ流す。
    private func handle(_ event: NSEvent) {
        // 自ウィンドウ宛のイベントのみ扱う（他ウィンドウ/メニュー操作は無視）。
        guard event.window === window, let onInput else { return }

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let p = canvasPoint(for: event) {
                emit(OutEvent(t: "mouseDown", x: p.x, y: p.y, button: buttonIndex(event)), via: onInput)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let p = canvasPoint(for: event) {
                emit(OutEvent(t: "mouseUp", x: p.x, y: p.y, button: buttonIndex(event)), via: onInput)
            }
        case .mouseMoved:
            if let p = canvasPoint(for: event) {
                emit(OutEvent(t: "mouseMove", x: p.x, y: p.y), via: onInput)
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if let p = canvasPoint(for: event) {
                emit(OutEvent(t: "mouseDrag", x: p.x, y: p.y), via: onInput)
            }
        case .scrollWheel:
            emit(OutEvent(t: "scroll", dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY)), via: onInput)
        case .keyDown:
            emit(OutEvent(t: "keyDown", code: event.keyCode, chars: event.characters, repeat: event.isARepeat), via: onInput)
        case .keyUp:
            emit(OutEvent(t: "keyUp", code: event.keyCode), via: onInput)
        default:
            break
        }
    }

    /// マウスイベントのウィンドウ座標をキャンバス座標へ逆変換する。
    /// フレーム未受信（キャンバス解像度不明）の間は nil を返して捨てる。
    private func canvasPoint(for event: NSEvent) -> (x: Float, y: Float)? {
        guard let texture = lastFrame else { return nil }
        // ウィンドウ座標 → ビュー座標（左下原点）→ 左上原点へ反転。
        let inView = view.convert(event.locationInWindow, from: nil)
        let yTopLeft = Double(view.bounds.height) - Double(inView.y)
        let c = canvasCoordinate(
            viewX: Double(inView.x), viewYTopLeft: yTopLeft,
            viewWidth: Double(view.bounds.width), viewHeight: Double(view.bounds.height),
            contentWidth: texture.width, contentHeight: texture.height
        )
        return (Float(c.x), Float(c.y))
    }

    /// metaphor のボタン番号（左=0, 右=1, その他=2）。ネイティブ窓 `MetaphorMTKView`
    /// の `mouseButtonIndex` と一致させる。
    private func buttonIndex(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return 0
        case .rightMouseDown, .rightMouseUp: return 1
        default: return 2
        }
    }

    private func emit(_ event: OutEvent, via sink: (String) -> Void) {
        guard let line = event.jsonLine() else { return }
        sink(line)
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var statusFrames = 0
    private var loggedFirstFrame = false

    public func draw(in view: MTKView) {
        // 接続・子プロセス差し替え（リロード）検知。``SyphonFrameSource`` が
        // 同名・別 UUID の新サーバーへの張り替えまで面倒を見る。
        source.poll()

        // 最新フレーム（bgra8Unorm）。来ていなければ直前フレームを使い続ける。
        if let frame = source.currentTexture() {
            lastFrame = frame
            hasRenderedFrame = true
            // 起動待ち（初回／リロード後）から最初の新フレームが届いたら描画中へ。
            // `.building` 中に旧サーバーの残像が返ることがあるため、遷移は `.launching`
            // からのみ（誤ってローディング表示を消さない）。
            if case .launching = state {
                setState(.rendering)
            }
        }

        // 状態をターミナルに表示（最初のフレーム受信・待機を可視化）。
        statusFrames += 1
        if lastFrame != nil && !loggedFirstFrame {
            loggedFirstFrame = true
            let s = lastFrame.map { "\($0.width)x\($0.height) fmt=\($0.pixelFormat.rawValue)" } ?? "?"
            FileHandle.standardError.write("[viewer] フレーム受信中 \(s)\n".data(using: .utf8)!)
        }
        if statusFrames % 180 == 0 && lastFrame == nil {
            FileHandle.standardError.write("[viewer] スケッチの Syphon 出力を待機中…\n".data(using: .utf8)!)
        }

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let dw = drawable.texture.width
        let dh = drawable.texture.height

        // ドローアブルと同じサイズのオフスクリーンを用意。
        if offscreen?.width != dw || offscreen?.height != dh {
            let od = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: dw, height: dh, mipmapped: false
            )
            od.usage = [.renderTarget, .shaderRead]
            od.storageMode = .private
            offscreen = device.makeTexture(descriptor: od)
        }

        guard let offscreen else { return }

        // 1) Syphon フレームをオフスクリーンへアスペクト比保持で描画（サンプリングは
        //    オフスクリーン宛て。ドローアブルへ直接サンプル描画すると画面が黒くなるため）。
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = offscreen
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            if let texture = lastFrame {
                let fit = aspectFitRect(
                    drawableWidth: Double(dw), drawableHeight: Double(dh),
                    contentWidth: texture.width, contentHeight: texture.height
                )
                encoder.setViewport(MTLViewport(
                    originX: fit.x, originY: fit.y,
                    width: fit.width, height: fit.height, znear: 0, zfar: 1
                ))
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
        }

        // 2) オフスクリーンをドローアブルへ blit（サンプル描画でなく blit で書き込む）。
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: offscreen,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: dw, height: dh, depth: 1),
                to: drawable.texture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    /// フルスクリーン三角形で held テクスチャをサンプルする blit パイプライン。
    /// Syphon フレームは上下反転しているため UV の V を反転する。
    private static func makeBlitPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut blit_v(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            VOut o;
            o.pos = float4(p[vid], 0.0, 1.0);
            // オフスクリーン描画では NDC→テクスチャの Y 反転が入るため、ここでは
            // V を反転しない（これで Syphon の上下反転と合わせて正立になる）。
            o.uv = float2((p[vid].x + 1.0) * 0.5, (p[vid].y + 1.0) * 0.5);
            return o;
        }
        fragment float4 blit_f(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vfn = library.makeFunction(name: "blit_v"),
              let ffn = library.makeFunction(name: "blit_f") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// 子スケッチの `InputInjectionPlugin` が読む JSON Lines 1 行に対応する送出イベント。
/// オプショナルは `encodeIfPresent` で nil キーが省かれる（種別ごとに必要な field のみ出る）。
private struct OutEvent: Encodable {
    let t: String
    var x: Float?
    var y: Float?
    var button: Int?
    var dx: Float?
    var dy: Float?
    var code: UInt16?
    var chars: String?
    var `repeat`: Bool?

    init(
        t: String, x: Float? = nil, y: Float? = nil, button: Int? = nil,
        dx: Float? = nil, dy: Float? = nil, code: UInt16? = nil,
        chars: String? = nil, repeat isRepeat: Bool? = nil
    ) {
        self.t = t; self.x = x; self.y = y; self.button = button
        self.dx = dx; self.dy = dy; self.code = code
        self.chars = chars; self.repeat = isRepeat
    }

    /// 1 行の JSON 文字列にエンコードする（改行は呼び出し側 / `sendLine` が付ける）。
    func jsonLine() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Status overlays

/// アクセントカラー（スピナー）。落ち着いた水色系。
private let statusAccentColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.0, alpha: 1.0)

/// ゆっくり脈動しながら回る有機的なブロブ（不定形の塊）で「処理中」を示す自前スピナー。
/// 輪郭の半径を複数の正弦波の和でゆらすことで、生きているように形が変わり続ける。
/// 形の変形（path のキーフレーム）と全体の回転を CoreAnimation で無限ループさせる。
/// ビルドはバックグラウンドキューで走りメインスレッドは空くため、処理中も止まらない。
private final class SpinnerView: NSView {
    private let blob = CALayer()        // 回転する入れ物
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()   // ブロブ形のマスク（これを変形させる）
    private let diameter: CGFloat

    /// 形のキーフレーム数（多いほど滑らか）。
    private static let morphFrames = 24

    init(diameter: CGFloat, lineWidth: CGFloat, color: NSColor) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.masksToBounds = false

        // 回転する入れ物（中心回りに回すため bounds=自サイズ・position=中心）。
        blob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        blob.position = CGPoint(x: diameter / 2, y: diameter / 2)

        // やわらかい陰影が出るよう、アクセント色の縦グラデーションをブロブ形で切り抜く。
        let light = SpinnerView.lighten(color, by: 0.18)
        gradient.frame = blob.bounds
        gradient.colors = [light.cgColor, color.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)

        mask.path = SpinnerView.blobPath(diameter: diameter, t: 0)
        mask.fillColor = NSColor.black.cgColor  // マスクは不透明部分だけ通す
        gradient.mask = mask

        blob.addSublayer(gradient)
        layer?.addSublayer(blob)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    /// 変形と回転を開始する（既に動いていれば何もしない）。
    func startAnimating() {
        guard mask.animation(forKey: "morph") == nil else { return }

        // 半径のゆらぎの位相 t を 0→2π まで動かすと元に戻るので、継ぎ目なくループする。
        var paths: [CGPath] = []
        for k in 0...SpinnerView.morphFrames {
            let t = CGFloat(k) / CGFloat(SpinnerView.morphFrames) * 2 * .pi
            paths.append(SpinnerView.blobPath(diameter: diameter, t: t))
        }
        let morph = CAKeyframeAnimation(keyPath: "path")
        morph.values = paths
        morph.duration = 2.8
        morph.repeatCount = .infinity
        morph.isRemovedOnCompletion = false
        mask.add(morph, forKey: "morph")

        // 全体をゆっくり回す（変形とは別周期にして単調さを消す）。
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        blob.add(spin, forKey: "spin")
    }

    func stopAnimating() {
        mask.removeAnimation(forKey: "morph")
        blob.removeAnimation(forKey: "spin")
    }

    /// 中心からの半径を複数の正弦波の和でゆらした、滑らかな閉じたブロブ輪郭。
    /// 位相 `t` を進めると形が変わり、`t = 2π` で `t = 0` に戻る。
    private static func blobPath(diameter: CGFloat, t: CGFloat) -> CGPath {
        let segments = 72
        let center = diameter / 2
        let base = diameter * 0.34
        let path = CGMutablePath()
        for i in 0...segments {
            let theta = CGFloat(i) / CGFloat(segments) * 2 * .pi
            // 周回数の異なる波を重ね、逆位相にも動かして有機的なゆらぎにする。
            let wobble = 0.11 * sin(3 * theta + t) + 0.07 * sin(2 * theta + 1.7 - t)
            let r = base * (1 + wobble)
            let point = CGPoint(x: center + r * cos(theta), y: center + r * sin(theta))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// 色を白方向へ `amount`（0–1）混ぜて明るくする。
    private static func lighten(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        return NSColor(
            deviceRed: c.redComponent + (1 - c.redComponent) * amount,
            green: c.greenComponent + (1 - c.greenComponent) * amount,
            blue: c.blueComponent + (1 - c.blueComponent) * amount,
            alpha: c.alphaComponent
        )
    }
}

/// フレーム未取得時に窓全体を覆うローディング/エラー表示。暗幕の中央に、回転スピナー
/// （または警告アイコン）とタイトル・詳細を縦に並べるだけのフラットな構成。装飾専用
/// なのでヒットテストは透過。
private final class StatusOverlayView: NSView {
    enum Mode { case loading, failed }

    private let spinner = SpinnerView(diameter: 54, lineWidth: 2.5, color: statusAccentColor)
    private let icon = NSImageView()
    private let titleLabel = StatusOverlayView.makeLabel(size: 14, weight: .medium, color: .white)
    private let detailLabel = StatusOverlayView.makeLabel(size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.55))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 全体を暗幕で覆うだけ（枠やカードは出さない）。
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor

        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "ビルド失敗")
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.isHidden = true

        let stack = NSStackView(views: [spinner, icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(8, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 装飾なのでクリック等は背後（ライブ表示）へ透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(mode: Mode, title: String, detail: String?) {
        switch mode {
        case .loading:
            icon.isHidden = true
            spinner.isHidden = false
            spinner.startAnimating()
        case .failed:
            spinner.stopAnimating()
            spinner.isHidden = true
            icon.isHidden = false
        }
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
    }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        return label
    }
}

/// フレーム取得済みのリロード中などに、直前の絵を覆わず右下へ小さく出す状態バッジ。
private final class StatusBadgeView: NSView {
    private let spinner = SpinnerView(diameter: 13, lineWidth: 2, color: .white)
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 6

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([spinner, label], in: .leading)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 装飾なのでクリック等は背後（ライブ表示）へ透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// バッジの中身を設定する。`spinning=false` のときはスピナーを隠す（失敗表示など）。
    func configure(spinning: Bool, text: String) {
        label.stringValue = text
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// `fittingSize` 計算前にレイアウトを確定させる（右下配置の幅/高さを正しく得るため）。
    func layoutImmediately() {
        layoutSubtreeIfNeeded()
    }
}
