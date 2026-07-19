import Darwin
import Foundation

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
        // 完了メッセージ用。どの metaphor をどう決めたかをユーザーに透明にする (#58)。
        let dependencySummary: String
        if let localPath = options.value("metaphor-path") {
            let url = PathResolver.url(from: localPath, relativeTo: currentDirectory)
            metaphorDependency = ".package(path: \"\(url.path.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
            aiDocsPath = url.path
            dependencySummary = "local checkout at \(url.path)"
        } else {
            let url = options.value("metaphor-url") ?? "https://github.com/shinyaoguri/metaphor.git"
            let version: String
            let versionSource: String
            if let explicit = options.value("metaphor-version") {
                version = explicit
                versionSource = "--metaphor-version"
            } else if let latest = latestMetaphorVersion() {
                version = latest
                versionSource = "latest GitHub release"
            } else {
                version = BuildInfo.defaultMetaphorVersion
                versionSource = "built-in default"
            }
            metaphorDependency = ".package(url: \"\(url.swiftLiteralEscaped)\", from: \"\(version.swiftLiteralEscaped)\")"
            packageIdentity = options.value("metaphor-package") ?? "metaphor"
            aiDocsPath = ".build/checkouts/metaphor"
            dependencySummary = "from: \(version) (\(versionSource); allows newer up to the next major)"
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

        console.write("Created \(projectName)\(inPlace ? " (in place)" : "") using the \(template.rawValue) template.")
        // Surface which catalog produced the files, so a stale install's
        // templates shadowing the expected ones is diagnosable at a glance (#69).
        console.write("Templates: \(catalog.root.path)")
        console.write("metaphor: \(dependencySummary)")

        // Resolve dependencies now so the metaphor package is checked out
        // immediately. For a remote (url) dependency this is what creates
        // `.build/checkouts/metaphor`, where `metaphor mcp`'s `api_reference`
        // tool finds the API docs — so an AI assistant can read the API before
        // the first build instead of hitting an unresolved-library error. Opt
        // out with --no-resolve (offline / faster scaffolding).
        if !options.flag("no-resolve") {
            resolveDependencies(in: projectURL)
        }

        // Lead with the metaphor-cli dev loop (live viewer + hot reload), which is
        // the whole point of the tool; `metaphor run` is the one-shot alternative.
        let devHint = "  metaphor watch        # live viewer + hot reload (one-shot: metaphor run)"
        let nextSteps = inPlace ? devHint : "  cd \(projectURL.path)\n\(devHint)"
        console.write("""

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

    /// Resolves the freshly generated project's dependencies so the metaphor
    /// package is materialized right away. For a remote (url) dependency this is
    /// what creates `<project>/.build/checkouts/metaphor`, where `api_reference`
    /// reads `llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.md`; for a
    /// local (path) dependency the docs are already on disk, but resolving still
    /// leaves the project ready to build.
    ///
    /// Best-effort: the project is already valid on disk, so a failure here
    /// (e.g. offline) is a warning, never fatal — `metaphor watch` / `metaphor
    /// run` resolve on the first build anyway.
    private func resolveDependencies(in projectURL: URL) {
        console.write("\nResolving dependencies so metaphor's API reference is ready…")
        // Flush our buffered stdout before the child streams to the inherited
        // stdout: when output is piped/redirected `print` is fully buffered, so
        // without this swift's fetch log would jumble ahead of our own lines.
        fflush(stdout)
        let hint = "`metaphor watch` / `metaphor run` will resolve them on the first build."
        do {
            // Stream swift's own progress (captureOutput: false); the fetch can
            // take a moment and silence would look like a hang.
            let result = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: ["swift", "package", "resolve"],
                currentDirectory: projectURL,
                captureOutput: false
            )
            if result.exitCode != 0 {
                console.writeError("warning: swift package resolve exited \(result.exitCode). \(hint)")
            }
        } catch {
            console.writeError("warning: could not run swift package resolve: \(error.localizedDescription). \(hint)")
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
      --no-resolve                Skip `swift package resolve` after generation (offline / faster)

    Templates:
    \(ProjectTemplate.usageList)
    """
}
