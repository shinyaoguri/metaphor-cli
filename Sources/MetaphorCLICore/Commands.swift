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
      metaphor run [--syphon[=name]] [--fps <n>] [--metrics] [swift-run-arguments...]
      metaphor watch [--no-viewer] [--syphon-name <name>] [--fps <n>] [--metrics] [swift-build/run-arguments...]
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
