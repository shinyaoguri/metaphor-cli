import Darwin
import Foundation
import XCTest
@testable import MetaphorCLICore

/// 親側 socket（``FrameIPCListener``）を、同じプロセスの fake producer で検証する。
/// Metal は使わない。イベントは専用の serial queue で受け、テストスレッドから待つ。
final class FrameIPCListenerTests: XCTestCase {
    private var listener: FrameIPCListener!
    private var recorder: EventRecorder!
    private var queue: DispatchQueue!
    private var path: String!

    override func setUpWithError() throws {
        path = try FrameIPCFixture.socketPath()
        queue = DispatchQueue(label: "FrameIPCListenerTests")
        recorder = EventRecorder()
        listener = try FrameIPCListener(path: path, queue: queue)
        let recorder = self.recorder!
        listener.onEvent = { recorder.record($0) }
    }

    override func tearDown() {
        queue.sync { listener.stop() }
        listener = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop() unlinks the socket file")
    }

    func testHelloArrivesWithTheSharedMemoryDescriptor() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)

        XCTAssertTrue(recorder.wait { events in events.contains { if case .hello = $0 { true } else { false } } })
        guard case .hello(let generation, let hello, let fd)? = recorder.all.last else {
            return XCTFail("expected hello, got \(recorder.all)")
        }
        defer { close(fd) }
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(hello.width, FrameIPCFixture.width)
        XCTAssertNotEqual(fd, shm, "the descriptor is a fresh one in the receiver's table")
        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        XCTAssertEqual(Int(info.st_size), FrameIPCFixture.totalBytes, "fstat sees the producer's ftruncate")
        XCTAssertEqual(recorder.all.first, .connected(generation: 1))
    }

    func testFramesArriveInOrderAndReleasesReachTheProducer() throws {
        let producer = try FakeProducer(path: path)
        let shm = try FakeProducer.makeSharedMemory(bytes: FrameIPCFixture.totalBytes)
        defer { close(shm) }
        try producer.sendHello(FrameIPCFixture.helloLine(), fd: shm)
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        try producer.send(line: FrameIPCFixture.frameLine(slot: 1, seq: 2))

        XCTAssertTrue(recorder.wait { events in
            events.filter { if case .frame = $0 { true } else { false } }.count == 2
        })
        let frames = recorder.all.compactMap { event -> ViewerFrame? in
            if case .frame(_, let frame) = event { return frame } else { return nil }
        }
        XCTAssertEqual(frames.map(\.slot), [0, 1])
        XCTAssertEqual(frames.map(\.seq), [1, 2])
        if case .hello(_, _, let fd)? = recorder.all.first(where: { if case .hello = $0 { true } else { false } }) {
            close(fd)
        }

        queue.sync { listener.send(release: 0) }
        XCTAssertEqual(producer.readLine(), #"{"t":"release","slot":0}"#)
    }

    func testLinesSplitAcrossReceivesAreReassembled() throws {
        let producer = try FakeProducer(path: path)
        let line = FrameIPCFixture.frameLine(slot: 2, seq: 9)
        let cut = line.index(line.startIndex, offsetBy: 10)
        try producer.sendRaw(String(line[..<cut]))
        usleep(50_000)
        try producer.sendRaw(String(line[cut...]) + "\n" + #"{"t":"bye"}"# + "\n")

        XCTAssertTrue(recorder.wait { events in events.contains(.bye(generation: 1)) })
        XCTAssertEqual(
            recorder.all,
            [.connected(generation: 1), .frame(generation: 1, frame: ViewerFrame(slot: 2, seq: 9, frameCount: 9, time: 9.0 / 60)), .bye(generation: 1)]
        )
    }

    func testUnknownLinesAreIgnored() throws {
        let producer = try FakeProducer(path: path)
        try producer.send(line: #"{"t":"dance"}"#)
        try producer.send(line: "garbage")
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        XCTAssertTrue(recorder.wait { events in events.contains { if case .frame = $0 { true } else { false } } })
        XCTAssertEqual(recorder.all.count, 2, "connected + frame; unknown lines produce no events")
    }

    func testHelloWithoutDescriptorIsDroppedWithADiagnostic() throws {
        var diagnostics: [String] = []
        let lock = NSLock()
        listener.onDiagnostic = { message in lock.lock(); diagnostics.append(message); lock.unlock() }
        let producer = try FakeProducer(path: path)
        try producer.send(line: FrameIPCFixture.helloLine())
        try producer.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1))
        XCTAssertTrue(recorder.wait { events in events.contains { if case .frame = $0 { true } else { false } } })
        XCTAssertFalse(recorder.all.contains { if case .hello = $0 { true } else { false } })
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("fd"))
    }

    func testEOFReportsDisconnectionForTheCurrentGeneration() throws {
        let producer = try FakeProducer(path: path)
        XCTAssertTrue(recorder.wait { $0.contains(.connected(generation: 1)) })
        producer.close()
        XCTAssertTrue(recorder.wait { $0.contains(.disconnected(generation: 1)) })
        queue.sync { XCTAssertNil(listener.currentGeneration) }
    }

    func testSecondConnectionStartsANewGenerationAndClosesTheOldOne() throws {
        let first = try FakeProducer(path: path)
        XCTAssertTrue(recorder.wait { $0.contains(.connected(generation: 1)) })

        let second = try FakeProducer(path: path)
        XCTAssertTrue(recorder.wait { $0.contains(.connected(generation: 2)) })
        XCTAssertEqual(
            recorder.all,
            [.connected(generation: 1), .disconnected(generation: 1), .connected(generation: 2)],
            "the old connection is retired before the new generation starts"
        )
        // 旧接続は親が閉じたので、producer 側の read は EOF（nil）になる。
        XCTAssertNil(first.readLine(timeout: 1))
        // release は新世代へ届く。
        queue.sync { listener.send(release: 1) }
        XCTAssertEqual(second.readLine(), #"{"t":"release","slot":1}"#)
        // 旧世代の frame は（閉じられているので）届かない。
        XCTAssertThrowsError(try first.send(line: FrameIPCFixture.frameLine(slot: 0, seq: 1)))
    }

    func testStaleSocketFileIsReplacedOnBind() throws {
        // 前回の異常終了で残った socket ファイルがあっても listen できる。
        let stale = try FrameIPCFixture.socketPath()
        FileManager.default.createFile(atPath: stale, contents: Data())
        let fresh = try FrameIPCListener(path: stale, queue: queue)
        let producer = try FakeProducer(path: stale)
        _ = producer
        queue.sync { fresh.stop() }
    }

    func testRefusesPathsLongerThanSunPath() {
        let long = "/" + String(repeating: "x", count: 120)
        XCTAssertThrowsError(try FrameIPCListener(path: long, queue: queue))
    }
}
