import Foundation

/// Syphon サーバ名の安定した既定値を決める。
///
/// MadMapper / Resolume / VDMX などの Syphon クライアントはソース一覧から名前で
/// 選ぶため、名前が毎回変わると人間が選び直す羽目になる。per-pid のような不安定名を
/// 避け、スケッチのディレクトリ名をそのまま既定の安定名として使う。
public enum SyphonName {
    /// `directory` のベース名を安定した Syphon 名として返す（空や `/` のときは "metaphor"）。
    public static func stable(for directory: URL) -> String {
        let base = directory.lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return base.isEmpty ? "metaphor" : base
    }
}
