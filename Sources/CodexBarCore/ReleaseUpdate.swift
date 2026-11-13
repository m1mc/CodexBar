import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ReleaseUpdateError: LocalizedError, Equatable, Sendable {
    case requestFailed(String)
    case invalidResponse
    case missingAsset(String)
    case checksumMissing(String)
    case checksumMismatch(String)
    case downloadFailed(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(details):
            "Could not reach the CodexBar release feed: \(details)"
        case .invalidResponse:
            "The CodexBar release feed returned an unexpected response."
        case let .missingAsset(name):
            "The release is missing \(name)."
        case let .checksumMissing(name):
            "SHA256SUMS.txt does not contain \(name)."
        case let .checksumMismatch(name):
            "\(name) failed its SHA-256 verification."
        case let .downloadFailed(details):
            "Could not download the CodexBar release: \(details)"
        case let .installFailed(details):
            "Could not install the CodexBar release: \(details)"
        }
    }
}

public struct ReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let downloadURL: URL

    public init(name: String, downloadURL: URL) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let version: String
    public let htmlURL: URL
    public let assets: [ReleaseAsset]

    public init(tag: String, version: String, htmlURL: URL, assets: [ReleaseAsset]) {
        self.tag = tag
        self.version = version
        self.htmlURL = htmlURL
        self.assets = assets
    }

    public func asset(named name: String) -> ReleaseAsset? {
        self.assets.first { $0.name == name }
    }
}

public enum ReleaseVersion {
    /// Strips the leading `v` used by GitHub tags and keeps prerelease suffixes intact.
    public static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        return value
    }

    /// Numeric comparison for the fork's release tags. Prereleases are ignored here because the
    /// stable release feed never offers them.
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = self.components(lhs)
        let right = self.components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        self.compare(candidate, installed) > 0
    }

    private static func components(_ raw: String) -> [Int] {
        let core = self.normalized(raw).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let core, !core.isEmpty else { return [] }
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}

public enum ReleaseUpdateClient {
    public static let repository = "m1mc/CodexBar"
    public static let apiBaseURL = URL(string: "https://api.github.com")!
    public static let downloadRootURL = URL(string: "https://github.com")!
    public static let releasesURL = URL(string: "https://github.com/m1mc/CodexBar/releases/latest")!

    public static func latestRelease(
        apiBaseURL: URL = Self.apiBaseURL,
        timeout: TimeInterval = 20) async throws -> ReleaseInfo
    {
        let url = apiBaseURL.appendingPathComponent("repos/\(Self.repository)/releases/latest")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // GitHub's unauthenticated API can be rate-limited; the release page redirect
                // remains available and identifies the same tag and assets.
                return try await self.latestReleaseFromRedirect(timeout: timeout)
            }
            return try self.decodeRelease(data)
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            return try await self.latestReleaseFromRedirect(timeout: timeout)
        }
    }

    public static func latestReleaseFromRedirect(timeout: TimeInterval = 20) async throws -> ReleaseInfo {
        var request = URLRequest(url: self.releasesURL, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let finalURL = response.url,
                  let tag = self.tagFromReleaseURL(finalURL)
            else {
                throw ReleaseUpdateError.requestFailed("could not resolve the latest release tag")
            }
            let downloadBase = URL(string: "https://github.com/\(self.repository)/releases/latest/download")!
            let assetNames = [
                "CodexBar-macOS.dmg",
                "SHA256SUMS.txt",
                "CodexBarCLI-macos-arm64.tar.gz",
                "CodexBarCLI-macos-x86_64.tar.gz",
                "CodexBarCLI-linux-x86_64.tar.gz",
            ]
            let assets = assetNames.map {
                ReleaseAsset(name: $0, downloadURL: downloadBase.appendingPathComponent($0))
            }
            return ReleaseInfo(
                tag: tag,
                version: ReleaseVersion.normalized(tag),
                htmlURL: finalURL,
                assets: assets)
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw ReleaseUpdateError.requestFailed(error.localizedDescription)
        }
    }

    private static func tagFromReleaseURL(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count else { return nil }
        let tag = String(parts[index + 1])
        guard tag.hasPrefix("v") else { return nil }
        return tag
    }

    public static func decodeRelease(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }

            let tagName: String
            let htmlURL: URL
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let assets = payload.assets.map {
                ReleaseAsset(name: $0.name, downloadURL: $0.browserDownloadURL)
            }
            return ReleaseInfo(
                tag: payload.tagName,
                version: ReleaseVersion.normalized(payload.tagName),
                htmlURL: payload.htmlURL,
                assets: assets)
        } catch {
            throw ReleaseUpdateError.invalidResponse
        }
    }

    public static func download(
        _ asset: ReleaseAsset,
        to directory: URL,
        timeout: TimeInterval = 60) async throws -> URL
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: asset.downloadURL, timeoutInterval: timeout)
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ReleaseUpdateError.downloadFailed(
                    "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let destination = directory.appendingPathComponent(asset.name)
            try? FileManager.default.removeItem(at: destination)
            try data.write(to: destination)
            return destination
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw ReleaseUpdateError.downloadFailed(error.localizedDescription)
        }
    }

    public static func downloadText(
        _ asset: ReleaseAsset,
        timeout: TimeInterval = 20) async throws -> String
    {
        var request = URLRequest(url: asset.downloadURL, timeoutInterval: timeout)
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ReleaseUpdateError.downloadFailed(
                    "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ReleaseUpdateError.downloadFailed("response is not UTF-8 text")
            }
            return text
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw ReleaseUpdateError.downloadFailed(error.localizedDescription)
        }
    }

    public static func checksum(named name: String, in checksumsText: String) throws -> String {
        for line in checksumsText.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let checksum = String(fields[0]).lowercased()
            let fileName = String(fields[1]).trimmingCharacters(in: .whitespaces)
            if fileName == name || fileName == "*\(name)" {
                guard checksum.count == 64, checksum.allSatisfy(\.isHexDigit) else {
                    throw ReleaseUpdateError.invalidResponse
                }
                return checksum
            }
        }
        throw ReleaseUpdateError.checksumMissing(name)
    }

    public static func verifySHA256(_ fileURL: URL, expected: String) throws {
        let actual = try self.sha256(fileURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw ReleaseUpdateError.checksumMismatch(fileURL.lastPathComponent)
        }
    }

    public static func sha256(_ fileURL: URL) throws -> String {
        var hash = SHA256()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ReleaseUpdateState: Codable, Equatable, Sendable {
    public var lastCheckAt: Date?
    public var availableVersion: String?
    public var checkedTag: String?
    public var lastNoticeAt: Date?
    public var lastNotifiedVersion: String?

    public init(
        lastCheckAt: Date? = nil,
        availableVersion: String? = nil,
        checkedTag: String? = nil,
        lastNoticeAt: Date? = nil,
        lastNotifiedVersion: String? = nil)
    {
        self.lastCheckAt = lastCheckAt
        self.availableVersion = availableVersion
        self.checkedTag = checkedTag
        self.lastNoticeAt = lastNoticeAt
        self.lastNotifiedVersion = lastNotifiedVersion
    }
}

public enum ReleaseUpdateStateStore {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment["CODEXBAR_UPDATE_STATE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/codexbar/update-state.json")
    }

    public static func load(from url: URL = Self.defaultURL()) -> ReleaseUpdateState {
        guard let data = try? Data(contentsOf: url) else { return ReleaseUpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReleaseUpdateState.self, from: data)) ?? ReleaseUpdateState()
    }

    public static func save(_ state: ReleaseUpdateState, to url: URL = Self.defaultURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    public static func isDue(_ state: ReleaseUpdateState, now: Date = Date()) -> Bool {
        guard let last = state.lastCheckAt else { return true }
        return now.timeIntervalSince(last) >= self.checkInterval
    }
}
