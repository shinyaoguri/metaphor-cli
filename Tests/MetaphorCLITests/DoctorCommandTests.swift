import Foundation
@testable import MetaphorCLICore
import XCTest

/// `metaphor doctor` の編集環境チェック（#148）。
///
/// `.vscode/` を同梱しても補完が出ないという実測問題（Swift 拡張の不在 /
/// 背景インデックス / 未ビルド）を doctor で切り分けられるようにしたので、
/// 「どの状態でどの行が出るか」をここで固定する。ホーム・カレントとも注入して
/// いるので、実行マシンに VSCode が入っているかどうかに結果は左右されない。
final class DoctorCommandTests: XCTestCase {
    // MARK: - Swift 拡張

    func testReportsInstalledSwiftExtensionWithVersion() throws {
        let home = temporaryDirectory()
        makeExtension(in: home, named: "swiftlang.swift-vscode-2.10.0")

        let output = try runDoctor(home: home)

        XCTAssertTrue(
            output.contains("[ok] VSCode Swift extension: swiftlang.swift-vscode 2.10.0"),
            output
        )
    }

    func testReportsInstalledSwiftExtensionWithoutVersionSuffix() throws {
        let home = temporaryDirectory()
        makeExtension(in: home, named: "swiftlang.swift-vscode")

        let output = try runDoctor(home: home)

        XCTAssertTrue(output.contains("[ok] VSCode Swift extension: swiftlang.swift-vscode\n"), output)
    }

    /// 版が複数残っているマシン（更新の残骸）では、新しい方を名乗る。
    func testPicksTheHighestInstalledExtensionVersion() throws {
        let home = temporaryDirectory()
        makeExtension(in: home, named: "swiftlang.swift-vscode-2.9.0")
        makeExtension(in: home, named: "swiftlang.swift-vscode-2.10.1")

        let output = try runDoctor(home: home)

        XCTAssertTrue(output.contains("swiftlang.swift-vscode 2.10.1"), output)
    }

    func testWarnsWhenSwiftExtensionIsMissingButVSCodeIsInstalled() throws {
        let home = temporaryDirectory()
        makeExtension(in: home, named: "vscodevim.vim-1.27.0")

        let output = try runDoctor(home: home)

        XCTAssertTrue(output.contains("[warn] VSCode Swift extension not installed"), output)
        XCTAssertTrue(output.contains("install swiftlang.swift-vscode"), output)
    }

    /// VSCode を使っていないマシンでは欠落ではないので、警告に格上げしない。
    func testReportsInfoWhenVSCodeIsNotInstalled() throws {
        let output = try runDoctor(home: temporaryDirectory())

        XCTAssertTrue(output.contains("[info] VSCode not detected"), output)
        XCTAssertFalse(output.contains("[warn] VSCode Swift extension"), output)
    }

    // MARK: - .sourcekit-lsp/config.json

    func testReportsDisabledBackgroundIndexing() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": false}"#)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[ok] .sourcekit-lsp/config.json: backgroundIndexing disabled"), output)
    }

    func testWarnsWhenBackgroundIndexingIsEnabled() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": true}"#)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] .sourcekit-lsp/config.json: backgroundIndexing is not disabled"), output)
    }

    /// sourcekit-lsp の既定は `auto`（Swift 6.1+ で有効）なので、
    /// キーが無いのは「切れている」ではなく「踏む」側。
    func testWarnsWhenBackgroundIndexingKeyIsAbsent() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"defaultWorkspaceType": "swiftPM"}"#)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] .sourcekit-lsp/config.json: backgroundIndexing is not disabled"), output)
    }

    func testWarnsWhenSourcekitLSPConfigIsBrokenJSON() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: "{ not json")

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] .sourcekit-lsp/config.json unreadable"), output)
    }

    /// 古い版で生成したプロジェクトには config ごと無い。
    func testWarnsWhenSourcekitLSPConfigIsMissing() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: nil)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] .sourcekit-lsp/config.json not found"), output)
    }

    // MARK: - .build

    func testWarnsWhenSketchHasNotBeenBuilt() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": false}"#)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] Sketch not built yet (.build/debug not found)"), output)
    }

    /// `metaphor new` は生成時に `swift package resolve` まで走らせるので、
    /// 一度もビルドしていないスケッチにも `.build/`（checkouts・artifacts）はある。
    /// ここを `.build` の有無で見ていると、未ビルドがすべて `[ok]` に化ける。
    func testWarnsWhenOnlyDependenciesHaveBeenResolved() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": false}"#)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".build/checkouts/metaphor"),
            withIntermediateDirectories: true
        )

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[warn] Sketch not built yet"), output)
    }

    func testReportsBuildProducts() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": false}"#, built: true)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[ok] Build products found"), output)
    }

    /// SwiftPM が張る `.build/debug` は `.build/<triple>/debug` へのシンボリックリンク。
    func testFollowsTheBuildDebugSymlink() throws {
        let project = temporaryDirectory()
        makeSketch(at: project, sourcekitLSPConfig: #"{"backgroundIndexing": false}"#)
        let real = project.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".build/debug"),
            withDestinationURL: real
        )

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[ok] Build products found"), output)
    }

    // MARK: - スケッチ外

    /// スケッチ外（Package.swift が無い）では、プロジェクト側の 2 項目は
    /// 無関係な警告になるので出さない。拡張の在否はマシンの話なので出す。
    func testSkipsProjectChecksOutsideASketch() throws {
        let home = temporaryDirectory()
        makeExtension(in: home, named: "swiftlang.swift-vscode-2.10.0")

        let output = try runDoctor(currentDirectory: temporaryDirectory(), home: home)

        XCTAssertTrue(output.contains("[warn] Package.swift not found"), output)
        XCTAssertFalse(output.contains(".sourcekit-lsp/config.json"), output)
        // テンプレートの配置先が `.build` 配下のことがあるので、`.build` の
        // 素の出現ではなく、この検査が出す文言そのもので見る。
        XCTAssertFalse(output.contains("Sketch not built yet"), output)
        XCTAssertFalse(output.contains("[ok] Build products found"), output)
        XCTAssertTrue(output.contains("[ok] VSCode Swift extension"), output)
    }

    /// metaphor-cli 自身のように、スケッチではない Swift パッケージの中で
    /// doctor を打っても、スケッチ向けの警告は出さない。
    func testSkipsProjectChecksInAPackageThatDoesNotDependOnMetaphor() throws {
        let project = temporaryDirectory()
        makePackage(at: project, dependency: #".package(url: "https://github.com/apple/swift-log", from: "1.0.0"),"#)

        let output = try runDoctor(currentDirectory: project)

        XCTAssertTrue(output.contains("[ok] Package.swift found"), output)
        XCTAssertFalse(output.contains(".sourcekit-lsp/config.json"), output)
        XCTAssertFalse(output.contains("Sketch not built yet"), output)
        XCTAssertFalse(output.contains("[ok] Build products found"), output)
    }

    // MARK: - テンプレートとの二重管理ガード

    /// doctor が探す拡張 ID と、生成物が推奨する拡張 ID がずれると、
    /// 「推奨どおり入れたのに doctor が warn を出す」ことになる。
    func testRecommendedExtensionIDMatchesTheTemplate() throws {
        let template = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // MetaphorCLITests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリルート
                .appendingPathComponent("Templates/common/vscode-extensions.json.template"),
            encoding: .utf8
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(template.data(using: .utf8))) as? [String: Any]
        )
        let recommendations = try XCTUnwrap(json["recommendations"] as? [String])

        XCTAssertTrue(
            recommendations.contains(VSCodeEnvironment.swiftExtensionID),
            "テンプレートの推奨拡張と doctor が探す拡張 ID は一致していること: \(recommendations)"
        )
    }

    // MARK: - Helpers

    private func runDoctor(
        currentDirectory: URL? = nil,
        home: URL? = nil
    ) throws -> String {
        let console = BufferedConsole()
        try DoctorCommand(
            console: console,
            processRunner: RecordingProcessRunner(),
            currentDirectory: currentDirectory ?? temporaryDirectory(),
            home: home ?? temporaryDirectory()
        ).run(arguments: [])
        return console.output.joined(separator: "\n") + "\n"
    }

    private func makeExtension(in home: URL, named name: String) {
        let directory = home
            .appendingPathComponent(".vscode", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeSketch(at root: URL, sourcekitLSPConfig: String?, built: Bool = false) {
        makePackage(at: root, dependency: #".package(url: "https://github.com/shinyaoguri/metaphor", from: "0.9.0"),"#)
        if let sourcekitLSPConfig {
            let directory = root.appendingPathComponent(".sourcekit-lsp", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("config.json").path,
                contents: Data(sourcekitLSPConfig.utf8)
            )
        }
        if built {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(".build/debug", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func makePackage(at root: URL, dependency: String) {
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: Data("""
            // swift-tools-version:6.0
            import PackageDescription

            let package = Package(
                name: "Demo",
                dependencies: [
                    \(dependency)
                ]
            )
            """.utf8)
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-doctor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
