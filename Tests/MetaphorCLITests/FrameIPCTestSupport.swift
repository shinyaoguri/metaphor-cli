import CMetaphorFrameIPC
import Darwin
import Foundation
import XCTest
@testable import MetaphorCLICore

/// テストの中で「子スケッチ」を演じる producer。本物の `ViewerOutputPlugin` と同じ wire
/// （socket へ connect → `hello` を fd つきで sendmsg → `frame` 行 → `release` 行を読む）を
/// 同じプロセスから喋る。Metal は使わない（共有メモリは CPU で塗る）。
final class FakeProducer {
    let socket: Int32
    private var inbox = Data()

    init(path: String) throws {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw NSError(domain: "FakeProducer", code: Int(errno)) }
        // 親が閉じた後の送信で SIGPIPE がテストプロセスを殺さないようにする（EPIPE で返る）。
        var one: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = FrameIPCListener.address(for: path)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            Darwin.close(socket)
            throw NSError(domain: "FakeProducer.connect", code: Int(code))
        }
    }

    deinit {
        close()
    }

    /// 匿名 shm を作って `bytes` に伸ばし、その fd を返す。
    static func makeSharedMemory(bytes: Int) throws -> Int32 {
        let fd = metaphor_shm_open_anon()
        guard fd >= 0, ftruncate(fd, off_t(bytes)) == 0 else {
            throw NSError(domain: "FakeProducer.shm", code: Int(errno))
        }
        return fd
    }

    /// `hello` 行を、同じ `sendmsg` に fd を添えて送る。
    func sendHello(_ line: String, fd: Int32) throws {
        let payload = Array((line + "\n").utf8)
        let sent = payload.withUnsafeBytes { metaphor_send_fd(socket, fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else { throw NSError(domain: "FakeProducer.sendHello", code: Int(errno)) }
    }

    /// 任意の行（`frame` など）を送る。改行はここで付ける。
    func send(line: String) throws {
        try sendRaw(line + "\n")
    }

    /// 改行を付けずに生のバイト列を送る（行の分割到着を再現するため）。
    func sendRaw(_ text: String) throws {
        let bytes = Array(text.utf8)
        let sent = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
        guard sent == bytes.count else { throw NSError(domain: "FakeProducer.send", code: Int(errno)) }
    }

    /// 親から 1 行（`release`）を読む。`timeout` 秒待って来なければ nil。
    func readLine(timeout: TimeInterval = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = inbox.firstIndex(of: 0x0A) {
                let line = String(decoding: inbox[inbox.startIndex..<newline], as: UTF8.self)
                inbox.removeSubrange(inbox.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return nil }
            inbox.append(contentsOf: chunk[0..<n])
        }
    }

    func close() {
        if socket >= 0 {
            Darwin.close(socket)
        }
    }
}

enum FrameIPCFixture {
    /// テストで使う小さな world（64x16、1 行 256 byte、slot は page 境界）。
    static let width = 64
    static let height = 16
    static let bytesPerRow = 256
    static var slotBytes: Int { Int(getpagesize()) }
    static let slots = 3
    static var totalBytes: Int { slotBytes * slots }

    static func helloLine(
        width: Int = width, height: Int = height, bytesPerRow: Int = bytesPerRow,
        slotBytes: Int = slotBytes, slots: Int = slots, protocolVersion: Int = 1
    ) -> String {
        """
        {"t":"hello","protocolVersion":\(protocolVersion),"pid":\(getpid()),"metaphor":"0.11.0",\
        "width":\(width),"height":\(height),"pixelFormat":"bgra8Unorm","alpha":"premultiplied",\
        "colorSpace":"sRGB","orientation":"topLeft","bytesPerRow":\(bytesPerRow),\
        "slotBytes":\(slotBytes),"slots":\(slots),"backing":"posix-shm"}
        """
    }

    static func frameLine(slot: Int, seq: Int) -> String {
        #"{"t":"frame","slot":\#(slot),"seq":\#(seq),"frameCount":\#(seq),"time":\#(Double(seq) / 60)}"#
    }

    /// 一時ディレクトリ直下の短い socket パス（テストごとに別名）。
    static func socketPath() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-test-\(UInt32.random(in: 0...UInt32.max)).sock").path
        guard path.utf8.count <= ViewerSocketPath.maximumLength else {
            throw XCTSkip("temporary directory path is too long for sun_path")
        }
        return path
    }
}

/// listener のイベントを専用キュー上で集め、テストスレッドから待てるようにする。
final class EventRecorder {
    private let lock = NSLock()
    private var events: [FrameIPCListener.Event] = []
    private var waiters: [(predicate: ([FrameIPCListener.Event]) -> Bool, semaphore: DispatchSemaphore)] = []

    func record(_ event: FrameIPCListener.Event) {
        lock.lock()
        events.append(event)
        let snapshot = events
        let ready = waiters.filter { $0.predicate(snapshot) }
        waiters.removeAll { waiter in ready.contains { $0.semaphore === waiter.semaphore } }
        lock.unlock()
        ready.forEach { $0.semaphore.signal() }
    }

    var all: [FrameIPCListener.Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// `predicate` を満たすまで待つ（最大 `timeout` 秒）。満たしたら true。
    @discardableResult
    func wait(timeout: TimeInterval = 3, until predicate: @escaping ([FrameIPCListener.Event]) -> Bool) -> Bool {
        lock.lock()
        if predicate(events) {
            lock.unlock()
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        waiters.append((predicate, semaphore))
        lock.unlock()
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
