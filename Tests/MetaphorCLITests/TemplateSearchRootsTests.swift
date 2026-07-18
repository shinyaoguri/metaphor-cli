import Foundation
@testable import MetaphorCLICore
import XCTest

/// テンプレート検索順の回帰テスト（#69）。
/// 「実行中のバイナリに隣接する share/」が、旧インストール方式の残骸が残りうる
/// レガシー固定パスより先に来ることを守る。
final class TemplateSearchRootsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")
    private let cwd = URL(fileURLWithPath: "/Users/tester/work")

    private func roots(
        environment: [String: String] = [:],
        argv0: String?,
        executableURL: URL?
    ) -> [String] {
        TemplateCatalog.searchRoots(
            environment: environment,
            argv0: argv0,
            executableURL: executableURL,
            currentDirectory: cwd,
            home: home
        ).map(\.path)
    }

    func testBrewBinaryAdjacentShareBeatsInstallerLeftovers() throws {
        // brew: argv0 は /opt/homebrew/bin の symlink、実体は Cellar の keg。
        let paths = roots(
            argv0: "/opt/homebrew/bin/metaphor",
            executableURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/metaphor/0.3.0/bin/metaphor")
        )

        let brewShare = try XCTUnwrap(paths.firstIndex(of: "/opt/homebrew/share/metaphor/templates"))
        let kegShare = try XCTUnwrap(paths.firstIndex(of: "/opt/homebrew/Cellar/metaphor/0.3.0/share/metaphor/templates"))
        let installerLeftover = try XCTUnwrap(paths.firstIndex(of: "/Users/tester/.local/share/metaphor/templates"))

        XCTAssertLessThan(brewShare, installerLeftover, "binary-adjacent share must beat installer leftovers (#69)")
        XCTAssertLessThan(kegShare, installerLeftover)
    }

    func testDirectInstallerSymlinkFindsItsOwnShareFirst() {
        // direct installer: ~/.local/bin/metaphor は ~/.local/libexec/metaphor/metaphor への symlink。
        let paths = roots(
            argv0: "/Users/tester/.local/bin/metaphor",
            executableURL: URL(fileURLWithPath: "/Users/tester/.local/libexec/metaphor/metaphor")
        )

        XCTAssertEqual(paths.first, "/Users/tester/.local/share/metaphor/templates")
    }

    func testEnvironmentOverrideComesFirst() {
        let paths = roots(
            environment: ["METAPHOR_TEMPLATES_PATH": "/tmp/custom-templates"],
            argv0: "/opt/homebrew/bin/metaphor",
            executableURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/metaphor/0.3.0/bin/metaphor")
        )

        XCTAssertEqual(paths.first, "/tmp/custom-templates")
    }

    func testBareArgv0WithoutSlashContributesNoRoot() {
        // PATH 経由でない特殊起動では argv0 が裸のコマンド名になりうる。
        // 位置情報を持たないので cwd 由来の share を捏造しないこと
        // （"metaphor" を cwd 相対で解決すると /Users/tester/work/metaphor →
        // 親の親 + share で /Users/tester/share/… が湧いてしまう）。
        let paths = roots(argv0: "metaphor", executableURL: nil)

        XCTAssertFalse(paths.contains("/Users/tester/share/metaphor/templates"))
    }

    func testDuplicateRootsAreListedOnce() {
        // argv0 と解決済み実体が同じ prefix を指すときに重複しない。
        let paths = roots(
            argv0: "/usr/local/bin/metaphor",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/metaphor")
        )

        XCTAssertEqual(paths.filter { $0 == "/usr/local/share/metaphor/templates" }.count, 1)
    }

    func testLoadFirstPicksFirstRootContainingManifest() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        let missing = base.appendingPathComponent("missing")
        let winner = base.appendingPathComponent("winner")
        let shadowed = base.appendingPathComponent("shadowed")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        for (root, id) in [(winner, "winner"), (shadowed, "shadowed")] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let manifest = """
            {"commonFiles": [], "templates": [{"id": "\(id)", "title": "\(id)", "summary": "\(id)", "files": []}]}
            """
            try manifest.write(to: root.appendingPathComponent("templates.json"), atomically: true, encoding: .utf8)
        }

        let catalog = try TemplateCatalog.loadFirst(
            from: [missing, winner, shadowed],
            fileManager: .default
        )

        XCTAssertEqual(catalog.root.path, winner.path)
        XCTAssertEqual(catalog.templates.map(\.id), ["winner"])
    }
}
