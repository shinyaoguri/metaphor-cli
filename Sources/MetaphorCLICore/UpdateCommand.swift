import Foundation

public struct UpdateCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let releaseService: any ReleaseServicing
    private let currentDirectory: URL
    private let executablePath: String
    private let fileManager: FileManager
    private let currentVersion: String
    private let currentReleaseVersion: String
    private let isDevelopmentBuild: Bool

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        releaseService: any ReleaseServicing,
        currentDirectory: URL,
        executablePath: String,
        fileManager: FileManager = .default,
        currentVersion: String = BuildInfo.displayVersion,
        isDevelopmentBuild: Bool = BuildInfo.isDevelopmentBuild
    ) {
        self.console = console
        self.processRunner = processRunner
        self.releaseService = releaseService
        self.currentDirectory = currentDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
        self.currentVersion = currentVersion
        self.currentReleaseVersion = BuildInfo.releaseVersion(from: currentVersion)
        self.isDevelopmentBuild = isDevelopmentBuild
    }

    public func run(arguments: [String]) throws {
        let options = try OptionParser.parse(arguments)
        if options.flag("help", "h") {
            console.write(Self.helpText)
            return
        }

        let subject = options.positionals.first ?? "check"
        switch subject {
        case "check":
            try check()
        case "self":
            try updateSelf(options: options)
        case "library", "lib":
            try updateLibrary(options: options)
        case "all":
            try updateSelf(options: options)
            try updateLibrary(options: options)
        default:
            throw CLIError("Unknown update target '\(subject)'. Use self, library, all, or check.", exitCode: 2)
        }
    }

    private func check() throws {
        console.write("Checking for updates...")
        let managedInstaller = managedInstallerForCurrentExecutable()

        do {
            let cliRelease = try latestCLIRelease()
            // 表示は実行中ビルドの版そのまま、比較は describe のサフィックスを畳んだ版。
            // 混ぜると「リリースより進んだ開発ビルド」に更新を促してしまう。
            let cliStatus = updateStatus(
                current: currentReleaseVersion,
                latest: cliRelease.tagName
            )

            switch cliStatus {
            case .upToDate where isDevelopmentBuild:
                // リリース版と同じ「up to date」で括ると、配布版が入っていると誤読される。
                console.write("[info] metaphor-cli \(currentVersion) is a development build (latest release: \(cliRelease.tagName))")
            case .upToDate:
                console.write("[ok] metaphor-cli is up to date (\(currentVersion))")
            case .available:
                console.write("[update] metaphor-cli \(currentVersion) -> \(cliRelease.tagName)")
                console.write("         Run: \(managedInstaller?.upgradeCommand ?? "metaphor update self")")
            case .unknown:
                console.write("[info] metaphor-cli latest release: \(cliRelease.tagName)")
            }
        } catch {
            console.write("[info] metaphor-cli release information is not available yet: \(message(for: error))")
        }

        guard referencesMetaphorPackage(at: currentDirectory) else {
            console.write("[info] No Package.swift metaphor dependency found in \(currentDirectory.path)")
            return
        }

        let libraryRelease = try latestLibraryRelease()
        let currentLibraryVersion = PackageResolvedReader.metaphorVersion(in: currentDirectory)
        if let currentLibraryVersion {
            let libraryStatus = updateStatus(current: currentLibraryVersion, latest: libraryRelease.tagName)
            switch libraryStatus {
            case .upToDate:
                console.write("[ok] metaphor library is up to date (\(currentLibraryVersion))")
            case .available:
                console.write("[update] metaphor library \(currentLibraryVersion) -> \(libraryRelease.tagName)")
                console.write("         Run: metaphor update library")
            case .unknown:
                console.write("[info] metaphor latest release: \(libraryRelease.tagName)")
            }
        } else {
            console.write("[info] metaphor latest release: \(libraryRelease.tagName)")
            console.write("[info] Current resolved metaphor version was not found. Run `swift package resolve` first if needed.")
        }
    }

    private func updateSelf(options: ParsedOptions) throws {
        if let managedInstaller = managedInstallerForCurrentExecutable() {
            console.write("metaphor-cli appears to be installed by \(managedInstaller.name).")
            console.write("Run: \(managedInstaller.upgradeCommand)")
            return
        }

        let release = try latestCLIRelease()
        let status = updateStatus(current: currentReleaseVersion, latest: release.tagName)
        if status == .upToDate, !options.flag("force") {
            let current = isDevelopmentBuild ? "\(currentVersion), development build" : currentVersion
            console.write("metaphor-cli is already up to date (\(current)).")
            return
        }

        let asset = try selectCLIArchiveAsset(from: release)
        let checksumAsset = release.assets.first { $0.name == "checksums.txt" }

        console.write("Downloading \(asset.name)...")
        let archiveData = try releaseService.download(from: asset.browserDownloadURL)

        if let checksumAsset {
            let checksums = String(data: try releaseService.download(from: checksumAsset.browserDownloadURL), encoding: .utf8) ?? ""
            guard let expected = Checksum.checksum(for: asset.name, in: checksums) else {
                throw CLIError("Checksum for \(asset.name) was not found in checksums.txt")
            }
            let actual = Checksum.sha256Hex(archiveData)
            guard expected.lowercased() == actual.lowercased() else {
                throw CLIError("Checksum mismatch for \(asset.name)")
            }
        } else if !options.flag("no-verify") {
            throw CLIError("checksums.txt asset was not found. Use --no-verify to update without checksum verification.")
        }

        let installPath = options.value("install-path")
            .map { PathResolver.url(from: $0, relativeTo: currentDirectory) }
            ?? defaultInstallPath()

        if options.flag("dry-run") {
            console.write("Would install \(asset.name) to \(installPath.path)")
            return
        }

        try installCLI(fromArchiveData: archiveData, to: installPath)
        console.write("Updated metaphor-cli to \(release.tagName) at \(installPath.path)")
    }

    private func updateLibrary(options: ParsedOptions) throws {
        guard referencesMetaphorPackage(at: currentDirectory) else {
            throw CLIError("Package.swift in \(currentDirectory.path) does not appear to depend on metaphor")
        }

        if let localPath = PackageManifestReader.localMetaphorDependencyPath(in: currentDirectory) {
            console.write("This project uses a local metaphor checkout:")
            console.write("  \(localPath)")
            console.write("Update it with:")
            console.write("  git -C \(localPath) pull --ff-only")
            return
        }

        if options.flag("dry-run") {
            console.write("Would run: swift package update metaphor")
            return
        }

        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["swift", "package", "update", "metaphor"],
            currentDirectory: currentDirectory,
            captureOutput: false
        )
        if result.exitCode != 0 {
            throw CLIError("swift package update metaphor failed with exit code \(result.exitCode)", exitCode: result.exitCode)
        }
        console.write("Updated metaphor package resolution.")
    }

    private func latestCLIRelease() throws -> GitHubRelease {
        try releaseService.latestRelease(
            owner: BuildInfo.cliRepositoryOwner,
            repo: BuildInfo.cliRepositoryName
        )
    }

    private func latestLibraryRelease() throws -> GitHubRelease {
        try releaseService.latestRelease(
            owner: BuildInfo.libraryRepositoryOwner,
            repo: BuildInfo.libraryRepositoryName
        )
    }

    private func updateStatus(current: String, latest: String) -> UpdateStatus {
        guard let currentVersion = SemanticVersion(current),
              let latestVersion = SemanticVersion(latest) else {
            return current == latest || "v\(current)" == latest ? .upToDate : .unknown
        }
        return currentVersion < latestVersion ? .available : .upToDate
    }

    private func selectCLIArchiveAsset(from release: GitHubRelease) throws -> GitHubRelease.Asset {
        let arch = currentReleaseArchitecture()
        let exactName = "metaphor-cli_\(release.tagName)_macos_\(arch).tar.gz"
        if let asset = release.assets.first(where: { $0.name == exactName }) {
            return asset
        }

        if let asset = release.assets.first(where: {
            $0.name.contains("macos_\(arch)") && $0.name.hasSuffix(".tar.gz")
        }) {
            return asset
        }

        if let fallback = release.assets.first(where: {
            $0.name.contains("macos") && $0.name.hasSuffix(".tar.gz")
        }) {
            return fallback
        }

        throw CLIError("No macOS CLI archive asset was found in release \(release.tagName)")
    }

    private func installCLI(fromArchiveData archiveData: Data, to installPath: URL) throws {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("metaphor-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("metaphor.tar.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        let result = try processRunner.run(
            executable: "/usr/bin/env",
            arguments: ["tar", "-xzf", archiveURL.path, "-C", tempDir.path],
            currentDirectory: tempDir,
            captureOutput: true
        )
        if result.exitCode != 0 {
            throw CLIError("Failed to extract CLI archive: \(result.standardError)")
        }

        let unpackedBinary = tempDir.appendingPathComponent("metaphor")
        guard fileManager.fileExists(atPath: unpackedBinary.path) else {
            throw CLIError("CLI archive did not contain a metaphor binary")
        }

        // When the install path is a symlink (the libexec layout produced by
        // scripts/install.sh and Homebrew), replace the *resolved* binary so the
        // symlink keeps pointing at the one real file.
        let resolvedBinary = installPath.resolvingSymlinksInPath()
        let installDir = resolvedBinary.deletingLastPathComponent()

        try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)

        let binaryBackup = resolvedBinary.appendingPathExtension("old")
        try? fileManager.removeItem(at: binaryBackup)
        if fileManager.fileExists(atPath: resolvedBinary.path) {
            try fileManager.moveItem(at: resolvedBinary, to: binaryBackup)
        }

        do {
            try fileManager.copyItem(at: unpackedBinary, to: resolvedBinary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedBinary.path)
            // Templates are keyed off the public install path (the bin symlink),
            // not the resolved libexec location, so pass the original installPath.
            try installTemplatesIfPresent(from: tempDir, installPath: installPath)
            try? fileManager.removeItem(at: binaryBackup)
        } catch {
            // Roll the binary back so a failed update never leaves a half-installed
            // CLI (new binary with the old templates, or no binary at all).
            try? fileManager.removeItem(at: resolvedBinary)
            if fileManager.fileExists(atPath: binaryBackup.path) {
                try? fileManager.moveItem(at: binaryBackup, to: resolvedBinary)
            }
            throw error
        }
    }

    private func installTemplatesIfPresent(from extractedDirectory: URL, installPath: URL) throws {
        let extractedTemplates = extractedDirectory.appendingPathComponent("templates", isDirectory: true)
        guard fileManager.fileExists(atPath: extractedTemplates.path) else { return }

        let destination = templateInstallPath(forCLIInstallPath: installPath)
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: extractedTemplates, to: destination)
    }

    private func templateInstallPath(forCLIInstallPath installPath: URL) -> URL {
        let binDirectory = installPath.deletingLastPathComponent()
        let prefix = binDirectory.lastPathComponent == "bin"
            ? binDirectory.deletingLastPathComponent()
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local")
        return prefix.appendingPathComponent("share/metaphor/templates", isDirectory: true)
    }

    private func defaultInstallPath() -> URL {
        if let path = executablePathInPATH() {
            return path
        }

        let expanded = ("~/.local/bin/metaphor" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private func executablePathInPATH() -> URL? {
        if executablePath.contains("/") {
            let url = PathResolver.url(from: executablePath, relativeTo: currentDirectory).standardizedFileURL
            if !url.path.contains("/.build/") {
                return url
            }
        }

        let pathComponents = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathComponents {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("metaphor")
            if fileManager.isExecutableFile(atPath: candidate.path), !candidate.path.contains("/.build/") {
                return candidate
            }
        }
        return nil
    }

    private func currentReleaseArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func managedInstallerForCurrentExecutable() -> ManagedInstaller? {
        for url in candidateExecutableURLs() {
            let paths = [
                url.standardizedFileURL.path,
                url.resolvingSymlinksInPath().standardizedFileURL.path,
            ]

            for path in paths {
                if path.contains("/Cellar/metaphor/") {
                    return ManagedInstaller(name: "Homebrew", upgradeCommand: "brew upgrade metaphor")
                }
                if path.contains("/Cellar/metaphor-cli/") {
                    return ManagedInstaller(name: "Homebrew", upgradeCommand: "brew upgrade metaphor-cli")
                }
            }
        }
        return nil
    }

    private func candidateExecutableURLs() -> [URL] {
        var urls: [URL] = []
        if executablePath.contains("/") {
            urls.append(PathResolver.url(from: executablePath, relativeTo: currentDirectory))
        }
        if let path = executablePathInPATH() {
            urls.append(path)
        }
        return urls
    }

    private func message(for error: Error) -> String {
        if let cliError = error as? CLIError {
            return cliError.message
        }
        return String(describing: error)
    }

    private func referencesMetaphorPackage(at directory: URL) -> Bool {
        let packageFile = directory.appendingPathComponent("Package.swift")
        guard let contents = try? String(contentsOf: packageFile) else { return false }
        return contents.contains("shinyaoguri/metaphor") ||
            contents.contains(".product(name: \"metaphor\"") ||
            contents.contains(".product(name:\"metaphor\"")
    }

    public static let helpText = """
    Usage:
      metaphor update
      metaphor update check
      metaphor update self [--force] [--dry-run] [--install-path <path>]
      metaphor update library [--dry-run]
      metaphor update all

    Targets:
      check      Check metaphor-cli and the current package's metaphor dependency
      self       Update the installed metaphor CLI from GitHub Releases
      library    Run `swift package update metaphor` for the current Swift package
      all        Update self, then the current package dependency

    Options:
      --force          Reinstall CLI even when the version appears current
      --dry-run        Show intended actions without writing files
      --install-path   Override CLI install path for `update self`
      --no-verify      Allow self update without checksums.txt verification
    """
}

private struct ManagedInstaller {
    let name: String
    let upgradeCommand: String
}

private enum UpdateStatus {
    case upToDate
    case available
    case unknown
}
