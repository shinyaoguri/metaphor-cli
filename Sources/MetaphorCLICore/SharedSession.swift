import Darwin
import Foundation

/// 共有セッション（`metaphor watch` が所有し `metaphor mcp` がアタッチして観測する）
/// のための、`.metaphor/` 配下のファイルプロトコル。
///
/// 設計の要点（`docs/design/shared-session.md`）:
/// - `metaphor watch` が唯一の所有者として build / spawn / 差し替え / ビューアを担い、
///   子を `METAPHOR_PROBE=1` で起動する。
/// - `metaphor mcp` は生存セッションを検出するとアタッチモードに入り、**子を spawn
///   せず・build せず**、既存の Probe ファイル往復で `snapshot` し、`build-status.json`
///   で `build_status` を返す。
/// - 編集は人間も AI も「ディスク上のファイルを直接書く」だけで共有され、watch が
///   再ビルドする。新しいトランスポートは不要（Probe と同じファイル IPC）。
///
/// すべて単一マシンのローカルファイル。`session.json` の `pid` 生存確認で stale を弾く。
public enum SharedSession {
    /// `session.json` / `build-status.json` のスキーマバージョン。
    public static let schemaVersion = 1

    // MARK: - Paths

    /// `<sketch>/.metaphor`
    public static func metaphorDirectory(for sketchDirectory: URL) -> URL {
        sketchDirectory.appendingPathComponent(".metaphor", isDirectory: true)
    }

    /// `<sketch>/.metaphor/session.json`
    public static func manifestURL(for sketchDirectory: URL) -> URL {
        metaphorDirectory(for: sketchDirectory).appendingPathComponent("session.json")
    }

    /// `<sketch>/.metaphor/build-status.json`
    public static func buildStatusURL(for sketchDirectory: URL) -> URL {
        metaphorDirectory(for: sketchDirectory).appendingPathComponent("build-status.json")
    }

    // MARK: - Manifest

    /// セッション所有者（`metaphor watch`）が書き出すマニフェスト。
    public struct Manifest: Codable, Equatable {
        public let schemaVersion: Int
        /// 所有者（watch supervisor）のプロセス ID。アタッチ側はこの生存を確認する。
        public let pid: Int32
        /// 対象スケッチの絶対パス。
        public let sketchPath: String
        /// 子が publish する Syphon サーバー名（人間がビューアで覗くため）。
        public let syphonName: String?
        /// 子が `METAPHOR_PROBE=1` で起動されているか（false だと snapshot 不可）。
        public let probeEnabled: Bool
        /// 起動時刻（ISO8601）。
        public let startedAt: String

        public init(
            pid: Int32,
            sketchPath: String,
            syphonName: String?,
            probeEnabled: Bool,
            startedAt: String
        ) {
            self.schemaVersion = SharedSession.schemaVersion
            self.pid = pid
            self.sketchPath = sketchPath
            self.syphonName = syphonName
            self.probeEnabled = probeEnabled
            self.startedAt = startedAt
        }
    }

    /// マニフェストを atomic（tmp → rename）に書き出す。
    public static func writeManifest(_ manifest: Manifest, for sketchDirectory: URL) {
        writeJSONAtomically(manifest, to: manifestURL(for: sketchDirectory))
    }

    /// マニフェストを削除する（セッション終了時）。
    public static func removeManifest(for sketchDirectory: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: sketchDirectory))
    }

    /// マニフェストを読む（存在しない/壊れていれば nil）。生存確認はしない。
    public static func readManifest(for sketchDirectory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: sketchDirectory)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// 生存しているセッションのマニフェストだけを返す。pid が死んでいれば（stale）nil。
    public static func liveManifest(for sketchDirectory: URL) -> Manifest? {
        guard let manifest = readManifest(for: sketchDirectory) else { return nil }
        return isProcessAlive(manifest.pid) ? manifest : nil
    }

    /// `kill(pid, 0)` でプロセス生存を判定する。0 なら生存、EPERM も生存（権限不足）、
    /// ESRCH なら不在。
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Build status

    /// 直近ビルドの結果を atomic に書き出す（watch が毎ビルド更新）。
    public static func writeBuildStatus(_ outcome: BuildOutcome, for sketchDirectory: URL) {
        writeJSONAtomically(outcome, to: buildStatusURL(for: sketchDirectory))
    }

    /// 直近ビルドの結果を読む（存在しない/壊れていれば nil）。
    public static func readBuildStatus(for sketchDirectory: URL) -> BuildOutcome? {
        guard let data = try? Data(contentsOf: buildStatusURL(for: sketchDirectory)) else { return nil }
        return try? JSONDecoder().decode(BuildOutcome.self, from: data)
    }

    // MARK: - Private

    private static func writeJSONAtomically<T: Encodable>(_ value: T, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }

        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
