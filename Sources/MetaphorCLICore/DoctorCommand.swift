import Foundation
import MachO

public struct DoctorCommand {
    private let console: any Console
    private let processRunner: any ProcessRunning
    private let currentDirectory: URL
    private let fileManager: FileManager
    private let loadedImagePaths: () -> [String]

    public init(
        console: any Console,
        processRunner: any ProcessRunning,
        currentDirectory: URL,
        fileManager: FileManager = .default,
        loadedImagePaths: @escaping () -> [String] = DoctorCommand.dyldLoadedImagePaths
    ) {
        self.console = console
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
        self.loadedImagePaths = loadedImagePaths
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

        // Report where Syphon.framework was loaded from. This is informational,
        // not a health gate: the metaphor binary hard-links Syphon, so if the
        // framework were missing this process would have aborted at launch
        // before reaching here. The path confirms the install layout (libexec
        // symlink, side-by-side tarball, or make-install rpath).
        if let syphon = loadedImagePaths().first(where: { $0.contains("Syphon.framework") }) {
            console.write("[ok] Syphon.framework loaded: \(syphon)")
        } else {
            console.write("[warn] Syphon.framework not among loaded images (live viewer / Syphon output unavailable)")
        }
    }

    /// Paths of all images currently loaded into this process, via dyld. Used to
    /// report where Syphon.framework resolved from. Injectable for tests.
    public static func dyldLoadedImagePaths() -> [String] {
        var paths: [String] = []
        let count = _dyld_image_count()
        var index: UInt32 = 0
        while index < count {
            if let name = _dyld_get_image_name(index) {
                paths.append(String(cString: name))
            }
            index += 1
        }
        return paths
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
