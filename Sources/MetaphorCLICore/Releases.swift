import CryptoKit
import Foundation

public struct GitHubRelease: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public let tagName: String
    public let name: String?
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case prerelease
        case assets
    }
}

public protocol ReleaseServicing {
    func latestRelease(owner: String, repo: String) throws -> GitHubRelease
    func download(from url: URL) throws -> Data
}

public final class GitHubReleaseService: ReleaseServicing {
    private let httpClient: any HTTPClient

    public init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func latestRelease(owner: String, repo: String) throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        let data = try httpClient.get(url)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    public func download(from url: URL) throws -> Data {
        try httpClient.get(url)
    }
}

public protocol HTTPClient {
    func get(_ url: URL) throws -> Data
}

public final class URLSessionHTTPClient: HTTPClient {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func get(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("metaphor-cli/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(error)
                return
            }

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                result = .failure(CLIError("HTTP \(http.statusCode) while requesting \(url.absoluteString)"))
                return
            }

            result = .success(data ?? Data())
        }

        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw CLIError("Timed out while requesting \(url.absoluteString)")
        }

        return try result?.get() ?? Data()
    }
}

public final class StubReleaseService: ReleaseServicing {
    public var releases: [String: GitHubRelease] = [:]
    public var downloads: [URL: Data] = [:]

    public init() {}

    public func latestRelease(owner: String, repo: String) throws -> GitHubRelease {
        let key = "\(owner)/\(repo)"
        guard let release = releases[key] else {
            throw CLIError("No stubbed release for \(key)")
        }
        return release
    }

    public func download(from url: URL) throws -> Data {
        guard let data = downloads[url] else {
            throw CLIError("No stubbed download for \(url.absoluteString)")
        }
        return data
    }
}

public struct SemanticVersion: Comparable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(_ rawValue: String) {
        var value = rawValue
        if value.hasPrefix("v") {
            value.removeFirst()
        }

        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let versionParts = parts[0].split(separator: ".").map(String.init)
        guard versionParts.count >= 3,
              let major = Int(versionParts[0]),
              let minor = Int(versionParts[1]),
              let patch = Int(versionParts[2]) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = parts.count > 1 ? parts[1] : nil
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (l?, r?):
            return l < r
        }
    }
}

public enum Checksum {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func checksum(for assetName: String, in checksumsText: String) -> String? {
        for line in checksumsText.split(whereSeparator: \.isNewline) {
            let pieces = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard pieces.count >= 2 else { continue }
            if pieces.dropFirst().contains(where: { $0.hasSuffix(assetName) || $0 == assetName }) {
                return pieces[0]
            }
        }
        return nil
    }
}

public enum PackageResolvedReader {
    public static func metaphorVersion(in packageDirectory: URL) -> String? {
        let candidates = [
            packageDirectory.appendingPathComponent("Package.resolved"),
            packageDirectory.appendingPathComponent(".swiftpm/configuration/Package.resolved"),
        ]

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let version = metaphorVersion(inResolvedData: data) else {
                continue
            }
            return version
        }
        return nil
    }

    static func metaphorVersion(inResolvedData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let pins = (json["pins"] as? [[String: Any]])
            ?? ((json["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []

        for pin in pins {
            let identity = (pin["identity"] as? String) ?? (pin["package"] as? String)
            let location = pin["location"] as? String
            let isMetaphor = identity == "metaphor" || location?.contains("shinyaoguri/metaphor") == true
            guard isMetaphor,
                  let state = pin["state"] as? [String: Any],
                  let version = state["version"] as? String else {
                continue
            }
            return version
        }

        return nil
    }
}
