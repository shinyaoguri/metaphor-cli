import Foundation
@testable import MetaphorCLICore
import XCTest

/// `metaphor version` / `metaphor doctor` が出す「環境の版一覧」（#120）。
/// CLI 行の版そのものはビルド環境依存なので、ここで固定するのは
/// **形（ラベル・桁揃え・ライブラリ行の 3 分岐・JSON のキー）**に絞る。
final class VersionCommandTests: XCTestCase {
    func testVersionReportsResolvedLibraryVersion() throws {
        let directory = try sketchDirectory(resolvedVersion: "0.9.0")
        let console = BufferedConsole()

        try VersionCommand(console: console, currentDirectory: directory).run(arguments: [])

        XCTAssertEqual(console.output.count, 2, "version should print exactly the CLI line and the library line")
        XCTAssertTrue(
            console.output[0].hasPrefix("metaphor-cli "),
            "CLI line should name itself metaphor-cli, not metaphor: \(console.output[0])"
        )
        XCTAssertEqual(console.output[1], "metaphor     0.9.0 (Package.resolved)")
    }

    func testVersionReportsLocalPathDependency() throws {
        let directory = temporaryDirectory()
        try """
        // swift-tools-version: 5.10
        import PackageDescription

        let package = Package(
            name: "Demo",
            dependencies: [
                .package(path: "../metaphor"),
            ]
        )
        """.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let console = BufferedConsole()

        try VersionCommand(console: console, currentDirectory: directory).run(arguments: [])

        XCTAssertEqual(console.output[1], "metaphor     local path ../metaphor")
    }

    func testVersionSaysWhereItLooksWhenLibraryIsUnresolved() throws {
        let console = BufferedConsole()

        try VersionCommand(console: console, currentDirectory: temporaryDirectory()).run(arguments: [])

        XCTAssertTrue(
            console.output[1].contains("(not resolved here"),
            "an unresolved library should say so rather than print a bare label: \(console.output[1])"
        )
    }

    /// 桁が揃っていないと 2 行の対応が読めない。ラベル幅の変更を検知する。
    func testVersionLinesAlignVersionColumn() throws {
        let console = BufferedConsole()

        try VersionCommand(
            console: console,
            currentDirectory: try sketchDirectory(resolvedVersion: "0.9.0")
        ).run(arguments: [])

        // 各行で「値が始まる桁」を求め、2 行で一致することを見る。
        let valueColumns = console.output.map { line -> Int in
            let labelEnd = line.firstIndex(of: " ") ?? line.endIndex
            let valueStart = line[labelEnd...].firstIndex { $0 != " " } ?? line.endIndex
            return line.distance(from: line.startIndex, to: valueStart)
        }
        XCTAssertEqual(
            valueColumns.first, valueColumns.last,
            "the two lines should line their values up in the same column: \(console.output)"
        )
    }

    func testVersionJSONExposesStableKeys() throws {
        let console = BufferedConsole()

        try VersionCommand(
            console: console,
            currentDirectory: try sketchDirectory(resolvedVersion: "0.9.0")
        ).run(arguments: ["--json"])

        let json = try jsonObject(from: console)
        let cli = try XCTUnwrap(json["cli"] as? [String: Any])
        XCTAssertEqual(cli["name"] as? String, "metaphor-cli")
        XCTAssertNotNil(cli["version"] as? String)
        XCTAssertNotNil(cli["built"] as? String)

        let library = try XCTUnwrap(json["library"] as? [String: Any])
        XCTAssertEqual(library["name"] as? String, "metaphor")
        XCTAssertEqual(library["source"] as? String, "package-resolved")
        XCTAssertEqual(library["version"] as? String, "0.9.0")
        XCTAssertTrue(library["path"] is NSNull, "path should be present as null, not missing")
    }

    /// 未解決でもキーは欠けない（消費者がキーの有無で分岐せずに済むように）。
    func testVersionJSONKeepsKeysWhenUnresolved() throws {
        let console = BufferedConsole()

        try VersionCommand(console: console, currentDirectory: temporaryDirectory())
            .run(arguments: ["--json"])

        let library = try XCTUnwrap(try jsonObject(from: console)["library"] as? [String: Any])
        XCTAssertEqual(library["source"] as? String, "unresolved")
        XCTAssertTrue(library["version"] is NSNull)
        XCTAssertTrue(library["path"] is NSNull)
    }

    func testVersionJSONReportsLocalPathSource() throws {
        let directory = temporaryDirectory()
        try """
        .package(path: "../metaphor"),
        """.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let console = BufferedConsole()

        try VersionCommand(console: console, currentDirectory: directory).run(arguments: ["--json"])

        let library = try XCTUnwrap(try jsonObject(from: console)["library"] as? [String: Any])
        XCTAssertEqual(library["source"] as? String, "local-path")
        XCTAssertEqual(library["path"] as? String, "../metaphor")
        XCTAssertTrue(library["version"] is NSNull)
    }

    func testDoctorPrintsTheSameVersionLines() throws {
        let directory = try sketchDirectory(resolvedVersion: "0.9.0")

        let versionConsole = BufferedConsole()
        try VersionCommand(console: versionConsole, currentDirectory: directory).run(arguments: [])

        let doctorConsole = BufferedConsole()
        try DoctorCommand(
            console: doctorConsole,
            processRunner: RecordingProcessRunner(),
            currentDirectory: directory,
            loadedImagePaths: { [] }
        ).run(arguments: [])

        XCTAssertEqual(
            Array(doctorConsole.output.dropFirst().prefix(2)),
            versionConsole.output,
            "doctor should reuse the exact lines `metaphor version` prints"
        )
    }

    // MARK: - Helpers

    private func jsonObject(from console: BufferedConsole) throws -> [String: Any] {
        let text = console.output.joined(separator: "\n")
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sketchDirectory(resolvedVersion: String) throws -> URL {
        let directory = temporaryDirectory()
        try """
        {
          "pins" : [
            {
              "identity" : "metaphor",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/shinyaoguri/metaphor.git",
              "state" : {
                "revision" : "abc",
                "version" : "\(resolvedVersion)"
              }
            }
          ],
          "version" : 2
        }
        """.write(to: directory.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        return directory
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
