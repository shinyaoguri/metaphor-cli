import Darwin
import Foundation
import MetaphorCLICore

@main
enum MetaphorCLIEntryPoint {
    static func main() {
        let tool = CommandLineTool()
        do {
            try tool.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            StandardConsole().writeError("error: \(error.message)")
            exit(error.exitCode)
        } catch {
            StandardConsole().writeError("error: \(error)")
            exit(1)
        }
    }
}
