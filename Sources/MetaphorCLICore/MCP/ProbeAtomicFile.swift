import Foundation

/// Probe `request.json` のアトミック書き込みヘルパー（CONTRACT.md 契約点 4）。
///
/// consumer は `request.json` を必ず「`.tmp` へ書いてから rename で確定」する規約。
/// `rename(2)` は同一ボリューム内で既存の宛先を**原子的に**置き換えるため、
/// producer が部分書き込み途中のファイルを読む TOCTOU も、`removeItem` →
/// `moveItem` の 2 段階で出力が存在しない瞬間窓ができる問題も生じない
/// （producer 側 `ProbeWriter.atomicReplace` と対称）。
enum ProbeAtomicFile {
    /// `tmp` に書き込み済みの内容を `final` へ原子的に反映する。
    static func replace(tmp: URL, final: URL) throws {
        let result = tmp.withUnsafeFileSystemRepresentation { tmpPath -> Int32 in
            final.withUnsafeFileSystemRepresentation { finalPath -> Int32 in
                guard let tmpPath, let finalPath else { return -1 }
                return rename(tmpPath, finalPath)
            }
        }
        if result != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: final.path,
                NSLocalizedDescriptionKey:
                    "rename(2) failed for \(final.lastPathComponent) (errno \(errno))",
            ])
        }
    }
}
