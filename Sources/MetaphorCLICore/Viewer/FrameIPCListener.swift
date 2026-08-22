import CMetaphorFrameIPC
import Darwin
import Foundation

/// live viewer の frame IPC（CONTRACT.md 契約点 5）の親側ソケット。
///
/// `AF_UNIX` / `SOCK_STREAM` の socket を bind + listen し、子スケッチ（`ViewerOutputPlugin`）
/// からの接続を受けて JSON Lines を読む。`hello` に添えられた共有メモリの fd は
/// `SCM_RIGHTS` で受け取り、`hello` とともにイベントで渡す（fd の所有権は受け手へ移る）。
///
/// - **世代**: 接続 1 本 = 子 1 プロセス。accept した順に世代番号を振り、新しい接続が来たら
///   旧接続は閉じる（`watch` は旧子を止めてから新子を起動するので、接続順 = 起動順）。
/// - **スレッド**: accept と読み取りは `queue`（既定 `.main`）上の `DispatchSource` で行い、
///   状態はそのキューに限定する。``onEvent`` も同じキューで呼ぶ。
/// - Metal には依存しない（共有メモリの mapping は `FrameIPCSource` の仕事）。
public final class FrameIPCListener {
    public enum Event: Equatable {
        /// 子が接続した（まだ `hello` は来ていない）。
        case connected(generation: Int)
        /// world の宣言。`fd` は共有メモリ（受け手が `close` する責任を持つ）。
        case hello(generation: Int, hello: ViewerHello, fd: Int32)
        /// slot の内容が確定した。
        case frame(generation: Int, frame: ViewerFrame)
        /// 子の正常終了（任意）。
        case bye(generation: Int)
        /// 接続が閉じた（子の終了・クラッシュ・新しい接続による置き換え）。
        case disconnected(generation: Int)
    }

    public let path: String
    /// イベントの受け手。`queue` 上で呼ばれる。
    public var onEvent: ((Event) -> Void)?
    /// 診断メッセージ（stderr 相当）の受け手。
    public var onDiagnostic: ((String) -> Void)?

    private let queue: DispatchQueue
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connection: Connection?
    private var nextGeneration = 1
    private var isStopped = false

    /// 現在の接続の世代（無ければ nil）。
    public var currentGeneration: Int? { connection?.generation }

    /// `path` に bind + listen する。古い socket ファイルが残っていれば先に unlink する。
    /// - Throws: `CLIError`（パスが長すぎる / bind できない）。
    public init(path: String, queue: DispatchQueue = .main) throws {
        self.path = path
        self.queue = queue

        guard path.utf8.count <= ViewerSocketPath.maximumLength else {
            throw CLIError("ビューアの socket パスが長すぎます (\(path.utf8.count) byte > \(ViewerSocketPath.maximumLength))", exitCode: 2)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError("ビューアの socket を作成できません: \(String(cString: strerror(errno)))", exitCode: 2)
        }
        unlink(path)  // 前回の異常終了で残った stale な socket ファイル。
        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw CLIError("ビューアの socket を開けません (\(path)): \(reason)", exitCode: 2)
        }
        Self.setNonBlocking(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    deinit {
        stop()
    }

    /// 現在の接続へ `release` を送る（接続が無ければ何もしない）。
    public func send(release slot: Int) {
        connection?.send(line: FrameIPC.releaseLine(slot: slot))
    }

    /// 接続と listen socket を閉じ、socket ファイルを消す。以後イベントは出ない。
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        connection?.close()
        connection = nil
        unlink(path)
    }

    // MARK: - Private

    private func acceptPending() {
        guard !isStopped else { return }
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                return  // EAGAIN（今は無い）か、エラー。どちらも次のイベントを待つ。
            }
            Self.setNonBlocking(fd)
            // 閉じた相手へ書いても SIGPIPE でプロセスが死なないようにする（write は EPIPE で返る）。
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            if let previous = connection {
                // 子 1 プロセス = 接続 1 本。新しい子が来たら旧接続は役目を終えている。
                previous.close()
                connection = nil
                onEvent?(.disconnected(generation: previous.generation))
            }
            let generation = nextGeneration
            nextGeneration += 1
            let conn = Connection(fd: fd, generation: generation, queue: queue, owner: self)
            connection = conn
            onEvent?(.connected(generation: generation))
            conn.resume()
        }
    }

    /// 接続側からの呼び出し。
    fileprivate func connectionDidRead(_ conn: Connection, line: String, fd: Int32) -> Int32 {
        guard conn === connection else { return fd }
        switch FrameIPC.decode(line: line) {
        case .hello(let hello)?:
            guard fd >= 0 else {
                onDiagnostic?("[viewer] hello に共有メモリの fd が添えられていません（無視します）")
                return -1
            }
            onEvent?(.hello(generation: conn.generation, hello: hello, fd: fd))
            return -1  // fd は受け手へ渡した。
        case .frame(let frame)?:
            onEvent?(.frame(generation: conn.generation, frame: frame))
        case .bye?:
            onEvent?(.bye(generation: conn.generation))
        case nil:
            break  // 未知の `t` / 壊れた行は黙って捨てる。
        }
        return fd
    }

    fileprivate func connectionDidClose(_ conn: Connection) {
        guard conn === connection else { return }
        connection = nil
        onEvent?(.disconnected(generation: conn.generation))
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// `sockaddr_un` を組み立てる（パス長は呼び出し側で検証済み）。
    public static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strlcpy($0, path, capacity)
            }
        }
        return address
    }
}

/// 1 本の接続。読み取りは `DispatchSource` で、改行で区切って 1 行ずつ owner へ渡す。
private final class Connection {
    let generation: Int
    private var fd: Int32
    private let source: DispatchSourceRead
    private unowned let owner: FrameIPCListener
    private var buffer = Data()
    /// `recvmsg` で受け取ったがまだ `hello` に結び付けていない fd。
    /// `hello` の fd は同じ `sendmsg` に載るので、その行の先頭を含む受信で届く。
    private var pendingFD: Int32 = -1
    private var isClosed = false

    init(fd: Int32, generation: Int, queue: DispatchQueue, owner: FrameIPCListener) {
        self.fd = fd
        self.generation = generation
        self.owner = owner
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
    }

    func resume() {
        source.resume()
    }

    func send(line: String) {
        guard !isClosed, let data = (line + "\n").data(using: .utf8) else { return }
        // 1 行は短い（PIPE_BUF 未満）ので write はアトミック。空きが無ければ EAGAIN で
        // その行は捨てる（release の取りこぼしは子が publish を飛ばすだけで、描画は止まらない）。
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(fd, base, raw.count)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
        Darwin.close(fd)
        fd = -1
        if pendingFD >= 0 {
            Darwin.close(pendingFD)
            pendingFD = -1
        }
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var receivedFD: Int32 = -1
        let n = chunk.withUnsafeMutableBytes { raw in
            metaphor_recv_fd(fd, raw.baseAddress, raw.count, &receivedFD)
        }
        if receivedFD >= 0 {
            if pendingFD >= 0 {
                Darwin.close(pendingFD)  // 結び付け先の無い fd は捨てる（二重 hello の取りこぼし）。
            }
            pendingFD = receivedFD
        }
        if n == 0 {
            // EOF: 子が終了した（正常・クラッシュとも）。
            close()
            owner.connectionDidClose(self)
            return
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            close()
            owner.connectionDidClose(self)
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        drainLines()
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            pendingFD = owner.connectionDidRead(self, line: line, fd: pendingFD)
            if isClosed { return }
        }
    }
}
