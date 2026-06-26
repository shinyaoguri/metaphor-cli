import Foundation

/// スケッチの依存先 metaphor パッケージの「AI ドキュメント・ルート」を解決する。
///
/// `metaphor mcp` の `api_reference` ツールが、生成プロジェクトから見て
/// `llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.md` がどこにあるかを
/// 知るために使う。依存の張られ方が 2 通りあるため両方を候補に挙げ、
/// 実際に `llms.txt` を含むディレクトリを採用する。
///
/// - url 依存（`.package(url:…)`）: SwiftPM がビルド時に
///   `<sketch>/.build/checkouts/metaphor/` へ checkout する。
/// - path 依存（`.package(path:…)`）: ローカル checkout をそのまま参照する。
public struct MetaphorDocsLocator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// metaphor の docs ルート（`llms.txt` がある場所）。解決できなければ nil。
    public func resolve(sketchDirectory: URL) -> URL? {
        for candidate in candidates(sketchDirectory: sketchDirectory) {
            let marker = candidate.appendingPathComponent("llms.txt").path
            if fileManager.fileExists(atPath: marker) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private func candidates(sketchDirectory: URL) -> [URL] {
        var result: [URL] = []
        // ① url 依存: SwiftPM の checkout 先（初回ビルド後に出現）。
        result.append(sketchDirectory.appendingPathComponent(".build/checkouts/metaphor"))
        // ② path 依存: Package.swift の .package(path: "X")（複数あれば全部）。
        for path in localPackagePaths(sketchDirectory: sketchDirectory) {
            if path.hasPrefix("/") {
                result.append(URL(fileURLWithPath: path))
            } else {
                result.append(sketchDirectory.appendingPathComponent(path))
            }
        }
        return result
    }

    private func localPackagePaths(sketchDirectory: URL) -> [String] {
        let packageURL = sketchDirectory.appendingPathComponent("Package.swift")
        guard let source = try? String(contentsOf: packageURL, encoding: .utf8) else { return [] }
        return Self.packagePaths(in: source)
    }

    /// Package.swift ソースから `.package(path: "….")` のパスを順に抽出する。
    static func packagePaths(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\.package\s*\(\s*path:\s*"([^"]+)""#
        ) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        }
    }
}
