import Foundation
@testable import MetaphorCLICore
import XCTest

/// `run` 呼び出しごとにキューから結果を返すランナー（resolver は
/// `--show-bin-path` → `dump-package` の 2 連続呼び出しをする）。
private final class ScriptedProcessRunner: ProcessRunning {
    private var results: [ProcessResult]
    private(set) var invocations: [[String]] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        captureOutput: Bool
    ) throws -> ProcessResult {
        invocations.append(arguments)
        return results.isEmpty ? ProcessResult(exitCode: 1) : results.removeFirst()
    }
}

final class SketchBinaryResolverTests: XCTestCase {

    private var binDir: URL!

    override func setUpWithError() throws {
        binDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: binDir)
    }

    /// `binDir` に実行可能なダミーバイナリを置く。
    private func placeExecutable(named name: String) throws {
        let path = binDir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func resolve(dumpJSON: String) -> String? {
        let runner = ScriptedProcessRunner(results: [
            ProcessResult(exitCode: 0, standardOutput: binDir.path, standardError: ""),
            ProcessResult(exitCode: 0, standardOutput: dumpJSON, standardError: ""),
        ])
        let resolver = SwiftPMBinaryResolver(processRunner: runner)
        return resolver.resolve(directory: URL(fileURLWithPath: "/tmp/sketch"), swiftArguments: [])
    }

    func testResolvesFromExecutableProduct() throws {
        try placeExecutable(named: "MySketch")
        // products の executable は type が辞書形式（{"executable": null}）。
        let json = """
        {"products": [{"name": "MySketch", "type": {"executable": null}}],
         "targets": [{"name": "Other", "type": "executable"}]}
        """
        XCTAssertEqual(resolve(dumpJSON: json), binDir.appendingPathComponent("MySketch").path)
    }

    func testFallsBackToExecutableTargetWhenNoProducts() throws {
        // products 宣言のないパッケージ（executableTarget のみ）は example・
        // テンプレートの標準形。SwiftPM はターゲット名でバイナリを作る。
        try placeExecutable(named: "ProbeSnapshot")
        let json = """
        {"products": [],
         "targets": [{"name": "ProbeSnapshot", "type": "executable"}]}
        """
        XCTAssertEqual(resolve(dumpJSON: json), binDir.appendingPathComponent("ProbeSnapshot").path)
    }

    func testSkipsLibraryTargets() throws {
        try placeExecutable(named: "Exe")
        let json = """
        {"products": [],
         "targets": [{"name": "Lib", "type": "library"},
                     {"name": "Exe", "type": "executable"}]}
        """
        XCTAssertEqual(resolve(dumpJSON: json), binDir.appendingPathComponent("Exe").path)
    }

    func testReturnsNilWhenNoExecutableAnywhere() {
        let json = """
        {"products": [], "targets": [{"name": "Lib", "type": "library"}]}
        """
        XCTAssertNil(resolve(dumpJSON: json))
    }

    func testReturnsNilWhenBinaryMissing() {
        // 解決名は得られてもバイナリ実体が無ければ nil（swift run フォールバック）。
        let json = """
        {"products": [], "targets": [{"name": "Ghost", "type": "executable"}]}
        """
        XCTAssertNil(resolve(dumpJSON: json))
    }

    func testReturnsNilWhenDumpPackageFails() {
        let runner = ScriptedProcessRunner(results: [
            ProcessResult(exitCode: 0, standardOutput: binDir.path, standardError: ""),
            ProcessResult(exitCode: 1),
        ])
        let resolver = SwiftPMBinaryResolver(processRunner: runner)
        XCTAssertNil(resolver.resolve(directory: URL(fileURLWithPath: "/tmp/sketch"), swiftArguments: []))
    }
}
