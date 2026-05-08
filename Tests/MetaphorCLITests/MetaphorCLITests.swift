import Foundation
@testable import MetaphorCLICore
import XCTest

final class MetaphorCLITests: XCTestCase {
    func testModuleNameSanitizesProjectName() {
        XCTAssertEqual(NameSanitizer.moduleName(from: "my-sketch"), "MySketch")
        XCTAssertEqual(NameSanitizer.moduleName(from: "123 waves"), "Sketch123Waves")
        XCTAssertEqual(NameSanitizer.moduleName(from: "!!!"), "Sketch")
    }

    func testSemanticVersionComparison() {
        XCTAssertLessThan(SemanticVersion("0.1.0-dev")!, SemanticVersion("0.1.0")!)
        XCTAssertLessThan(SemanticVersion("v0.1.0")!, SemanticVersion("v0.2.0")!)
        XCTAssertLessThan(SemanticVersion("v0.2.0")!, SemanticVersion("v1.0.0")!)
    }

    func testChecksumLookup() {
        let text = """
        111aaa  metaphor-cli_v0.1.0_macos_arm64.tar.gz
        222bbb  other-file.zip
        """
        XCTAssertEqual(
            Checksum.checksum(for: "metaphor-cli_v0.1.0_macos_arm64.tar.gz", in: text),
            "111aaa"
        )
    }

    func testPackageResolvedReaderFindsMetaphorVersion() {
        let data = """
        {
          "pins" : [
            {
              "identity" : "metaphor",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/shinyaoguri/metaphor.git",
              "state" : {
                "revision" : "abc",
                "version" : "0.2.1"
              }
            }
          ],
          "version" : 2
        }
        """.data(using: .utf8)!

        XCTAssertEqual(PackageResolvedReader.metaphorVersion(inResolvedData: data), "0.2.1")
    }

    func testTopLevelHelpListsTemplates() throws {
        let console = BufferedConsole()
        let tool = CommandLineTool(
            console: console,
            processRunner: RecordingProcessRunner(),
            releaseService: StubReleaseService(),
            currentDirectory: temporaryDirectory()
        )

        try tool.run(arguments: ["--help"])

        let help = console.output.joined(separator: "\n")
        XCTAssertTrue(help.contains("Templates:"))
        XCTAssertTrue(help.contains("audio-reactive"))
        XCTAssertTrue(help.contains("raytracing"))
    }

    func testTemplatePackageUsesLocalMetaphorPath() throws {
        let catalog = try TemplateCatalog.loadDefault()
        let template = try XCTUnwrap(catalog.template(named: "2d"))
        let context = TemplateContext(
            projectName: "Demo",
            moduleName: "Demo",
            template: template,
            metaphorDependency: ".package(path: \"/Users/so/Repos/metaphor\")",
            metaphorPackageIdentity: "metaphor"
        )

        let package = try TemplateRenderer.packageSwift(context, catalog: catalog)
        XCTAssertTrue(package.contains(".package(path: \"/Users/so/Repos/metaphor\")"))
        XCTAssertTrue(package.contains(".product(name: \"metaphor\", package: \"metaphor\")"))
    }

    func testAllAppTemplatesRenderProjectNameAndModuleName() throws {
        let catalog = try TemplateCatalog.loadDefault()
        for template in catalog.templates {
            let context = TemplateContext(
                projectName: "Demo",
                moduleName: "Demo",
                template: template,
                metaphorDependency: ".package(path: \"/Users/so/Repos/metaphor\")",
                metaphorPackageIdentity: "metaphor"
            )

            let app = try TemplateRenderer.appSwift(context, catalog: catalog)
            XCTAssertTrue(app.contains("final class Demo"), "Template \(template.id) should render module name")
            XCTAssertFalse(app.contains("\\#("), "Template \(template.id) contains an unrendered raw interpolation")
            XCTAssertFalse(app.contains("\\##("), "Template \(template.id) contains an unrendered raw interpolation")
            XCTAssertFalse(app.contains("{{"), "Template \(template.id) contains an unrendered placeholder")
        }
    }

    func testNewCommandCreatesProjectFiles() throws {
        let root = temporaryDirectory()
        let console = BufferedConsole()
        let runner = RecordingProcessRunner()
        let tool = CommandLineTool(
            console: console,
            processRunner: runner,
            currentDirectory: root
        )

        try tool.run(arguments: [
            "new",
            "MySketch",
            "--template",
            "live",
            "--metaphor-path",
            "/Users/so/Repos/metaphor",
        ])

        let app = root.appendingPathComponent("MySketch/Sources/MySketch/App.swift")
        let package = root.appendingPathComponent("MySketch/Package.swift")
        let preset = root.appendingPathComponent("MySketch/Sources/MySketch/Presets/default.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preset.path))

        let packageContents = try String(contentsOf: package)
        XCTAssertTrue(packageContents.contains(".package(path: \"/Users/so/Repos/metaphor\")"))
    }

    func testUpdateLibraryDryRun() throws {
        let root = temporaryDirectory()
        try """
        // swift-tools-version: 5.10
        import PackageDescription
        let package = Package(
            name: "Demo",
            dependencies: [
                .package(url: "https://github.com/shinyaoguri/metaphor.git", from: "0.2.1")
            ],
            targets: [
                .executableTarget(name: "Demo", dependencies: [.product(name: "metaphor", package: "metaphor")])
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let console = BufferedConsole()
        let tool = CommandLineTool(
            console: console,
            processRunner: RecordingProcessRunner(),
            releaseService: StubReleaseService(),
            currentDirectory: root
        )

        try tool.run(arguments: ["update", "library", "--dry-run"])

        XCTAssertTrue(console.output.contains("Would run: swift package update metaphor"))
    }

    func testUpdateSelfDelegatesToHomebrewWhenInstalledByBrew() throws {
        let console = BufferedConsole()
        let tool = CommandLineTool(
            console: console,
            processRunner: RecordingProcessRunner(),
            releaseService: StubReleaseService(),
            currentDirectory: temporaryDirectory(),
            executablePath: "/opt/homebrew/Cellar/metaphor/0.1.0/bin/metaphor"
        )

        try tool.run(arguments: ["update", "self"])

        XCTAssertTrue(console.output.contains("metaphor-cli appears to be installed by Homebrew."))
        XCTAssertTrue(console.output.contains("Run: brew upgrade metaphor"))
    }

    func testUpdateCheckUsesHomebrewUpgradeHintWhenInstalledByBrew() throws {
        let root = temporaryDirectory()
        let console = BufferedConsole()
        let releases = StubReleaseService()
        releases.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v9.0.0",
            name: "v9.0.0",
            prerelease: false,
            assets: []
        )

        let tool = CommandLineTool(
            console: console,
            processRunner: RecordingProcessRunner(),
            releaseService: releases,
            currentDirectory: root,
            executablePath: "/opt/homebrew/Cellar/metaphor/0.1.0/bin/metaphor"
        )

        try tool.run(arguments: ["update", "check"])

        let output = console.output.joined(separator: "\n")
        XCTAssertTrue(output.contains("[update] metaphor-cli"))
        XCTAssertTrue(output.contains("Run: brew upgrade metaphor"))
        XCTAssertFalse(output.contains("Run: metaphor update self"))
    }

    func testNewCommandRefusesNonEmptyDestinationWithoutForce() throws {
        let root = temporaryDirectory()
        let destination = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "keep".write(to: destination.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let tool = CommandLineTool(
            console: BufferedConsole(),
            processRunner: RecordingProcessRunner(),
            currentDirectory: root
        )

        XCTAssertThrowsError(try tool.run(arguments: ["new", "Existing"])) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError")
                return
            }
            XCTAssertTrue(cliError.message.contains("Destination is not empty"))
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
