import Darwin
import Foundation
import Metal
import XCTest
@testable import MetaphorCLICore
@testable import MetaphorViewer

/// 共有メモリ → `MTLBuffer(bytesNoCopy:)` → linear texture view の経路を GPU で検証する。
/// GPU が無い環境（CI の一部）では skip。listener は `.main` で動かし、XCTest のメインスレッドで
/// run loop を回して配送する（本番と同じスレッド構成）。
final class FrameIPCSourceTests: XCTestCase {
    private var device: MTLDevice!
    private var listener: FrameIPCListener!
    private var source: FrameIPCSource!
    private var path: String!
    private var diagnostics: [String] = []

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device が無い環境")
        }
        self.device = device
        path = try FrameIPCFixture.socketPath()
        listener = try FrameIPCListener(path: path, queue: .main)
        source = FrameIPCSource(listener: listener, device: device)
        source.onDiagnostic = { [weak self] in self?.diagnostics.append($0) }
    }

    override func tearDown() {
        listener?.stop()
        source = nil
        listener = nil
    }

    /// メインの run loop を回しながら `condition` が真になるのを待つ。
    private func spin(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// slot を BGRA のパターン（B = x, G = y, R = tag, A = 255）で塗る。
    private func paint(shm: Int32, slot: Int, tag: UInt8) throws {
        let total = FrameIPCFixture.totalBytes
        guard let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, shm, 0), base != MAP_FAILED else {
            throw NSError(domain: "mmap", code: Int(errno))
        }
        defer { munmap(base, total) }
        let bytes = base.assumingMemoryBound(to: UInt8.self) + slot * FrameIPCFixture.slotBytes
        for y in 0..<FrameIPCFixture.height {
            for x in 0..<FrameIPCFixture.width {
                let p = bytes + y * FrameIPCFixture.bytesPerRow + x * 4
                p[0] = UInt8(x); p[1] = UInt8(y); p[2] = tag; p[3] = 255
            }
        }
    }

    /// texture を shared texture へ blit して読み戻す。
    private func readBack(_ texture: MTLTexture) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let copy = device.makeTexture(descriptor: descriptor)!
        let queue = device.makeCommandQueue()!
        let commandBuffer = queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(
            &pixels, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
        )
        return pixels
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(pixels[i..<i + 4])
    }

    func testFrameInSharedMemoryIsReadableAsATextureWithoutCopying() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try paint(shm: shm, slot: 1, tag: 0x33)
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        try producer.send(line: FrameIPCFixture.frameLine(slot: 1, seq: 1))

        var texture: MTLTexture?
        XCTAssertTrue(spin { texture = source.currentTexture(); return texture != nil }, "diagnostics: \(diagnostics)")
        let tex = try XCTUnwrap(texture)
        XCTAssertEqual(source.status, .connected(width: FrameIPCFixture.width, height: FrameIPCFixture.height))
        XCTAssertEqual(tex.width, FrameIPCFixture.width)
        XCTAssertEqual(tex.height, FrameIPCFixture.height)
        XCTAssertNotNil(tex.buffer, "a linear texture view over the shared memory, not a copy")

        let pixels = readBack(tex)
        XCTAssertEqual(pixel(pixels, x: 5, y: 3, width: tex.width), [5, 3, 0x33, 255], "row 0 = top, no flip")
        XCTAssertEqual(pixel(pixels, x: 63, y: 15, width: tex.width), [63, 15, 0x33, 255])

        // 同じ mapping を producer が書き換えれば GPU からもそのまま見える（コピー無し）。
        try paint(shm: shm, slot: 1, tag: 0x77)
        XCTAssertEqual(pixel(readBack(tex), x: 5, y: 3, width: tex.width), [5, 3, 0x77, 255])
        XCTAssertNil(source.currentTexture(), "no new frame: the window keeps the displayed one")
    }

    func testReleaseIsSentAfterTheGPUReadOfTheOvertakenSlotCompletes() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        var first: MTLTexture?
        XCTAssertTrue(spin { first = source.currentTexture(); return first != nil })

        // 窓が slot 0 をサンプルする command buffer を commit する（完了は待たせる）。
        let queue = device.makeCommandQueue()!
        let commandBuffer = queue.makeCommandBuffer()!
        source.noteSampling(of: try XCTUnwrap(first), in: commandBuffer)

        try producer.send(line: FrameIPCFixture.frameLine(slot: 1, seq: 2))
        var second: MTLTexture?
        XCTAssertTrue(spin { second = source.currentTexture(); return second != nil })
        XCTAssertTrue(second !== first)
        XCTAssertNil(producer.readLine(timeout: 0.3), "slot 0 is still being read by the GPU — no release yet")

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var line: String?
        XCTAssertTrue(spin { line = producer.readLine(timeout: 0.05); return line != nil })
        XCTAssertEqual(line, #"{"t":"release","slot":0}"#)
        XCTAssertGreaterThan(source.latency.count, 0, "frame → first GPU completion latency is recorded")
    }

    func testOvertakenPendingSlotIsReleasedWithoutBeingDisplayed() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        try producer.send(line: FrameIPCFixture.frameLine(slot: 1, seq: 2))
        var line: String?
        XCTAssertTrue(spin { line = producer.readLine(timeout: 0.05); return line != nil })
        XCTAssertEqual(line, #"{"t":"release","slot":0}"#, "latest-wins: slot 0 never reached the screen")
        var shown: MTLTexture?
        XCTAssertTrue(spin { shown = source.currentTexture(); return shown != nil })
        XCTAssertEqual(pixel(readBack(try XCTUnwrap(shown)), x: 0, y: 0, width: FrameIPCFixture.width).count, 4)
    }

    func testResizeReplacesTheWorldAndKeepsTheOldTextureReadable() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try paint(shm: shm, slot: 0, tag: 0x11)
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        var old: MTLTexture?
        XCTAssertTrue(spin { old = source.currentTexture(); return old != nil })

        // resize: 同じ接続で新しい world（32x8）の hello を再送。
        let bigger = Int(getpagesize())
        let shm2 = try FakeProducer.makeSharedMemory(bytes: bigger * 3)
        defer { close(shm2) }
        try producer.sendHello(
            FrameIPCFixture.helloLine(width: 32, height: 8, bytesPerRow: 256, slotBytes: bigger), fd: shm2
        )
        XCTAssertTrue(spin { source.status == .connected(width: 32, height: 8) })
        XCTAssertNil(source.currentTexture(), "no frame in the new world yet → keep showing the old texture")
        try producer.send(line: FrameIPCFixture.frameLine(slot: 2, seq: 2))
        var fresh: MTLTexture?
        XCTAssertTrue(spin { fresh = source.currentTexture(); return fresh != nil })
        XCTAssertEqual(fresh?.width, 32)
        XCTAssertEqual(fresh?.height, 8)

        // 旧 world の texture は（参照を持っている限り）読める。mapping は Metal が保持する。
        XCTAssertEqual(pixel(readBack(try XCTUnwrap(old)), x: 1, y: 2, width: FrameIPCFixture.width), [1, 2, 0x11, 255])
    }

    func testHelloWithMismatchedSharedMemorySizeIsRejected() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: Int(getpagesize()))  // 1 slot 分しか無い
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        XCTAssertTrue(spin { !diagnostics.isEmpty })
        XCTAssertTrue(diagnostics[0].contains("サイズ"), "\(diagnostics)")
        if case .connected = source.status { XCTFail("must not report connected") }
    }

    func testDisconnectionAfterHelloIsReportedAndNewGenerationResets() throws {
        var disconnected = 0
        source.onDisconnected = { disconnected += 1 }
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        XCTAssertTrue(spin { source.hasReceivedHello })
        producer.close()
        XCTAssertTrue(spin { disconnected == 1 })
        XCTAssertEqual(source.status, .disconnected)

        // 親が「次の子」を待つと宣言すれば、切断ではなく待機になる。
        source.expectNewGeneration()
        if case .waitingForConnection = source.status {} else { XCTFail("expected waiting, got \(source.status)") }
        let next = try FakeProducer(path: path)
        XCTAssertTrue(spin { listener.currentGeneration == 2 })
        XCTAssertFalse(source.hasReceivedHello)
        _ = next
    }
}
