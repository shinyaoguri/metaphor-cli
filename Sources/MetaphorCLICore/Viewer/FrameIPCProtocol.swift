import Darwin
import Foundation

// MARK: - Wire format（CONTRACT.md 契約点 5: viewer frame IPC）

/// 子スケッチ（`ViewerOutputPlugin`）が接続直後と resize のたびに送る world の宣言。
/// この行を運ぶ `sendmsg` に共有メモリの fd が `SCM_RIGHTS` で添えられる。
///
/// JSON の構造は `contract/viewer-hello.schema.json` が正典。未知のキーは無視する
/// （契約点 3 と同じ規約）。必須キーが欠けていればデコードに失敗し、その行は捨てる。
public struct ViewerHello: Decodable, Equatable {
    public let protocolVersion: Int
    public let pid: Int32
    /// 子がリンクしている metaphor の版文字列。
    public let metaphor: String
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let alpha: String
    public let colorSpace: String
    public let orientation: String
    /// 1 行のバイト数（linear texture の alignment に切り上げ済み）。
    public let bytesPerRow: Int
    /// 1 slot のバイト数（page 境界に切り上げ済み）。slot i は offset `i * slotBytes`。
    public let slotBytes: Int
    public let slots: Int
    public let backing: String

    public init(
        protocolVersion: Int, pid: Int32, metaphor: String, width: Int, height: Int,
        pixelFormat: String, alpha: String, colorSpace: String, orientation: String,
        bytesPerRow: Int, slotBytes: Int, slots: Int, backing: String
    ) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.metaphor = metaphor
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.alpha = alpha
        self.colorSpace = colorSpace
        self.orientation = orientation
        self.bytesPerRow = bytesPerRow
        self.slotBytes = slotBytes
        self.slots = slots
        self.backing = backing
    }

    /// 共有メモリ全体のバイト数（`fstat` のサイズと一致するはず）。
    public var totalBytes: Int { slotBytes * slots }

    /// この viewer が扱える world か。v1 は `bgra8Unorm` / 3 slot / `posix-shm` だけを受ける。
    /// 受けられない理由を返す（nil なら受けられる）。
    public var unsupportedReason: String? {
        if protocolVersion != FrameIPC.protocolVersion {
            return "protocolVersion \(protocolVersion) は未対応（この viewer は \(FrameIPC.protocolVersion)）"
        }
        if backing != "posix-shm" { return "backing '\(backing)' は未対応" }
        if pixelFormat != "bgra8Unorm" { return "pixelFormat '\(pixelFormat)' は未対応" }
        if width <= 0 || height <= 0 { return "サイズが不正 (\(width)x\(height))" }
        if slots < 1 { return "slots が不正 (\(slots))" }
        if bytesPerRow < width * 4 { return "bytesPerRow が小さすぎる (\(bytesPerRow) < \(width * 4))" }
        if slotBytes < bytesPerRow * height { return "slotBytes が小さすぎる (\(slotBytes) < \(bytesPerRow * height))" }
        return nil
    }
}

/// 子が「slot の内容が確定した」と知らせる行（command buffer の完了ハンドラから送られる）。
/// 親は最新の `frame` だけを表示する（latest-wins）。
public struct ViewerFrame: Decodable, Equatable {
    public let slot: Int
    /// 単調増加の通し番号。
    public let seq: Int
    /// スケッチの `frameCount`（`--metrics` や診断用。省略可）。
    public let frameCount: Int?
    /// スケッチの `time`（秒。省略可）。
    public let time: Double?

    public init(slot: Int, seq: Int, frameCount: Int? = nil, time: Double? = nil) {
        self.slot = slot
        self.seq = seq
        self.frameCount = frameCount
        self.time = time
    }
}

/// 子 → 親の 1 行を種別で分けたもの。
public enum FrameIPCMessage: Equatable {
    case hello(ViewerHello)
    case frame(ViewerFrame)
    case bye
}

public enum FrameIPC {
    /// この viewer が話す wire の版。bump 規則は CONTRACT.md の schemaVersion と同じ
    /// （キー追加は据え置き、リネーム / 削除 / 意味変更で bump）。
    public static let protocolVersion = 1

    /// JSON Lines の 1 行（改行なし）を解釈する。未知の `t` や JSON でない行は nil
    /// （黙って捨てる = 契約点 3 と同じ寛容さ）。
    public static func decode(line: String) -> FrameIPCMessage? {
        guard let data = line.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let tag = try? decoder.decode(Tagged.self, from: data) else { return nil }
        switch tag.t {
        case "hello":
            return (try? decoder.decode(ViewerHello.self, from: data)).map { .hello($0) }
        case "frame":
            return (try? decoder.decode(ViewerFrame.self, from: data)).map { .frame($0) }
        case "bye":
            return .bye
        default:
            return nil
        }
    }

    /// 親 → 子の `release`（slot の GPU 読みを終えた）1 行。改行は付けない。
    public static func releaseLine(slot: Int) -> String {
        "{\"t\":\"release\",\"slot\":\(slot)}"
    }

    private struct Tagged: Decodable {
        let t: String
    }
}

// MARK: - Socket path

public enum ViewerSocketPath {
    /// `sockaddr_un.sun_path` の上限（終端 NUL を除く）。macOS は 104 byte の配列なので 103。
    public static let maximumLength = MemoryLayout<sockaddr_un>.size
        - MemoryLayout<sa_family_t>.size - MemoryLayout<UInt8>.size - 1

    /// watch プロセス固有の socket パス。`.metaphor/` ではなく短い一時ディレクトリに置く
    /// （プロジェクトが同期フォルダ配下でも汚さず、`sun_path` の上限にも収まる）。
    /// 上限を超えるなら nil（呼び出し側がエラーにする）。
    public static func make(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let path = directory.appendingPathComponent("metaphor-viewer-\(pid).sock").path
        return path.utf8.count <= maximumLength ? path : nil
    }
}
