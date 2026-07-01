import XCTest
@testable import MetaphorCLICore

// MARK: - Wire-schema conformance (consumer side)
//
// contract/request.schema.json が request.json wire 形式の正典 (案C+、ADR-0004)。
// consumer(cli) は request.json を JSONSerialization + [String: Any] で手組みするため、
// 型共有ではコンパイル時保証が付かない。ここでは MCP ツールが実際に書いた request.json を
// スキーマで検証することで、**consumer 出力 ⊨ schema** を直接押さえる（型共有との決定的差）。
//
// スキーマ検証は check-jsonschema (Python) に shell out する（Swift ネイティブ validator は
// 貧弱。設計ノート §5.1）。CI は check-contract-schema.sh の前段で check-jsonschema を
// インストール済みなので実際に走る。ローカルで未インストールなら XCTSkip する。
final class ProbeRequestSchemaTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-schema-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// リポジトリルート（#filePath = <repo>/Tests/MetaphorCLITests/ProbeRequestSchemaTests.swift）。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaphorCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private var requestSchema: URL {
        repoRoot.appendingPathComponent("contract/request.schema.json")
    }

    /// check-jsonschema で `json` が `schema` に適合するか検証する。
    /// バイナリが PATH に無ければ nil を返す（呼び出し側で XCTSkip）。
    private func validate(_ json: URL, against schema: URL) throws -> (ok: Bool, output: String)? {
        let launch = URL(fileURLWithPath: "/usr/bin/env")
        let process = Process()
        process.executableURL = launch
        process.arguments = ["check-jsonschema", "--schemafile", schema.path, json.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil  // /usr/bin/env 起動失敗（想定外）
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // env は対象コマンドが見つからないと 127 を返す。
        if process.terminationStatus == 127 || output.contains("No such file or directory") {
            return nil
        }
        return (process.terminationStatus == 0, output)
    }

    func testSnapshotRequestConformsToSchema() throws {
        let dir = try makeTempDir()
        // 短いタイムアウト: snapshot は request.json を書いてから待つため、
        // タイムアウトしても request.json は残る。
        let tool = ProbeSnapshotTool(sketchDirectory: dir, timeout: 0.2)
        _ = tool.snapshot(label: "baseline")

        let request = dir.appendingPathComponent(".metaphor/probe/request.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path), "request.json が書かれていない")

        guard let result = try validate(request, against: requestSchema) else {
            throw XCTSkip("check-jsonschema が見つからないためスキップ（CI では実行される）")
        }
        XCTAssertTrue(result.ok, "snapshot の request.json が request.schema.json に非適合:\n\(result.output)")
    }

    func testSequenceRequestConformsToSchema() throws {
        let dir = try makeTempDir()
        let tool = ProbeSequenceTool(sketchDirectory: dir, timeout: 0.2)
        _ = tool.captureSequence(label: "motion", frames: 8, every: 2)

        let request = dir.appendingPathComponent(".metaphor/probe/request.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path), "request.json が書かれていない")

        guard let result = try validate(request, against: requestSchema) else {
            throw XCTSkip("check-jsonschema が見つからないためスキップ（CI では実行される）")
        }
        XCTAssertTrue(result.ok, "capture_sequence の request.json が request.schema.json に非適合:\n\(result.output)")
    }
}
