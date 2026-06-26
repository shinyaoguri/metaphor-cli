import XCTest
@testable import MetaphorCLICore

final class MetaphorDocsLocatorTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locator-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, _ contents: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testResolvesLocalPackagePath() throws {
        let sketch = try makeTempDir()
        let lib = try makeTempDir()
        try touch(lib.appendingPathComponent("llms.txt"))
        try touch(sketch.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.10
        let package = Package(
            name: "X",
            dependencies: [ .package(path: "\(lib.path)") ]
        )
        """)

        let resolved = MetaphorDocsLocator().resolve(sketchDirectory: sketch)
        XCTAssertEqual(resolved?.standardizedFileURL.path, lib.standardizedFileURL.path)
    }

    func testResolvesBuildCheckouts() throws {
        let sketch = try makeTempDir()
        let checkout = sketch.appendingPathComponent(".build/checkouts/metaphor")
        try touch(checkout.appendingPathComponent("llms.txt"))
        // Package.swift は url 依存（path 無し）でも checkouts を拾えること。
        try touch(sketch.appendingPathComponent("Package.swift"), """
        .package(url: "https://github.com/shinyaoguri/metaphor.git", from: "0.1.0")
        """)

        let resolved = MetaphorDocsLocator().resolve(sketchDirectory: sketch)
        XCTAssertEqual(resolved?.standardizedFileURL.path, checkout.standardizedFileURL.path)
    }

    func testReturnsNilWhenNoLLMSTxt() throws {
        let sketch = try makeTempDir()
        let lib = try makeTempDir()  // llms.txt を置かない
        try touch(sketch.appendingPathComponent("Package.swift"), """
        .package(path: "\(lib.path)")
        """)
        XCTAssertNil(MetaphorDocsLocator().resolve(sketchDirectory: sketch))
    }

    func testPackagePathsRegexExtractsAll() {
        let source = """
        dependencies: [
            .package(path: "/a/b/metaphor"),
            .package(url: "https://x", from: "1.0.0"),
            .package(path: "../local"),
        ]
        """
        XCTAssertEqual(MetaphorDocsLocator.packagePaths(in: source), ["/a/b/metaphor", "../local"])
    }
}
