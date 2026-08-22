import Foundation

public struct DoctorCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL
    private let fileManager: FileManager
    private let home: URL

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        currentDirectory: URL,
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
        self.home = home
    }

    public func run(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            console.write("Usage: metaphor doctor")
            return
        }

        console.write("metaphor doctor")
        // 環境診断の正典なので、`metaphor version` と同じ 2 行をそのまま出す
        // （どの CLI とどのライブラリの話をしているかが診断結果の前提になる）。
        EnvironmentVersions.resolve(in: currentDirectory).textLines.forEach(console.write)
        checkCommand(label: "Swift", arguments: ["swift", "--version"])
        checkCommand(label: "Xcode", arguments: ["xcodebuild", "-version"])

        let packageFile = currentDirectory.appendingPathComponent("Package.swift")
        let isSketchProject = fileManager.fileExists(atPath: packageFile.path)
        if isSketchProject {
            console.write("[ok] Package.swift found")
        } else {
            console.write("[warn] Package.swift not found in \(currentDirectory.path)")
        }

        if let catalog = try? TemplateCatalog.loadDefault() {
            console.write("[ok] \(catalog.templates.count) project templates available (\(catalog.root.path))")
        } else {
            console.write("[warn] Project templates are not available")
        }

        checkEditorEnvironment(
            isSketch: isSketchProject
                && PackageManifestReader.declaresMetaphorDependency(in: currentDirectory)
        )
    }

    /// 人間側の編集環境（VSCode）の検査。CLI の動作自体は妨げないので、
    /// どれも `[warn]` 止まり。補完・hover が「無言で出ない」ときに、原因が
    /// 拡張の不在なのか背景インデックスなのか未ビルドなのかを切り分ける。
    private func checkEditorEnvironment(isSketch: Bool) {
        switch VSCodeEnvironment.swiftExtension(home: home, fileManager: fileManager) {
        case .installed(let version):
            let suffix = version.map { " \($0)" } ?? ""
            console.write("[ok] VSCode Swift extension: \(VSCodeEnvironment.swiftExtensionID)\(suffix)")
        case .missing:
            console.write(
                "[warn] VSCode Swift extension not installed — hover and completion stay silent "
                    + "(install \(VSCodeEnvironment.swiftExtensionID))"
            )
        case .vscodeNotFound:
            // VSCode を使っていないマシンでは欠落ではないので、警告にはしない。
            console.write("[info] VSCode not detected (~/.vscode/extensions) — editor checks skipped")
        }

        // 以下はスケッチ側の設定なので、スケッチ外での doctor では無関係な警告になる。
        guard isSketch else { return }

        switch VSCodeEnvironment.sourcekitLSPConfig(projectRoot: currentDirectory, fileManager: fileManager) {
        case .backgroundIndexingDisabled:
            console.write("[ok] .sourcekit-lsp/config.json: backgroundIndexing disabled")
        case .backgroundIndexingEnabled:
            console.write(
                "[warn] .sourcekit-lsp/config.json: backgroundIndexing is not disabled — "
                    + "`import metaphor` can fail in the editor (metaphor#578)"
            )
        case .missing:
            console.write(
                "[warn] .sourcekit-lsp/config.json not found — background indexing can break "
                    + "`import metaphor` in the editor (regenerate with a newer `metaphor new`)"
            )
        case .unreadable(let reason):
            console.write("[warn] .sourcekit-lsp/config.json unreadable: \(reason)")
        }

        if VSCodeEnvironment.hasBuildProducts(projectRoot: currentDirectory, fileManager: fileManager) {
            console.write("[ok] Build products found (editor completion has something to index)")
        } else {
            console.write(
                "[warn] Sketch not built yet (.build/debug not found) — "
                    + "editor completion needs one `swift build`"
            )
        }
    }

    private func checkCommand(label: String, arguments: [String]) {
        do {
            let result = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                currentDirectory: currentDirectory,
                captureOutput: true
            )
            if result.exitCode == 0 {
                let firstLine = result.standardOutput.split(separator: "\n").first.map(String.init) ?? "available"
                console.write("[ok] \(label): \(firstLine)")
            } else {
                console.write("[warn] \(label): \(result.standardError)")
            }
        } catch {
            console.write("[warn] \(label): \(error)")
        }
    }
}

public struct ExamplesCommand {
    private let console: any Console

    public init(console: any Console) {
        self.console = console
    }

    public func run() {
        console.write("""
        Available templates:
        \(ProjectTemplate.usageList)

        Example:
          metaphor new MySketch --template live
        """)
    }
}
