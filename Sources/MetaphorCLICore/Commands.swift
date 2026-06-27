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
        case "init":
            // `init` is sugar for `new .`: initialize the current directory.
            try NewCommand(
                console: console,
                processRunner: processRunner,
                releaseService: releaseService,
                currentDirectory: currentDirectory
            ).run(arguments: ["."] + commandArguments)
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
        case "mcp":
            try MCPCommand(
                console: console,
                currentDirectory: currentDirectory
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
      metaphor init [--template 2d]
      metaphor run [swift-run-arguments...]
      metaphor watch [--no-viewer] [--syphon-name <name>] [swift-build/run-arguments...]
      metaphor mcp [sketch-dir]
      metaphor update [check|self|library|all]
      metaphor doctor
      metaphor examples
      metaphor version

    Commands:
      new       Create a new metaphor sketch package
      init      Initialize a sketch in the current directory (alias for `new .`)
      run       Run the current Swift package via `swift run`
      watch     Live-reload the sketch in a viewer window (--no-viewer for the sketch's own window)
      mcp       Serve a local MCP server (snapshot/observe the sketch for AI agents)
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

        // `metaphor new .` (and the `metaphor init` alias) initialize in place:
        // the current directory becomes the project and its name is taken from
        // the folder. Otherwise the positional names a child directory to create
        // under the cwd (or `--path`).
        let rawName = options.positionals.first
        let inPlace = rawName == "." || rawName == "./"

        let projectName: String
        let projectURL: URL
        if inPlace {
            projectURL = currentDirectory.standardizedFileURL
            projectName = projectURL.lastPathComponent
            guard !projectName.isEmpty, projectName != "/" else {
                throw CLIError("Could not derive a project name from the current directory.", exitCode: 2)
            }
        } else {
            guard let name = rawName else {
                throw CLIError("Missing project name. Usage: metaphor new <name>  (or `metaphor new .` to initialize the current directory)", exitCode: 2)
            }
            try validateProjectName(name)
            projectName = name
            let root = options.value("path")
                .map { PathResolver.url(from: $0, relativeTo: currentDirectory) }
                ?? currentDirectory
            projectURL = root.appendingPathComponent(projectName, isDirectory: true)
        }

        let catalog = try TemplateCatalog.loadDefault()
        let templateName = options.value("template", "t") ?? "2d"
        guard let template = catalog.template(named: templateName) else {
            let names = catalog.templates.map(\.id).joined(separator: ", ")
            throw CLIError("Unknown template '\(templateName)'. Available templates: \(names)", exitCode: 2)
        }

        let metaphorDependency: String
        let packageIdentity: String
        // api_reference / AGENTS.md 用の AI ドキュメントの在り処。ローカル checkout は
        // その絶対パス、リモート版は初回ビルド後に現れる SwiftPM checkout 先。
        let aiDocsPath: String
        if let localPath = options.value("metaphor-path") {
            let url = PathResolver.url(from: localPath, relativeTo: currentDirectory)
            metaphorDependency = ".package(path: \"\(url.path.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
            aiDocsPath = url.path
        } else {
            let url = options.value("metaphor-url") ?? "https://github.com/shinyaoguri/metaphor.git"
            let version = options.value("metaphor-version") ?? latestMetaphorVersion() ?? BuildInfo.defaultMetaphorVersion
            metaphorDependency = ".package(url: \"\(url.swiftLiteralEscaped)\", from: \"\(version.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
            aiDocsPath = ".build/checkouts/metaphor"
        }

        let context = TemplateContext(
            projectName: projectName,
            moduleName: NameSanitizer.moduleName(from: projectName),
            template: template,
            metaphorDependency: metaphorDependency,
            metaphorPackageIdentity: packageIdentity,
            metaphorAIDocsPath: aiDocsPath
        )

        // Render every file up front, before touching the filesystem, so a
        // broken template fails cleanly without leaving a directory behind.
        let files = try TemplateRenderer.files(for: context, catalog: catalog)

        let force = options.flag("force")
        let createdDirectory = try prepareDestination(projectURL, force: force, inPlace: inPlace)

        do {
            // Pre-flight: find every collision and refuse as a group *before*
            // writing anything, so a half-generated project is never left behind.
            if !force {
                try assertNoCollisions(for: files, in: projectURL)
            }
            for file in files {
                try write(file, into: projectURL, overwrite: force)
            }
            if options.flag("git") {
                try initializeGitRepository(at: projectURL)
            }
        } catch {
            // Roll back only a directory we created ourselves; never delete a
            // pre-existing (e.g. in-place) directory or the user's own files.
            if createdDirectory {
                try? fileManager.removeItem(at: projectURL)
            }
            throw error
        }

        // Lead with the metaphor-cli dev loop (live viewer + hot reload), which is
        // the whole point of the tool; `metaphor run` is the one-shot alternative.
        let devHint = "  metaphor watch        # live viewer + hot reload (one-shot: metaphor run)"
        let nextSteps = inPlace ? devHint : "  cd \(projectURL.path)\n\(devHint)"
        console.write("""
        Created \(projectName)\(inPlace ? " (in place)" : "") using the \(template.rawValue) template.

        Next:
        \(nextSteps)
        """)
    }

    /// Ensures `url` is a usable destination directory and returns whether this
    /// call created it (so the caller can roll it back on a later failure).
    private func prepareDestination(_ url: URL, force: Bool, inPlace: Bool) throws -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw CLIError("Destination exists but is not a directory: \(url.path)")
            }

            // In-place init (`metaphor new .`) runs inside a directory that may
            // already hold dotfiles like `.envrc`/`.git`, so the bulk emptiness
            // gate would always trip. Skip it and let the pre-flight collision
            // check refuse to clobber an existing project instead.
            if !inPlace {
                let contents = try fileManager.contentsOfDirectory(atPath: url.path)
                if !contents.isEmpty && !force {
                    throw CLIError("Destination is not empty: \(url.path). Use --force to write into it.")
                }
            }
            return false
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CLIError("Could not create project directory \(url.path): \(error.localizedDescription)")
        }
        return true
    }

    /// Refuses to overwrite existing files, reporting *all* collisions at once so
    /// the user can resolve them in a single pass. Skipped when `--force` is set.
    private func assertNoCollisions(for files: [GeneratedFile], in root: URL) throws {
        let existing = files
            .map { root.appendingPathComponent($0.path) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard existing.isEmpty else {
            let list = existing.map { "  \($0.path)" }.joined(separator: "\n")
            throw CLIError("""
            Refusing to overwrite \(existing.count) existing file(s):
            \(list)

            Pass --force to overwrite them, or remove/rename them first.
            """)
        }
    }

    /// Rejects path-like names so `new` only ever creates a single child
    /// directory; a different location is chosen with `--path`.
    private func validateProjectName(_ name: String) throws {
        let isPathLike = name.isEmpty
            || name == "."
            || name == ".."
            || name.contains("/")
            || name.hasPrefix("~")
        if isPathLike {
            throw CLIError(
                "Invalid project name '\(name)'. Use a single directory name (no '/', '..', or '~'). To create it elsewhere, add: --path <directory>",
                exitCode: 2
            )
        }
    }

    private func write(_ file: GeneratedFile, into root: URL, overwrite: Bool) throws {
        let destination = root.appendingPathComponent(file.path)
        let parent = destination.deletingLastPathComponent()

        if fileManager.fileExists(atPath: destination.path) && !overwrite {
            throw CLIError("Refusing to overwrite existing file: \(destination.path)")
        }

        guard let data = file.contents.data(using: .utf8) else {
            throw CLIError("Failed to encode \(file.path) as UTF-8")
        }

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw CLIError("Could not write \(file.path): \(error.localizedDescription)")
        }
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
      metaphor new <name> [options]      Create <name>/ under the current directory
      metaphor new . [options]           Initialize the current directory (name taken from the folder)
      metaphor init [options]            Alias for `metaphor new .`

    Options:
      --template <name>            Template: 2d, 3d, shader, live, audio-reactive, raytracing, syphon
      --path <directory>           Parent directory for the new project (ignored for in-place init)
      --metaphor-version <ver>     metaphor package version, default: latest release
      --metaphor-url <url>         metaphor package URL
      --metaphor-path <path>       Use a local metaphor checkout instead of a remote package
      --metaphor-package <name>    Package identity for the metaphor product, default: metaphor
      --git                       Run git init after generation
      --force                     Overwrite existing files in the destination

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
