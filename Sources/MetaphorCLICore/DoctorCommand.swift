import Foundation

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
