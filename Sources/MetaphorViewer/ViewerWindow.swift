import AppKit
import MetalKit
import Metal
import MetaphorCLICore

/// 名前付き Syphon サーバーのフレームをウィンドウに表示するライブビューア。
///
/// `MTKView` に Syphon の最新テクスチャをアスペクト比保持（レターボックス）で
/// blit する。フレームは ``SyphonFrameSource`` から取得し、metaphor が flipped:true で
/// publish するため、サンプリング時に上下反転する。
public final class ViewerWindow: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let source: SyphonFrameSource

    private let window: NSWindow
    private let view: MTKView

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

    public func draw(in view: MTKView) {
        // サーバー未接続なら接続を試みる（子プロセスが後から起動するため）。
        if !source.isConnected {
            _ = source.connectIfAvailable()
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        if let texture = source.currentTexture() {
            let fit = aspectFitRect(
                drawableWidth: Double(view.drawableSize.width),
                drawableHeight: Double(view.drawableSize.height),
                contentWidth: texture.width,
                contentHeight: texture.height
            )
            encoder.setViewport(MTLViewport(
                originX: fit.x, originY: fit.y,
                width: fit.width, height: fit.height,
                znear: 0, zfar: 1
            ))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        // テクスチャ無しのときはクリアのみ（前フレームは drawable のため残らないが、
        // サーバー切替時の黒画面は許容範囲）。

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    /// フルスクリーン三角形で Syphon テクスチャをサンプルする blit パイプライン。
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
            o.uv = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);
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
