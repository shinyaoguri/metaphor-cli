import AppKit
import MetalKit
import Metal
import MetaphorCLICore

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

        // 新フレーム到着で確実に再描画（連続描画もしているため保険）。
        source.onFrame = { [weak view] in
            DispatchQueue.main.async { view?.needsDisplay = true }
        }
    }

    /// ウィンドウを表示し前面に出す。
    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var statusFrames = 0
    private var loggedConnected = false
    private var loggedFirstFrame = false

    private var framesSinceConnect = 0

    public func draw(in view: MTKView) {
        // サーバー未接続/無効（子プロセス再起動）なら接続し直す。
        if !source.isConnected {
            lastFrame = nil  // 旧サーバーのテクスチャは無効化（retire 済みを掴まない）
            framesSinceConnect = 0
            _ = source.connectIfAvailable()
        }

        // 最新フレーム（bgra8Unorm）。来ていなければ直前フレームを使う。
        if let frame = source.currentTexture() {
            lastFrame = frame
        }

        // 接続済みなのに一定時間フレームが来なければ繋ぎ直す（誤接続/取り残しサーバー
        // からの自己回復）。約2秒（120フレーム）でリセット。
        if source.isConnected {
            framesSinceConnect += 1
            if lastFrame == nil && framesSinceConnect > 120 {
                source.reconnect()
                framesSinceConnect = 0
            }
        }

        // 状態をターミナルに表示（接続・フレーム受信の有無を可視化）。
        statusFrames += 1
        if source.isConnected && !loggedConnected {
            loggedConnected = true
            FileHandle.standardError.write("[viewer] Syphon サーバーに接続しました\n".data(using: .utf8)!)
        }
        if lastFrame != nil && !loggedFirstFrame {
            loggedFirstFrame = true
            let s = lastFrame.map { "\($0.width)x\($0.height) fmt=\($0.pixelFormat.rawValue)" } ?? "?"
            FileHandle.standardError.write("[viewer] フレーム受信中 \(s)\n".data(using: .utf8)!)
        }
        if statusFrames % 180 == 0 && lastFrame == nil {
            FileHandle.standardError.write("[viewer] スケッチの Syphon 出力を待機中…（connected=\(source.isConnected)）\n".data(using: .utf8)!)
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
