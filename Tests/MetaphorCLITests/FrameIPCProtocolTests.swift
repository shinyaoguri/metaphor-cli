import Foundation
import XCTest
@testable import MetaphorCLICore

/// frame IPC（CONTRACT.md 契約点 5）の wire format の読み書き。
/// JSON の構造は `contract/viewer-*.schema.json` が正典で、ここは consumer 側の解釈を固定する。
final class FrameIPCProtocolTests: XCTestCase {
    static let helloLine = """
    {"t":"hello","protocolVersion":1,"pid":4242,"metaphor":"0.11.0","width":1920,"height":1080,\
    "pixelFormat":"bgra8Unorm","alpha":"premultiplied","colorSpace":"sRGB","orientation":"topLeft",\
    "bytesPerRow":7680,"slotBytes":8306688,"slots":3,"backing":"posix-shm"}
    """

    func testDecodesHello() throws {
        guard case .hello(let hello)? = FrameIPC.decode(line: Self.helloLine) else {
            return XCTFail("hello should decode")
        }
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertEqual(hello.pid, 4242)
        XCTAssertEqual(hello.metaphor, "0.11.0")
        XCTAssertEqual(hello.width, 1920)
        XCTAssertEqual(hello.height, 1080)
        XCTAssertEqual(hello.bytesPerRow, 7680)
        XCTAssertEqual(hello.slotBytes, 8_306_688)
        XCTAssertEqual(hello.slots, 3)
        XCTAssertEqual(hello.totalBytes, 8_306_688 * 3)
        XCTAssertNil(hello.unsupportedReason)
    }

    func testDecodesFrameWithOptionalFields() {
        XCTAssertEqual(
            FrameIPC.decode(line: #"{"t":"frame","slot":2,"seq":17,"frameCount":120,"time":2.0}"#),
            .frame(ViewerFrame(slot: 2, seq: 17, frameCount: 120, time: 2.0))
        )
        XCTAssertEqual(
            FrameIPC.decode(line: #"{"t":"frame","slot":0,"seq":1}"#),
            .frame(ViewerFrame(slot: 0, seq: 1)),
            "frameCount / time are optional"
        )
    }

    func testDecodesBye() {
        XCTAssertEqual(FrameIPC.decode(line: #"{"t":"bye"}"#), .bye)
    }

    func testIgnoresUnknownTagsAndGarbage() {
        XCTAssertNil(FrameIPC.decode(line: #"{"t":"dance","slot":1}"#), "unknown t is ignored (contract point 3 leniency)")
        XCTAssertNil(FrameIPC.decode(line: "not json"))
        XCTAssertNil(FrameIPC.decode(line: ""))
        XCTAssertNil(FrameIPC.decode(line: #"{"t":"frame","seq":1}"#), "frame without slot is dropped")
    }

    func testUnknownKeysAreIgnored() {
        let line = #"{"t":"frame","slot":1,"seq":2,"futureKey":{"nested":true}}"#
        XCTAssertEqual(FrameIPC.decode(line: line), .frame(ViewerFrame(slot: 1, seq: 2)))
    }

    func testReleaseLine() {
        XCTAssertEqual(FrameIPC.releaseLine(slot: 2), #"{"t":"release","slot":2}"#)
        XCTAssertFalse(FrameIPC.releaseLine(slot: 0).contains("\n"), "caller appends the newline")
    }

    func testHelloRejectsWorldsThisViewerCannotMap() throws {
        func hello(_ mutate: (inout [String: Any]) -> Void) throws -> ViewerHello {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(Self.helloLine.utf8)) as? [String: Any]
            )
            mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ViewerHello.self, from: data)
        }
        XCTAssertNotNil(try hello { $0["protocolVersion"] = 2 }.unsupportedReason)
        XCTAssertNotNil(try hello { $0["backing"] = "iosurface-xpc" }.unsupportedReason)
        XCTAssertNotNil(try hello { $0["pixelFormat"] = "rgba16Float" }.unsupportedReason)
        XCTAssertNotNil(try hello { $0["bytesPerRow"] = 100 }.unsupportedReason, "bytesPerRow < width*4")
        XCTAssertNotNil(try hello { $0["slotBytes"] = 4096 }.unsupportedReason, "slotBytes < bytesPerRow*height")
        XCTAssertNotNil(try hello { $0["width"] = 0 }.unsupportedReason)
        XCTAssertNil(try hello { $0["colorSpace"] = "displayP3" }.unsupportedReason, "colorSpace vocabulary is not a mapping concern")
    }

    // MARK: - Socket path

    func testSocketPathLivesInTemporaryDirectoryAndNamesThePid() throws {
        let directory = URL(fileURLWithPath: "/tmp/t")
        let path = try XCTUnwrap(ViewerSocketPath.make(pid: 1234, directory: directory))
        XCTAssertEqual(path, "/tmp/t/metaphor-viewer-1234.sock")
    }

    func testSocketPathRefusesToExceedSunPathLimit() {
        XCTAssertEqual(ViewerSocketPath.maximumLength, 103, "macOS sun_path is 104 bytes including the NUL")
        let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 90))
        XCTAssertNil(ViewerSocketPath.make(pid: 1, directory: long))
        let justFits = URL(fileURLWithPath: "/" + String(repeating: "d", count: 103 - "/metaphor-viewer-1.sock".utf8.count - 1))
        XCTAssertNotNil(ViewerSocketPath.make(pid: 1, directory: justFits))
    }
}
