import Foundation

public struct CLIError: Error, Equatable {
    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

public protocol Console {
    func write(_ message: String)
    func writeError(_ message: String)
}

public struct StandardConsole: Console {
    public init() {}

    public func write(_ message: String) {
        print(message)
    }

    public func writeError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

public final class BufferedConsole: Console {
    public private(set) var output: [String] = []
    public private(set) var errors: [String] = []

    public init() {}

    public func write(_ message: String) {
        output.append(message)
    }

    public func writeError(_ message: String) {
        errors.append(message)
    }
}

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning {
    @discardableResult
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        captureOutput: Bool
    ) throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    @discardableResult
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        captureOutput: Bool = true
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if captureOutput {
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
        } else {
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }

        try process.run()
        process.waitUntilExit()

        let stdout: String
        let stderr: String
        if captureOutput {
            stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else {
            stdout = ""
            stderr = ""
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public final class RecordingProcessRunner: ProcessRunning {
    public struct Invocation: Equatable {
        public let executable: String
        public let arguments: [String]
        public let currentDirectory: URL?
        public let captureOutput: Bool
    }

    public private(set) var invocations: [Invocation] = []
    public var result = ProcessResult(exitCode: 0)

    public init() {}

    @discardableResult
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        captureOutput: Bool
    ) throws -> ProcessResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            captureOutput: captureOutput
        ))
        return result
    }
}

public struct ParsedOptions {
    public var positionals: [String] = []
    public var flags: Set<String> = []
    public var values: [String: String] = [:]

    public func value(_ names: String...) -> String? {
        for name in names {
            if let value = values[name] {
                return value
            }
        }
        return nil
    }

    public func flag(_ names: String...) -> Bool {
        names.contains { flags.contains($0) || values[$0] == "true" }
    }
}

public enum OptionParser {
    public static func parse(_ arguments: [String]) throws -> ParsedOptions {
        var parsed = ParsedOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            if argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let trimmed = String(argument.dropFirst())
                if !trimmed.isEmpty {
                    parsed.flags.insert(trimmed)
                }
                index += 1
                continue
            }

            guard argument.hasPrefix("--") else {
                parsed.positionals.append(argument)
                index += 1
                continue
            }

            let trimmed = String(argument.dropFirst(2))
            guard !trimmed.isEmpty else {
                index += 1
                continue
            }

            if let equals = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equals])
                let value = String(trimmed[trimmed.index(after: equals)...])
                parsed.values[key] = value
                index += 1
                continue
            }

            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                parsed.values[trimmed] = arguments[index + 1]
                index += 2
            } else {
                parsed.flags.insert(trimmed)
                index += 1
            }
        }

        return parsed
    }
}

public enum PathResolver {
    public static func url(from path: String, relativeTo currentDirectory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return currentDirectory.appendingPathComponent(expanded)
    }
}

public enum NameSanitizer {
    public static func moduleName(from projectName: String) -> String {
        let pieces = projectName
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)

        let joined = pieces.map { piece -> String in
            guard let first = piece.first else { return "" }
            return first.uppercased() + piece.dropFirst()
        }.joined()

        let fallback = joined.isEmpty ? "Sketch" : joined
        guard let first = fallback.first, first.isLetter || first == "_" else {
            return "Sketch" + fallback
        }
        return fallback
    }
}

extension String {
    var swiftLiteralEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
