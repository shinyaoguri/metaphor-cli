import Foundation

public enum BuildInfo {
    public static let name = "metaphor"
    public static let version = "0.1.0-dev"
    public static let defaultMetaphorVersion = "0.2.3"
    public static let cliRepositoryOwner = "shinyaoguri"
    public static let cliRepositoryName = "metaphor-cli"
    public static let libraryRepositoryOwner = "shinyaoguri"
    public static let libraryRepositoryName = "metaphor"

    /// 実行中バイナリのビルド識別子（実行ファイルの更新時刻）。
    /// どのビルド/インストールが動いているかを実行時に判別するために使う。
    /// 再ビルド/再インストールのたびに変わるので、最新版かどうかが分かる。
    public static var buildStamp: String {
        guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return "unknown"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    /// バージョン + ビルド識別子の1行表記。
    public static var fullIdentifier: String {
        "\(name) \(version) (built \(buildStamp))"
    }

    /// CLI であることを明示した1行表記（例: `metaphor-cli 0.1.0-dev (built ...)`）。
    /// `watch` のバナーで使う。スケッチ子プロセスは別途 `[metaphor] <版>` を出すため、
    /// CLI 版とライブラリ版がログ上で区別できるよう名前で曖昧さを消す。
    public static var cliIdentifier: String {
        "\(name)-cli \(version) (built \(buildStamp))"
    }
}
