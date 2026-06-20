import Foundation

public struct CommandLineTool {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let releaseService: any ReleaseServicing
    private let currentDirectory: URL
    private let executablePath: String

    public init(
        console: any Console = StandardConsole(),
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        releaseService: any ReleaseServicing = GitHubReleaseService(),
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        executablePath: String = CommandLine.arguments.first ?? "metaphor"
    ) {
        self.console = console
        self.processRunner = processRunner
        self.releaseService = releaseService
        self.currentDirectory = currentDirectory
        self.executablePath = executablePath
    }

    public func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            console.write(Self.helpText)
            return
        }

        let commandArguments = Array(arguments.dropFirst())

        switch command {
        case "new":
            try NewCommand(
                console: console,
                processRunner: processRunner,
                releaseService: releaseService,
                currentDirectory: currentDirectory
            ).run(arguments: commandArguments)
        case "run":
            try RunCommand(
                console: console,
                processRunner: processRunner,
                currentDirectory: currentDirectory
            ).run(arguments: commandArguments)
        case "watch":
            try WatchCommand(
                console: console,
                processRunner: processRunner,
                currentDirectory: currentDirectory
            ).run(arguments: commandArguments)
        case "doctor":
            try DoctorCommand(
                console: console,
                processRunner: processRunner,
                currentDirectory: currentDirectory
            ).run(arguments: commandArguments)
        case "update":
            try UpdateCommand(
                console: console,
                processRunner: processRunner,
                releaseService: releaseService,
                currentDirectory: currentDirectory,
                executablePath: executablePath
            ).run(arguments: commandArguments)
        case "examples", "templates":
            ExamplesCommand(console: console).run()
        case "version", "--version":
            console.write(BuildInfo.fullIdentifier)
        case "help", "--help", "-h":
            console.write(Self.helpText)
        default:
            throw CLIError("Unknown command '\(command)'. Run 'metaphor help' for usage.", exitCode: 2)
        }
    }

    public static let helpText = """
    metaphor: Swift + Metal creative coding tools

    Usage:
      metaphor new <name> [--template 2d] [--metaphor-version 0.2.3]
      metaphor run [swift-run-arguments...]
      metaphor watch [swift-build/run-arguments...]
      metaphor update [check|self|library|all]
      metaphor doctor
      metaphor examples
      metaphor version

    Commands:
      new       Create a new metaphor sketch package
      run       Run the current Swift package via `swift run`
      watch     Rebuild and restart the sketch on source changes
      update    Check or apply metaphor CLI/library updates
      doctor    Check local Swift/Xcode/package setup
      examples  List available project templates
      version   Print CLI version

    Templates:
    \(ProjectTemplate.usageList)

    Run `metaphor new --help` for project generation options.
    """
}

public struct NewCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let releaseService: any ReleaseServicing
    private let currentDirectory: URL
    private let fileManager: FileManager

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        releaseService: any ReleaseServicing,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.console = console
        self.processRunner = processRunner
        self.releaseService = releaseService
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    public func run(arguments: [String]) throws {
        let options = try OptionParser.parse(arguments)
        if options.flag("help", "h") {
            console.write(Self.helpText)
            return
        }

        guard let projectName = options.positionals.first else {
            throw CLIError("Missing project name. Usage: metaphor new <name>", exitCode: 2)
        }

        let catalog = try TemplateCatalog.loadDefault()
        let templateName = options.value("template", "t") ?? "2d"
        guard let template = catalog.template(named: templateName) else {
            let names = catalog.templates.map(\.id).joined(separator: ", ")
            throw CLIError("Unknown template '\(templateName)'. Available templates: \(names)", exitCode: 2)
        }

        let root = options.value("path")
            .map { PathResolver.url(from: $0, relativeTo: currentDirectory) }
            ?? currentDirectory
        let projectURL = root.appendingPathComponent(projectName, isDirectory: true)
        let force = options.flag("force")

        try prepareDestination(projectURL, force: force)

        let metaphorDependency: String
        let packageIdentity: String
        if let localPath = options.value("metaphor-path") {
            let url = PathResolver.url(from: localPath, relativeTo: currentDirectory)
            metaphorDependency = ".package(path: \"\(url.path.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
        } else {
            let url = options.value("metaphor-url") ?? "https://github.com/shinyaoguri/metaphor.git"
            let version = options.value("metaphor-version") ?? latestMetaphorVersion() ?? BuildInfo.defaultMetaphorVersion
            metaphorDependency = ".package(url: \"\(url.swiftLiteralEscaped)\", from: \"\(version.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
        }

        let context = TemplateContext(
            projectName: projectName,
            moduleName: NameSanitizer.moduleName(from: projectName),
            template: template,
            metaphorDependency: metaphorDependency,
            metaphorPackageIdentity: packageIdentity
        )

        for file in try TemplateRenderer.files(for: context, catalog: catalog) {
            try write(file, into: projectURL, overwrite: force)
        }

        if options.flag("git") {
            try initializeGitRepository(at: projectURL)
        }

        console.write("""
        Created \(projectName) using the \(template.rawValue) template.

        Next:
          cd \(projectURL.path)
          swift run
        """)
    }

    private func prepareDestination(_ url: URL, force: Bool) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw CLIError("Destination exists and is not a directory: \(url.path)")
            }

            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            if !contents.isEmpty && !force {
                throw CLIError("Destination is not empty: \(url.path). Use --force to write into it.")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write(_ file: GeneratedFile, into root: URL, overwrite: Bool) throws {
        let destination = root.appendingPathComponent(file.path)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) && !overwrite {
            throw CLIError("Refusing to overwrite existing file: \(destination.path)")
        }

        guard let data = file.contents.data(using: .utf8) else {
            throw CLIError("Failed to encode \(file.path) as UTF-8")
        }
        try data.write(to: destination, options: .atomic)
    }

    private func initializeGitRepository(at url: URL) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["git", "init"],
            currentDirectory: url,
            captureOutput: true
        )
        if result.exitCode != 0 {
            console.writeError("warning: git init failed: \(result.standardError)")
        }
    }

    private func latestMetaphorVersion() -> String? {
        do {
            let release = try releaseService.latestRelease(
                owner: BuildInfo.libraryRepositoryOwner,
                repo: BuildInfo.libraryRepositoryName
            )
            return release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        } catch {
            console.writeError("warning: could not fetch latest metaphor release; using \(BuildInfo.defaultMetaphorVersion)")
            return nil
        }
    }

    public static let helpText = """
    Usage:
      metaphor new <name> [options]

    Options:
      --template <name>            Template: 2d, 3d, shader, live, audio-reactive, raytracing, syphon
      --path <directory>           Parent directory for the new project
      --metaphor-version <ver>     metaphor package version, default: latest release
      --metaphor-url <url>         metaphor package URL
      --metaphor-path <path>       Use a local metaphor checkout instead of a remote package
      --metaphor-package <name>    Package identity for the metaphor product, default: metaphor
      --git                       Run git init after generation
      --force                     Write into an existing non-empty directory

    Templates:
    \(ProjectTemplate.usageList)
    """
}

public struct RunCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL

    public init(console: any Console, processRunner: any ProcessRunning, currentDirectory: URL) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
    }

    public func run(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            console.write("""
            Usage:
              metaphor run [swift-run-arguments...]

            Runs `swift run` in the current directory and forwards extra arguments.
            """)
            return
        }

        if arguments.contains("--watch") {
            throw CLIError("`metaphor run --watch` は `metaphor watch` に移行しました。`metaphor watch` を使ってください。", exitCode: 2)
        }

        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["swift", "run"] + arguments,
            currentDirectory: currentDirectory,
            captureOutput: false
        )
        if result.exitCode != 0 {
            throw CLIError("swift run failed with exit code \(result.exitCode)", exitCode: result.exitCode)
        }
    }
}

public struct DoctorCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL
    private let fileManager: FileManager

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    public func run(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            console.write("Usage: metaphor doctor")
            return
        }

        console.write("metaphor doctor")
        checkCommand(label: "Swift", arguments: ["swift", "--version"])
        checkCommand(label: "Xcode", arguments: ["xcodebuild", "-version"])

        let packageFile = currentDirectory.appendingPathComponent("Package.swift")
        if fileManager.fileExists(atPath: packageFile.path) {
            console.write("[ok] Package.swift found")
        } else {
            console.write("[warn] Package.swift not found in \(currentDirectory.path)")
        }

        if let catalog = try? TemplateCatalog.loadDefault() {
            console.write("[ok] \(catalog.templates.count) project templates available")
        } else {
            console.write("[warn] Project templates are not available")
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
