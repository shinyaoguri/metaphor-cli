import Foundation

/// `.metaphor/` 配下のファイル契約（Probe / Parameter Store / State）の**基準ディレクトリ**
/// を解決します（CONTRACT.md 契約点 2。producer 側は metaphor の `MetaphorPaths.swift`）。
///
/// これらは従来スケッチディレクトリ（＝子プロセスの cwd）相対で解決していました。
/// ところが **`.app` を LaunchServices から起動すると cwd が `/`** になるため、
/// 常設運用に近い形では producer（スケッチ）と consumer（cli）が別の場所を見てしまい、
/// Probe の応答が返らない・パラメータが永続化されない、という壊れ方をします
/// （metaphor#688 / #133）。
///
/// 環境変数 `METAPHOR_STATE_DIR` があれば、両者ともそこを基準にします。
/// **未設定なら従来どおり**スケッチディレクトリ基準です（additive な追加）。
public enum MetaphorStateDirectory {
    /// 基準ディレクトリを与える環境変数の名前（契約点 2）。
    public static let environmentKey = "METAPHOR_STATE_DIR"

    /// `.metaphor/` を置く基準ディレクトリ。
    ///
    /// - Parameters:
    ///   - sketchDirectory: スケッチのディレクトリ（環境変数が無いときの既定）。
    ///   - environment: 参照する環境（テスト用に差し替え可能）。
    public static func base(
        for sketchDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let raw = environment[environmentKey],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return sketchDirectory
        }
        let expanded = NSString(string: raw).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        // 相対指定は cli 自身の cwd 基準で絶対化してから使う（producer 側と同じ規則）。
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded).standardizedFileURL
    }

    /// `.metaphor/` そのもののパス。
    public static func root(
        for sketchDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        base(for: sketchDirectory, environment: environment)
            .appendingPathComponent(".metaphor", isDirectory: true)
    }
}
