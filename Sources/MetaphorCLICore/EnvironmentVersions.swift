import Foundation

/// いま動いている環境の版一覧（CLI 本体 + そのディレクトリで解決されている
/// metaphor ライブラリ）。ネットワークは一切叩かない — 「最新かどうか」は
/// `metaphor update check` の責務で、こちらは「いま何が居るか」だけを答える。
public struct EnvironmentVersions {
    /// ライブラリ版の出どころ。バージョン文字列だけだと「見つからない」と
    /// 「ローカル checkout を指しているので版が無い」が区別できないので型で持つ。
    public enum Library: Equatable {
        /// `Package.resolved` に固定されている版。
        case resolved(String)
        /// `Package.swift` の `.package(path:)` によるローカル参照（版は無い）。
        case localPath(String)
        /// スケッチ外、または未解決。
        case unresolved
    }

    /// CLI 行のラベル（`metaphor-cli`）。ライブラリ行の `metaphor` をこの幅まで
    /// 詰めることで、2 行の版が縦に揃う。
    public static let cliName = "\(BuildInfo.name)-cli"

    public let library: Library

    public init(library: Library) {
        self.library = library
    }

    /// 指定ディレクトリを SwiftPM パッケージとみなして版を集める。
    public static func resolve(in packageDirectory: URL) -> EnvironmentVersions {
        EnvironmentVersions(library: resolveLibrary(in: packageDirectory))
    }

    private static func resolveLibrary(in packageDirectory: URL) -> Library {
        if let version = PackageResolvedReader.metaphorVersion(in: packageDirectory) {
            return .resolved(version)
        }
        if let path = PackageManifestReader.localMetaphorDependencyPath(in: packageDirectory) {
            return .localPath(path)
        }
        return .unresolved
    }

    /// `metaphor version` / `metaphor doctor` が出す 2 行。両者で同じ文字列を使う。
    /// CLI 行は `watch` のバナーと同一（`BuildInfo.cliIdentifier`）。
    public var textLines: [String] {
        [
            BuildInfo.cliIdentifier,
            "\(pad(BuildInfo.name)) \(libraryDescription)",
        ]
    }

    private var libraryDescription: String {
        switch library {
        case let .resolved(version):
            return "\(version) (Package.resolved)"
        case let .localPath(path):
            return "local path \(path)"
        case .unresolved:
            return "(not resolved here - run inside a sketch, or 'swift package resolve')"
        }
    }

    private func pad(_ label: String) -> String {
        label.count >= Self.cliName.count
            ? label
            : label + String(repeating: " ", count: Self.cliName.count - label.count)
    }

    /// `metaphor version --json` の本体。MCP・CI・エージェントが安定して読めるよう、
    /// キーは常にすべて並べ、当てはまらない値は `null` にする（キーの有無で
    /// 分岐させない）。並びは `.sortedKeys` で固定。
    public func jsonString() throws -> String {
        let source: String
        let version: Any
        let path: Any
        switch library {
        case let .resolved(resolvedVersion):
            (source, version, path) = ("package-resolved", resolvedVersion, NSNull())
        case let .localPath(localPath):
            (source, version, path) = ("local-path", NSNull(), localPath)
        case .unresolved:
            (source, version, path) = ("unresolved", NSNull(), NSNull())
        }

        let object: [String: Any] = [
            "cli": [
                "name": Self.cliName,
                "version": BuildInfo.displayVersion,
                "built": BuildInfo.buildStamp,
            ],
            "library": [
                "name": BuildInfo.name,
                "source": source,
                "version": version,
                "path": path,
            ],
        ]

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLIError("Failed to encode version information as JSON")
        }
        return json
    }
}

public struct VersionCommand {
    private let console: any Console
    private let currentDirectory: URL

    public init(console: any Console, currentDirectory: URL) {
        self.console = console
        self.currentDirectory = currentDirectory
    }

    public func run(arguments: [String]) throws {
        let options = try OptionParser.parse(arguments)
        if options.flag("help", "h") {
            console.write(Self.helpText)
            return
        }

        let versions = EnvironmentVersions.resolve(in: currentDirectory)
        if options.flag("json") {
            console.write(try versions.jsonString())
            return
        }
        versions.textLines.forEach(console.write)
    }

    static let helpText = """
    Usage: metaphor version [--json]

    Print the versions in play here: the CLI itself, and the metaphor library
    resolved in the current directory. Does not touch the network — use
    `metaphor update check` to compare against the latest releases.

    Options:
      --json    Emit machine-readable JSON instead of two aligned lines
    """
}
