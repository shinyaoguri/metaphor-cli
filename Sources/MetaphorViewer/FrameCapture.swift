import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ヘッドレス検証用: 名前付き Syphon サーバーに接続して1フレームを取得し、PNG に書き出す。
///
/// ビューア窓を開かずに「フレームが本当に届いているか」を確認するための関数。
/// `metaphor __capture <serverName> <outputPath>` から使う。
///
/// - Returns: 成功したら `true`。サーバーが見つからない/フレームが来ない場合は `false`。
public func captureSyphonFrame(
    serverName: String,
    outputPath: String,
    timeout: TimeInterval = 8.0
) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        return false
    }

    let source = SyphonFrameSource(device: device, serverName: serverName)
    let deadline = Date().addingTimeInterval(timeout)

    // サーバー接続を待つ。Syphon のサーバー発見は NSDistributedNotificationCenter
    // 経由（run loop 配送）なので、run loop を回しながら待つ必要がある。
    while !source.isConnected {
        source.poll()
        if Date() >= deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    // フレーム到着を待つ。
    var frame: MTLTexture?
    while frame == nil {
        frame = source.currentTexture()
        if frame == nil {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    guard let texture = frame else { return false }

    guard let png = pngData(from: texture, device: device, queue: queue) else {
        return false
    }
    return (try? png.write(to: URL(fileURLWithPath: outputPath))) != nil
}

/// `MTLTexture`（BGRA8 想定）を共有テクスチャに blit して読み戻し、PNG データを作る。
private func pngData(from texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> Data? {
    let width = texture.width
    let height = texture.height

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let staging = device.makeTexture(descriptor: descriptor),
          let commandBuffer = queue.makeCommandBuffer(),
          let blit = commandBuffer.makeBlitCommandEncoder() else {
        return nil
    }
    blit.copy(
        from: texture,
        sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: width, height: height, depth: 1),
        to: staging,
        destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    staging.getBytes(
        &pixels, bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
    )

    // metaphor は Syphon へ flipped: true で publish するため、検証画像が正しい向きに
    // なるよう行順を反転する（実際のビューア窓ではサンプラの UV で処理する）。
    pixels = verticallyFlipped(pixels, width: width, height: height)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )
    guard let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace, bitmapInfo: bitmapInfo.rawValue
    ), let cgImage = context.makeImage() else {
        return nil
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// BGRA8 バッファの行順を上下反転する。
private func verticallyFlipped(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
    let bytesPerRow = width * 4
    var flipped = [UInt8](repeating: 0, count: pixels.count)
    for row in 0..<height {
        let src = row * bytesPerRow
        let dst = (height - 1 - row) * bytesPerRow
        flipped.replaceSubrange(dst..<(dst + bytesPerRow), with: pixels[src..<(src + bytesPerRow)])
    }
    return flipped
}
