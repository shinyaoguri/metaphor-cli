import Foundation

/// ビルド済みスケッチの実行ファイルパスを解決する抽象。
///
/// `swift run` 経由だと SwiftPM のロック競合時に exec せず fork してプロセスが
/// 二重化しうるため、watch ではビルド済みバイナリを直接起動する。その実行ファイルの
/// 場所を求めるのがこの責務。テストではスタブを注入して実 swift 呼び出しを避ける。
public protocol SketchBinaryResolving {
    /// `directory` のパッケージをビルドした場合の実行ファイルパス。解決できなければ nil。
    func resolve(directory: URL, swiftArguments: [String]) -> String?
}

/// `swift build --show-bin-path` と `swift package dump-package` を使って実行ファイルを
/// 解決する実装。
public struct SwiftPMBinaryResolver: SketchBinaryResolving {
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    /// 解決失敗の原因を残すための任意ロガー。nil ならサイレント（従来動作）。
    private let console: (any Console)?

    public init(
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        console: (any Console)? = nil
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.console = console
    }

    public func resolve(directory: URL, swiftArguments: [String]) -> String? {
        guard let binDir = binPath(directory: directory, swiftArguments: swiftArguments),
              let product = firstExecutableProduct(directory: directory) else {
            return nil
        }
        let path = (binDir as NSString).appendingPathComponent(product)
        guard fileManager.isExecutableFile(atPath: path) else {
            console?.writeError(
                "[watch] バイナリ解決に失敗（\(path) が実行可能でない）— swift run にフォールバックします")
            return nil
        }
        return path
    }

    /// `swift build --show-bin-path` の出力（ビルド成果物ディレクトリ）。
    private func binPath(directory: URL, swiftArguments: [String]) -> String? {
        let result: ProcessResult
        do {
            result = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: ["swift", "build", "--show-bin-path"] + swiftArguments,
                currentDirectory: directory,
                captureOutput: true
            )
        } catch {
            console?.writeError("[watch] バイナリ解決に失敗（swift build --show-bin-path）: \(error) — swift run にフォールバックします")
            return nil
        }
        guard result.exitCode == 0 else {
            console?.writeError("[watch] バイナリ解決に失敗（swift build --show-bin-path が exit \(result.exitCode)）— swift run にフォールバックします")
            return nil
        }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// `swift package dump-package` の JSON から実行ファイル名を得る。
    ///
    /// `products` に executable があればその名前。`products` 宣言のないパッケージ
    /// （`executableTarget` だけの、example・テンプレートの標準形）では SwiftPM が
    /// **ターゲット名**で実行ファイルを生成するので、executable ターゲット名へ
    /// フォールバックする。ここが nil を返すと呼び出し側は毎リロードで
    /// dump-package をやり直すため、解決できない理由は必ずログに残す。
    private func firstExecutableProduct(directory: URL) -> String? {
        let result: ProcessResult
        do {
            result = try processRunner.run(
                executable: "/usr/bin/env",
                arguments: ["swift", "package", "dump-package"],
                currentDirectory: directory,
                captureOutput: true
            )
        } catch {
            console?.writeError("[watch] バイナリ解決に失敗（swift package dump-package）: \(error) — swift run にフォールバックします")
            return nil
        }
        guard result.exitCode == 0,
        let data = result.standardOutput.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            console?.writeError("[watch] バイナリ解決に失敗（dump-package が exit \(result.exitCode) / JSON 解釈不能）— swift run にフォールバックします")
            return nil
        }
        // executable プロダクトは type に "executable" キーを持つ（辞書形式）。
        if let products = json["products"] as? [[String: Any]] {
            for product in products {
                if let type = product["type"] as? [String: Any], type.keys.contains("executable"),
                   let name = product["name"] as? String {
                    return name
                }
            }
        }
        // executable ターゲットの type は文字列 "executable"。
        if let targets = json["targets"] as? [[String: Any]] {
            for target in targets {
                if target["type"] as? String == "executable",
                   let name = target["name"] as? String {
                    return name
                }
            }
        }
        console?.writeError("[watch] バイナリ解決に失敗（executable product/target が見つからない）— swift run にフォールバックします")
        return nil
    }
}
