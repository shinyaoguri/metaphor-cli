import Darwin
import Foundation
import Metal
import MetaphorCLICore
import QuartzCore

/// frame IPC（CONTRACT.md 契約点 5）で子スケッチからフレームを受け取る ``FrameSource``。
///
/// ``FrameIPCListener`` が受けた `hello` の共有メモリ fd を `mmap` し、
/// `MTLBuffer(bytesNoCopy:)` で GPU から直接読めるバッファにして、slot ごとに linear texture
/// view を作る（コピーは発生しない）。`frame` が届いた slot を表示し、表示し終えて GPU 読みも
/// 完了した slot を `release` で子へ返す（状態機械は ``ViewerSlotTracker``）。
///
/// ## 世代
///
/// 接続 1 本 = 子 1 プロセス = 1 世代（accept 順）。新しい子が接続して最初の `frame` が
/// 届くまでは**旧世代の texture を表示し続ける**（mapping は子の死後も有効）。旧世代の
/// mapping は Metal の参照管理に任せて解放する: texture view が buffer を、in-flight の
/// command buffer が texture を保持するので、こちらが参照を捨てれば、旧 slot をサンプルした
/// command buffer の完了後に `munmap` が走る（手で in-flight を数えて unmap しない）。
///
/// すべてメインスレッド（listener の queue）で動く。command buffer の完了ハンドラだけは
/// Metal のスレッドから来るのでメインへホップする。
public final class FrameIPCSource: FrameSource {
    /// `hello` を待つ上限。これを過ぎると ``status`` が `.helloTimedOut` になる
    /// （`ProbeSnapshotTool` の cold-start 既定に倣う）。
    public static let helloTimeout: TimeInterval = 15

    public var onFrame: (() -> Void)?
    /// `hello` を受理した（world を張れた）ときに呼ばれる。
    public var onHello: ((ViewerHello) -> Void)?
    /// 現世代の接続が閉じた（子の終了・クラッシュ）ときに呼ばれる。
    public var onDisconnected: (() -> Void)?
    /// 診断メッセージ（既定は stderr）。
    public var onDiagnostic: (String) -> Void = { message in
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    private let device: MTLDevice
    private let listener: FrameIPCListener

    private var world: World?
    private var tracker = ViewerSlotTracker()
    private var currentGeneration: Int?
    private var helloReceived = false
    private var expectingNewGeneration = true
    private var waitingSince: TimeInterval = CACurrentMediaTime()
    private var isDisconnected = false

    /// 直近の `frame` が届いた時刻（slot ごと）。表示までの遅延の計測用。
    private var frameArrivedAt: [Int: TimeInterval] = [:]
    /// `frame` 受信 → その slot をサンプルした最初の command buffer の完了までの遅延。
    public private(set) var latency = LatencyStats()
    /// 受け取った `frame` の数と、実際に表示へ回した数（差 = latest-wins で追い越した数）。
    public private(set) var receivedFrames = 0
    public private(set) var displayedFrames = 0
    /// `METAPHOR_VIEWER_DEBUG=1` のとき、`frame` 300 枚ごとに受信・表示・遅延の統計を stderr へ出す。
    private let debugStats = ProcessInfo.processInfo.environment["METAPHOR_VIEWER_DEBUG"] == "1"

    public struct LatencyStats: Equatable {
        public var count = 0
        public var totalSeconds: TimeInterval = 0
        public var maxSeconds: TimeInterval = 0
        public var meanSeconds: TimeInterval { count == 0 ? 0 : totalSeconds / Double(count) }
        mutating func record(_ seconds: TimeInterval) {
            count += 1
            totalSeconds += seconds
            maxSeconds = max(maxSeconds, seconds)
        }
    }

    public init(listener: FrameIPCListener, device: MTLDevice) {
        self.listener = listener
        self.device = device
        listener.onEvent = { [weak self] event in self?.handle(event) }
        listener.onDiagnostic = { [weak self] message in self?.onDiagnostic(message) }
    }

    // MARK: - FrameSource

    public var status: FrameSourceStatus {
        if isDisconnected && !expectingNewGeneration {
            return .disconnected
        }
        if helloReceived, let world {
            return .connected(width: world.hello.width, height: world.hello.height)
        }
        if CACurrentMediaTime() - waitingSince >= Self.helloTimeout {
            return .helloTimedOut
        }
        return .waitingForConnection(since: waitingSince)
    }

    public func poll() {}

    public func currentTexture() -> MTLTexture? {
        guard let world, let taken = tracker.takeForDisplay() else { return nil }
        release(taken.releases)
        displayedFrames += 1
        return world.textures[taken.slot]
    }

    public func expectNewGeneration() {
        expectingNewGeneration = true
        helloReceived = false
        waitingSince = CACurrentMediaTime()
    }

    public func noteSampling(of texture: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        guard let world, let slot = world.textures.firstIndex(where: { $0 === texture }) else { return }
        tracker.gpuReadBegan(slot: slot)
        let arrivedAt = frameArrivedAt.removeValue(forKey: slot)
        commandBuffer.addCompletedHandler { [weak self, weak world] _ in
            let completedAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self, let world, world === self.world else { return }
                if let arrivedAt {
                    self.latency.record(completedAt - arrivedAt)
                }
                self.release(self.tracker.gpuReadEnded(slot: slot))
            }
        }
    }

    // MARK: - Events

    /// 現世代で `hello` を受理済みか（overlay の「本体が古い」判定に使う）。
    public var hasReceivedHello: Bool { helloReceived }

    private func handle(_ event: FrameIPCListener.Event) {
        switch event {
        case .connected(let generation):
            currentGeneration = generation
            helloReceived = false
            isDisconnected = false
            expectingNewGeneration = false
            frameArrivedAt = [:]
            // 新世代の最初の frame までは旧 world を表示し続ける。slot の握りは世代ごと。
            tracker.reset()

        case .hello(let generation, let hello, let fd):
            guard generation == currentGeneration else {
                close(fd)
                return
            }
            if let reason = hello.unsupportedReason {
                close(fd)
                onDiagnostic("[viewer] 子スケッチのフレーム形式を受け付けられません: \(reason)")
                return
            }
            guard let next = World(hello: hello, fd: fd, device: device, diagnostic: onDiagnostic) else {
                return  // World.init が理由を診断済み。fd も閉じてある。
            }
            world = next  // resize（同一接続内の再送）は world の差し替え。旧 world は Metal が解放する。
            tracker.reset()
            frameArrivedAt = [:]
            helloReceived = true
            onHello?(hello)

        case .frame(let generation, let frame):
            guard generation == currentGeneration, let world,
                  frame.slot >= 0, frame.slot < world.textures.count else { return }
            frameArrivedAt[frame.slot] = CACurrentMediaTime()
            release(tracker.frameArrived(slot: frame.slot))
            receivedFrames += 1
            if debugStats, receivedFrames % 300 == 0 {
                onDiagnostic(String(
                    format: "[viewer-debug] received=%d displayed=%d overtaken=%d latency mean=%.2fms max=%.2fms (n=%d)",
                    receivedFrames, displayedFrames, receivedFrames - displayedFrames,
                    latency.meanSeconds * 1000, latency.maxSeconds * 1000, latency.count
                ))
            }
            onFrame?()

        case .bye:
            break

        case .disconnected(let generation):
            guard generation == currentGeneration else { return }
            isDisconnected = true
            tracker.reset()  // release の送り先が無い。
            frameArrivedAt = [:]
            onDisconnected?()
        }
    }

    private func release(_ slots: [Int]) {
        for slot in slots {
            listener.send(release: slot)
        }
    }

    // MARK: - World

    /// 1 世代（1 つの `hello`）ぶんの共有メモリと、その上の texture view。
    private final class World {
        let hello: ViewerHello
        let buffer: MTLBuffer
        let textures: [MTLTexture]

        init?(hello: ViewerHello, fd: Int32, device: MTLDevice, diagnostic: (String) -> Void) {
            defer { close(fd) }  // mapping は fd を閉じても生きる。

            var info = stat()
            guard fstat(fd, &info) == 0, Int(info.st_size) >= hello.totalBytes else {
                diagnostic("[viewer] 共有メモリのサイズが hello と合いません (fstat=\(info.st_size), hello=\(hello.totalBytes))")
                return nil
            }
            let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
            guard hello.bytesPerRow % alignment == 0 else {
                diagnostic("[viewer] bytesPerRow \(hello.bytesPerRow) がこの GPU の alignment \(alignment) に合いません")
                return nil
            }
            let length = hello.totalBytes
            guard let base = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED else {
                diagnostic("[viewer] 共有メモリを mmap できません: \(String(cString: strerror(errno)))")
                return nil
            }
            guard let buffer = device.makeBuffer(
                bytesNoCopy: base, length: length, options: .storageModeShared,
                deallocator: { pointer, size in munmap(pointer, size) }
            ) else {
                munmap(base, length)
                diagnostic("[viewer] 共有メモリを MTLBuffer にできません (\(length) byte)")
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: hello.width, height: hello.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            var textures: [MTLTexture] = []
            for slot in 0..<hello.slots {
                guard let texture = buffer.makeTexture(
                    descriptor: descriptor, offset: slot * hello.slotBytes, bytesPerRow: hello.bytesPerRow
                ) else {
                    diagnostic("[viewer] slot \(slot) の texture view を作れません")
                    return nil
                }
                textures.append(texture)
            }
            self.hello = hello
            self.buffer = buffer
            self.textures = textures
        }
    }
}
