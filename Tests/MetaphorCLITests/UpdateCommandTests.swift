import Foundation
@testable import MetaphorCLICore
import XCTest

/// `metaphor update check` の CLI 行（#122）。
///
/// 実行中ビルドの版は環境依存なので版を注入し、(a) 表示にはその版がそのまま出ること、
/// (b) up-to-date 判定は `git describe` のサフィックスに引きずられないことを固定する。
final class UpdateCommandTests: XCTestCase {
    func testCheckReportsDevelopmentBuildAheadOfLatestRelease() throws {
        let output = try checkOutput(currentVersion: "0.9.0-3-gabc1234", isDevelopmentBuild: true, latestTag: "v0.9.0")

        XCTAssertEqual(
            output.first,
            "[info] metaphor-cli 0.9.0-3-gabc1234 is a development build (latest release: v0.9.0)"
        )
        XCTAssertFalse(
            output.contains { $0.hasPrefix("[update]") },
            "リリースより進んだ開発ビルドに更新を促してはいけない: \(output)"
        )
    }

    func testCheckReportsAvailableUpdateWithTheRunningVersion() throws {
        let output = try checkOutput(currentVersion: "0.8.0", isDevelopmentBuild: false, latestTag: "v0.9.0")

        XCTAssertEqual(output.first, "[update] metaphor-cli 0.8.0 -> v0.9.0")
    }

    func testCheckReportsUpToDateWithTheRunningVersion() throws {
        let output = try checkOutput(currentVersion: "0.9.0", isDevelopmentBuild: false, latestTag: "v0.9.0")

        XCTAssertEqual(output.first, "[ok] metaphor-cli is up to date (0.9.0)")
    }

    // MARK: - Helpers

    /// `update check` を走らせて "Checking for updates..." より後の行を返す。
    /// Package.swift の無いディレクトリを渡すので、CLI 行のあとはライブラリ側の
    /// 案内 1 行で終わる（ライブラリのリリース取得には進まない）。
    private func checkOutput(currentVersion: String, isDevelopmentBuild: Bool, latestTag: String) throws -> [String] {
        let directory = temporaryDirectory()
        let console = BufferedConsole()

        try UpdateCommand(
            console: console,
            processRunner: UnusedProcessRunner(),
            releaseService: StubReleaseService(tagName: latestTag),
            currentDirectory: directory,
            executablePath: directory.appendingPathComponent("metaphor").path,
            currentVersion: currentVersion,
            isDevelopmentBuild: isDevelopmentBuild
        ).run(arguments: ["check"])

        return Array(console.output.dropFirst())
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-update-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct StubReleaseService: ReleaseServicing {
    let tagName: String

    func latestRelease(owner: String, repo: String) throws -> GitHubRelease {
        let json = """
        {"tag_name":"\(tagName)","name":"Release","prerelease":false,"assets":[]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(GitHubRelease.self, from: json)
    }

    func download(from url: URL) throws -> Data {
        throw CLIError("update check should not download anything")
    }
}

private struct UnusedProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        captureOutput: Bool
    ) throws -> ProcessResult {
        throw CLIError("update check should not run a subprocess")
    }
}
