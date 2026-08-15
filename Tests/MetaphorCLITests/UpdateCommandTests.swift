import Foundation
@testable import MetaphorCLICore
import XCTest

/// `metaphor update check` の CLI 行（#122）。
///
/// 実行中ビルドの版は環境依存（`git describe` の結果で変わり、タグを持たない
/// チェックアウトでは短縮 SHA になる）なので版を注入し、(a) 表示にはその版がそのまま
/// 出ること、(b) up-to-date 判定は describe のサフィックスに引きずられないことを固定する。
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

    /// brew で入れた CLI を自前で上書きすると brew の管理と食い違うので、
    /// `metaphor update self` ではなく `brew upgrade` を案内する。
    func testCheckSuggestsHomebrewUpgradeWhenInstalledByBrew() throws {
        let output = try checkOutput(
            currentVersion: "0.8.0",
            isDevelopmentBuild: false,
            latestTag: "v9.0.0",
            executablePath: "/opt/homebrew/Cellar/metaphor/0.1.0/bin/metaphor"
        )

        XCTAssertEqual(output.first, "[update] metaphor-cli 0.8.0 -> v9.0.0")
        XCTAssertTrue(output.contains { $0.contains("Run: brew upgrade metaphor") }, "\(output)")
        XCTAssertFalse(output.contains { $0.contains("metaphor update self") }, "\(output)")
    }

    // MARK: - Helpers

    /// `update check` を走らせて "Checking for updates..." より後の行を返す。
    /// Package.swift の無いディレクトリを渡すので、CLI 行のあとはライブラリ側の
    /// 案内 1 行で終わる（ライブラリのリリース取得には進まない）。
    private func checkOutput(
        currentVersion: String,
        isDevelopmentBuild: Bool,
        latestTag: String,
        executablePath: String? = nil
    ) throws -> [String] {
        let directory = temporaryDirectory()
        let console = BufferedConsole()
        let releases = StubReleaseService()
        releases.releases["\(BuildInfo.cliRepositoryOwner)/\(BuildInfo.cliRepositoryName)"] = GitHubRelease(
            tagName: latestTag,
            name: latestTag,
            prerelease: false,
            assets: []
        )

        try UpdateCommand(
            console: console,
            processRunner: UnusedProcessRunner(),
            releaseService: releases,
            currentDirectory: directory,
            // 既定はテスト用の一時パス。実在の metaphor を PATH から拾って
            // brew 判定が環境で揺れるのを避ける。
            executablePath: executablePath ?? directory.appendingPathComponent("metaphor").path,
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
