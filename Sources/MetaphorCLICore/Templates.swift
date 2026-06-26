import Foundation

public struct ProjectTemplate: Decodable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let files: [TemplateFileSpec]

    public var rawValue: String { id }

    public static var usageList: String {
        TemplateCatalog.defaultUsageList()
    }
}

public struct TemplateFileSpec: Decodable, Equatable {
    public let source: String
    public let destination: String
}

public struct TemplateManifest: Decodable, Equatable {
    public let commonFiles: [TemplateFileSpec]
    public let templates: [ProjectTemplate]
}

public struct TemplateCatalog {
    public let root: URL
    public let manifest: TemplateManifest

    public var templates: [ProjectTemplate] {
        manifest.templates
    }

    public var usageList: String {
        templates.map { template in
            "  \(template.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(template.summary)"
        }.joined(separator: "\n")
    }

    public init(root: URL, manifest: TemplateManifest) {
        self.root = root
        self.manifest = manifest
    }

    public func template(named id: String) -> ProjectTemplate? {
        templates.first { $0.id == id }
    }

    public static func loadDefault(fileManager: FileManager = .default) throws -> TemplateCatalog {
        for root in defaultSearchRoots() where fileManager.fileExists(atPath: root.appendingPathComponent("templates.json").path) {
            return try load(from: root)
        }
        let searched = defaultSearchRoots().map(\.path).joined(separator: "\n  ")
        throw CLIError("Template catalog was not found. Searched:\n  \(searched)")
    }

    public static func load(from root: URL) throws -> TemplateCatalog {
        let manifestURL = root.appendingPathComponent("templates.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(TemplateManifest.self, from: data)
        return TemplateCatalog(root: root, manifest: manifest)
    }

    public static func defaultUsageList() -> String {
        if let catalog = try? loadDefault() {
            return catalog.usageList
        }

        return """
          2d               Minimal Processing-style 2D sketch.
          3d               Camera, lights, and animated 3D primitives.
          shader           Sketch with a custom Metal post-process effect.
          live             Parameter GUI, OSC input, MIDI input, and performance HUD.
          audio-reactive   Microphone FFT analysis driving visuals.
          raytracing       MPS/Metal ray tracing starter scene.
          syphon           Fixed-resolution output configured for Syphon.
        """
    }

    private static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let override = ProcessInfo.processInfo.environment["METAPHOR_TEMPLATES_PATH"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }

        // Prefer checkout templates when running from source so template edits are immediately testable.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        roots.append(sourceRoot.appendingPathComponent("Templates"))

        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".local/share/metaphor/templates"))
        roots.append(URL(fileURLWithPath: "/usr/local/share/metaphor/templates"))
        roots.append(URL(fileURLWithPath: "/opt/homebrew/share/metaphor/templates"))

        return roots
    }
}

public struct TemplateContext {
    public let projectName: String
    public let moduleName: String
    public let template: ProjectTemplate
    public let metaphorDependency: String
    public let metaphorPackageIdentity: String
    /// 依存先 metaphor の AI ドキュメント（`llms.txt` 等）がある場所。AGENTS.md の
    /// フォールバック導線に埋め込む。ローカル checkout は絶対パス、リモート版は
    /// 初回ビルド後に現れる `.build/checkouts/metaphor`。
    public let metaphorAIDocsPath: String

    public init(
        projectName: String,
        moduleName: String,
        template: ProjectTemplate,
        metaphorDependency: String,
        metaphorPackageIdentity: String,
        metaphorAIDocsPath: String
    ) {
        self.projectName = projectName
        self.moduleName = moduleName
        self.template = template
        self.metaphorDependency = metaphorDependency
        self.metaphorPackageIdentity = metaphorPackageIdentity
        self.metaphorAIDocsPath = metaphorAIDocsPath
    }
}

public struct GeneratedFile: Equatable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public enum TemplateRenderer {
    public static func files(for context: TemplateContext, catalog: TemplateCatalog) throws -> [GeneratedFile] {
        let specs = catalog.manifest.commonFiles + context.template.files
        let replacements = replacements(for: context)

        return try specs.map { spec in
            let sourceURL = catalog.root.appendingPathComponent(spec.source)
            let template = try String(contentsOf: sourceURL, encoding: .utf8)
            return GeneratedFile(
                path: render(spec.destination, replacements: replacements),
                contents: render(template, replacements: replacements)
            )
        }
    }

    public static func packageSwift(_ context: TemplateContext, catalog: TemplateCatalog) throws -> String {
        try renderedCommonFile("Package.swift", context: context, catalog: catalog)
    }

    public static func appSwift(_ context: TemplateContext, catalog: TemplateCatalog) throws -> String {
        let replacements = replacements(for: context)
        guard let appSpec = context.template.files.first(where: { $0.destination.hasSuffix("App.swift") }) else {
            throw CLIError("Template \(context.template.id) does not define an App.swift file")
        }

        let url = catalog.root.appendingPathComponent(appSpec.source)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return render(contents, replacements: replacements)
    }

    private static func renderedCommonFile(_ destination: String, context: TemplateContext, catalog: TemplateCatalog) throws -> String {
        let replacements = replacements(for: context)
        guard let spec = catalog.manifest.commonFiles.first(where: { $0.destination == destination }) else {
            throw CLIError("Common template file for \(destination) was not found")
        }

        let url = catalog.root.appendingPathComponent(spec.source)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return render(contents, replacements: replacements)
    }

    private static func replacements(for context: TemplateContext) -> [String: String] {
        [
            "PROJECT_NAME": context.projectName,
            "PROJECT_NAME_SWIFT": context.projectName.swiftLiteralEscaped,
            "PROJECT_NAME_JSON": context.projectName.jsonEscaped,
            "MODULE_NAME": context.moduleName,
            "TEMPLATE_ID": context.template.id,
            "METAPHOR_DEPENDENCY": context.metaphorDependency,
            "METAPHOR_PACKAGE_IDENTITY": context.metaphorPackageIdentity,
            "METAPHOR_PACKAGE_IDENTITY_SWIFT": context.metaphorPackageIdentity.swiftLiteralEscaped,
            "METAPHOR_AI_DOCS_PATH": context.metaphorAIDocsPath,
        ]
    }

    private static func render(_ template: String, replacements: [String: String]) -> String {
        replacements.reduce(template) { partial, item in
            partial.replacingOccurrences(of: "{{\(item.key)}}", with: item.value)
        }
    }
}
