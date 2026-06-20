import PackagePlugin
import Foundation

@main
struct VersionStampPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let output = context.pluginWorkDirectory.appending("GeneratedBuildRevision.swift")
        let pkgDir = context.package.directory.string
        let script = """
        rev=$(cd '\(pkgDir)' && git describe --tags --always --dirty 2>/dev/null || true)
        printf 'enum BuildRevision { static let gitDescribe = "%s" }\\n' "$rev" > '\(output.string)'
        """
        return [
            .prebuildCommand(
                displayName: "Stamp build revision (git describe)",
                executable: Path("/bin/sh"),
                arguments: ["-c", script],
                outputFilesDirectory: context.pluginWorkDirectory
            )
        ]
    }
}
