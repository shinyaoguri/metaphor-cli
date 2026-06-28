import Darwin
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
        try withSourceTemplates {
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
    }

    func testTemplatePackageUsesLocalMetaphorPath() throws {
        try withSourceTemplates {
            let catalog = try TemplateCatalog.loadDefault()
            let template = try XCTUnwrap(catalog.template(named: "2d"))
            let context = TemplateContext(
                projectName: "Demo",
                moduleName: "Demo",
                template: template,
                metaphorDependency: ".package(path: \"/Users/so/Repos/metaphor\")",
                metaphorPackageIdentity: "metaphor",
                metaphorAIDocsPath: "/Users/so/Repos/metaphor"
            )

            let package = try TemplateRenderer.packageSwift(context, catalog: catalog)
            XCTAssertTrue(package.contains(".package(path: \"/Users/so/Repos/metaphor\")"))
            XCTAssertTrue(package.contains(".product(name: \"metaphor\", package: \"metaphor\")"))
        }
    }

    func testAllAppTemplatesRenderProjectNameAndModuleName() throws {
        try withSourceTemplates {
            let catalog = try TemplateCatalog.loadDefault()
            for template in catalog.templates {
                let context = TemplateContext(
                    projectName: "Demo",
                    moduleName: "Demo",
                    template: template,
                    metaphorDependency: ".package(path: \"/Users/so/Repos/metaphor\")",
                    metaphorPackageIdentity: "metaphor",
                    metaphorAIDocsPath: "/Users/so/Repos/metaphor"
                )

                let app = try TemplateRenderer.appSwift(context, catalog: catalog)
                XCTAssertTrue(app.contains("final class Demo"), "Template \(template.id) should render module name")
                XCTAssertFalse(app.contains("\\#("), "Template \(template.id) contains an unrendered raw interpolation")
                XCTAssertFalse(app.contains("\\##("), "Template \(template.id) contains an unrendered raw interpolation")
                XCTAssertFalse(app.contains("{{"), "Template \(template.id) contains an unrendered placeholder")
            }
        }
    }

    func testNewCommandCreatesProjectFiles() throws {
        try withSourceTemplates {
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
            let agents = root.appendingPathComponent("MySketch/AGENTS.md")
            let brief = root.appendingPathComponent("MySketch/PROJECT_BRIEF.md")
            let preset = root.appendingPathComponent("MySketch/Sources/MySketch/Presets/default.json")

            XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: agents.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: brief.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: preset.path))

            let packageContents = try String(contentsOf: package)
            XCTAssertTrue(packageContents.contains(".package(path: \"/Users/so/Repos/metaphor\")"))

            let agentsContents = try String(contentsOf: agents)
            XCTAssertTrue(agentsContents.contains("Sources/MySketch/App.swift"))
            XCTAssertFalse(agentsContents.contains("{{"))

            let briefContents = try String(contentsOf: brief)
            XCTAssertTrue(briefContents.contains("# MySketch Brief"))
            XCTAssertFalse(briefContents.contains("{{"))
        }
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

    func testRunForwardsExplicitSyphonNameAsEnv() throws {
        let runner = RecordingProcessRunner()
        let cmd = RunCommand(
            console: BufferedConsole(),
            processRunner: runner,
            currentDirectory: temporaryDirectory()
        )

        try cmd.run(arguments: ["--syphon=MySketch", "--", "extra"])

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.arguments, ["METAPHOR_SYPHON_NAME=MySketch", "swift", "run", "--", "extra"])
    }

    func testRunBareSyphonUsesDirectoryName() throws {
        let sketchDir = temporaryDirectory().appendingPathComponent("WaveField")
        try FileManager.default.createDirectory(at: sketchDir, withIntermediateDirectories: true)
        let runner = RecordingProcessRunner()
        let cmd = RunCommand(console: BufferedConsole(), processRunner: runner, currentDirectory: sketchDir)

        try cmd.run(arguments: ["--syphon"])

        XCTAssertEqual(runner.invocations.first?.arguments, ["METAPHOR_SYPHON_NAME=WaveField", "swift", "run"])
    }

    func testRunWithoutSyphonForwardsArgumentsUnchanged() throws {
        let runner = RecordingProcessRunner()
        let cmd = RunCommand(
            console: BufferedConsole(),
            processRunner: runner,
            currentDirectory: temporaryDirectory()
        )

        try cmd.run(arguments: ["--", "foo"])

        XCTAssertEqual(runner.invocations.first?.arguments, ["swift", "run", "--", "foo"])
    }

    func testSyphonStableNameUsesDirectoryBasename() {
        XCTAssertEqual(SyphonName.stable(for: URL(fileURLWithPath: "/Users/x/Sketches/WaveField")), "WaveField")
        XCTAssertEqual(SyphonName.stable(for: URL(fileURLWithPath: "/")), "metaphor")
    }

    func testUpdateSelfInstallsFrameworkBesideResolvedBinaryThroughSymlink() throws {
        let fm = FileManager.default
        let root = temporaryDirectory()

        // Build a release tarball fixture mirroring the real payload layout:
        // metaphor + Syphon.framework + templates.
        let staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try "NEW-BINARY".write(to: staging.appendingPathComponent("metaphor"), atomically: true, encoding: .utf8)
        let fwVersionsA = staging.appendingPathComponent("Syphon.framework/Versions/A")
        try fm.createDirectory(at: fwVersionsA, withIntermediateDirectories: true)
        try "FRAMEWORK".write(to: fwVersionsA.appendingPathComponent("Syphon"), atomically: true, encoding: .utf8)
        let templates = staging.appendingPathComponent("templates")
        try fm.createDirectory(at: templates, withIntermediateDirectories: true)
        try "x".write(to: templates.appendingPathComponent("placeholder.txt"), atomically: true, encoding: .utf8)

        let archiveURL = root.appendingPathComponent("release.tar.gz")
        try runTar(["-czf", archiveURL.path, "-C", staging.path, "metaphor", "Syphon.framework", "templates"])
        let tarData = try Data(contentsOf: archiveURL)

        // Pre-create the libexec + bin-symlink layout that scripts/install.sh / Homebrew produce.
        let libexecMetaphor = root.appendingPathComponent("libexec/metaphor")
        try fm.createDirectory(at: libexecMetaphor, withIntermediateDirectories: true)
        try "OLD-BINARY".write(to: libexecMetaphor.appendingPathComponent("metaphor"), atomically: true, encoding: .utf8)
        let binDir = root.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let symlink = binDir.appendingPathComponent("metaphor")
        try fm.createSymbolicLink(atPath: symlink.path, withDestinationPath: "../libexec/metaphor/metaphor")

        let assetURL = URL(string: "https://example.com/metaphor-cli_v9.0.0_macos_arm64.tar.gz")!
        let releases = StubReleaseService()
        releases.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v9.0.0",
            name: "v9.0.0",
            prerelease: false,
            assets: [GitHubRelease.Asset(name: "metaphor-cli_v9.0.0_macos_arm64.tar.gz", browserDownloadURL: assetURL, size: nil)]
        )
        releases.downloads[assetURL] = tarData

        let tool = CommandLineTool(
            console: BufferedConsole(),
            processRunner: FoundationProcessRunner(),
            releaseService: releases,
            currentDirectory: root,
            executablePath: symlink.path
        )

        try tool.run(arguments: ["update", "self", "--force", "--no-verify", "--install-path", symlink.path])

        // The framework must land beside the RESOLVED binary (libexec), not the symlink (bin).
        XCTAssertTrue(
            fm.fileExists(atPath: libexecMetaphor.appendingPathComponent("Syphon.framework/Versions/A/Syphon").path),
            "Syphon.framework must be installed beside the resolved binary in libexec"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: binDir.appendingPathComponent("Syphon.framework").path),
            "Framework must not be dropped next to the bin symlink"
        )
        XCTAssertEqual(
            try String(contentsOf: libexecMetaphor.appendingPathComponent("metaphor"), encoding: .utf8),
            "NEW-BINARY",
            "Resolved binary should be replaced with the new one"
        )
        let attrs = try fm.attributesOfItem(atPath: symlink.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "bin entry must remain a symlink")
        XCTAssertTrue(
            fm.fileExists(atPath: root.appendingPathComponent("share/metaphor/templates/placeholder.txt").path),
            "Templates should install under the prefix share dir"
        )
    }

    func testUpdateSelfRefusesArchiveWithoutFramework() throws {
        let fm = FileManager.default
        let root = temporaryDirectory()

        // Legacy-style payload: binary only, no Syphon.framework.
        let staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try "NEW-BINARY".write(to: staging.appendingPathComponent("metaphor"), atomically: true, encoding: .utf8)
        let archiveURL = root.appendingPathComponent("release.tar.gz")
        try runTar(["-czf", archiveURL.path, "-C", staging.path, "metaphor"])
        let tarData = try Data(contentsOf: archiveURL)

        let installPath = root.appendingPathComponent("bin/metaphor")
        try fm.createDirectory(at: installPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "OLD-BINARY".write(to: installPath, atomically: true, encoding: .utf8)

        let assetURL = URL(string: "https://example.com/metaphor-cli_v9.0.0_macos_arm64.tar.gz")!
        let releases = StubReleaseService()
        releases.releases["shinyaoguri/metaphor-cli"] = GitHubRelease(
            tagName: "v9.0.0",
            name: "v9.0.0",
            prerelease: false,
            assets: [GitHubRelease.Asset(name: "metaphor-cli_v9.0.0_macos_arm64.tar.gz", browserDownloadURL: assetURL, size: nil)]
        )
        releases.downloads[assetURL] = tarData

        let tool = CommandLineTool(
            console: BufferedConsole(),
            processRunner: FoundationProcessRunner(),
            releaseService: releases,
            currentDirectory: root,
            executablePath: installPath.path
        )

        XCTAssertThrowsError(
            try tool.run(arguments: ["update", "self", "--force", "--no-verify", "--install-path", installPath.path]),
            "update self must refuse an archive missing Syphon.framework"
        )
        // The existing binary must be left intact (rolled back), not destroyed.
        XCTAssertEqual(try String(contentsOf: installPath, encoding: .utf8), "OLD-BINARY")
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

    func testNewCommandInitializesInPlaceFromDirectoryName() throws {
        try withSourceTemplates {
            // The project name is derived from the folder, so create a named dir.
            let projectDir = temporaryDirectory().appendingPathComponent("test-meta")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            // A pre-existing dotfile must not block in-place init.
            let envrc = projectDir.appendingPathComponent(".envrc")
            try "PATH_add foo\n".write(to: envrc, atomically: true, encoding: .utf8)

            let console = BufferedConsole()
            let tool = CommandLineTool(
                console: console,
                processRunner: RecordingProcessRunner(),
                currentDirectory: projectDir
            )

            try tool.run(arguments: ["new", ".", "--template", "live", "--metaphor-path", "/Users/so/Repos/metaphor"])

            // "test-meta" -> package name "test-meta", module "TestMeta".
            let app = projectDir.appendingPathComponent("Sources/TestMeta/App.swift")
            let package = projectDir.appendingPathComponent("Package.swift")
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
            XCTAssertTrue(try String(contentsOf: package).contains("name: \"test-meta\""))

            // The pre-existing dotfile survives in-place init.
            XCTAssertTrue(FileManager.default.fileExists(atPath: envrc.path))
            XCTAssertTrue(console.output.joined(separator: "\n").contains("(in place)"))
        }
    }

    func testInitAliasInitializesCurrentDirectoryInPlace() throws {
        try withSourceTemplates {
            let projectDir = temporaryDirectory().appendingPathComponent("my-cool-sketch")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

            let console = BufferedConsole()
            let tool = CommandLineTool(
                console: console,
                processRunner: RecordingProcessRunner(),
                currentDirectory: projectDir
            )

            try tool.run(arguments: ["init", "--metaphor-path", "/Users/so/Repos/metaphor"])

            let app = projectDir.appendingPathComponent("Sources/MyCoolSketch/App.swift")
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
            XCTAssertTrue(console.output.joined(separator: "\n").contains("(in place)"))
        }
    }

    func testInPlaceInitRefusesToOverwriteExistingProjectFileWithoutForce() throws {
        try withSourceTemplates {
            let projectDir = temporaryDirectory().appendingPathComponent("occupied")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try "existing".write(to: projectDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

            let tool = CommandLineTool(
                console: BufferedConsole(),
                processRunner: RecordingProcessRunner(),
                currentDirectory: projectDir
            )

            // In-place skips the bulk emptiness gate, but the pre-flight check
            // still refuses to clobber an existing Package.swift without --force.
            XCTAssertThrowsError(try tool.run(arguments: ["new", ".", "--metaphor-path", "/Users/so/Repos/metaphor"])) { error in
                guard let cliError = error as? CLIError else {
                    XCTFail("Expected CLIError")
                    return
                }
                XCTAssertTrue(cliError.message.contains("Refusing to overwrite"))
            }
        }
    }

    func testInPlaceInitReportsAllCollisionsAndWritesNothing() throws {
        try withSourceTemplates {
            let projectDir = temporaryDirectory().appendingPathComponent("occupied")
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let package = projectDir.appendingPathComponent("Package.swift")
            try "old-package".write(to: package, atomically: true, encoding: .utf8)
            try "old-readme".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

            let console = BufferedConsole()
            let tool = CommandLineTool(
                console: console,
                processRunner: RecordingProcessRunner(),
                currentDirectory: projectDir
            )

            XCTAssertThrowsError(try tool.run(arguments: ["new", ".", "--metaphor-path", "/Users/so/Repos/metaphor"])) { error in
                guard let cliError = error as? CLIError else { return XCTFail("Expected CLIError") }
                // All collisions reported at once, not just the first.
                XCTAssertTrue(cliError.message.contains("2 existing file(s)"))
                XCTAssertTrue(cliError.message.contains("Package.swift"))
                XCTAssertTrue(cliError.message.contains("README.md"))
            }

            // Nothing was written: existing files untouched, no partial scaffold.
            XCTAssertEqual(try String(contentsOf: package), "old-package")
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("AGENTS.md").path))
        }
    }

    func testNewCommandRejectsPathLikeNames() throws {
        try withSourceTemplates {
            let root = temporaryDirectory()
            for badName in ["..", "a/b"] {
                let tool = CommandLineTool(
                    console: BufferedConsole(),
                    processRunner: RecordingProcessRunner(),
                    currentDirectory: root
                )
                XCTAssertThrowsError(try tool.run(arguments: ["new", badName, "--metaphor-path", "/Users/so/Repos/metaphor"])) { error in
                    guard let cliError = error as? CLIError else { return XCTFail("Expected CLIError") }
                    XCTAssertTrue(cliError.message.contains("Invalid project name"))
                    XCTAssertEqual(cliError.exitCode, 2)
                }
            }
            // The parent directory was never scaffolded into.
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        }
    }

    func testNewCommandRollsBackCreatedDirectoryOnWriteFailure() throws {
        try withSourceTemplates {
            let root = temporaryDirectory()
            let projectURL = root.appendingPathComponent("Doomed")
            // Fails once the generator descends into Sources/, after the top-level
            // files have already been written into the freshly created directory.
            let fileManager = FailingFileManager { $0.path.contains("/Sources") }

            let command = NewCommand(
                console: BufferedConsole(),
                processRunner: RecordingProcessRunner(),
                releaseService: StubReleaseService(),
                currentDirectory: root,
                fileManager: fileManager
            )

            XCTAssertThrowsError(try command.run(arguments: ["Doomed", "--metaphor-path", "/Users/so/Repos/metaphor"]))
            // The directory we created is rolled back, so a retry isn't blocked.
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runTar(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar"] + args
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "tar \(args.joined(separator: " ")) failed")
    }

    private func sourceTemplatesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Templates")
    }

    private func withSourceTemplates<T>(_ body: () throws -> T) rethrows -> T {
        let key = "METAPHOR_TEMPLATES_PATH"
        let previousValue = getenv(key).map { String(cString: $0) }
        setenv(key, sourceTemplatesDirectory().path, 1)
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
        return try body()
    }
}

/// A FileManager that fails `createDirectory` for paths matching a predicate, to
/// exercise NewCommand's rollback of a half-generated project.
private final class FailingFileManager: FileManager {
    private let shouldFail: (URL) -> Bool

    init(failWhen shouldFail: @escaping (URL) -> Bool) {
        self.shouldFail = shouldFail
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if shouldFail(url) {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
