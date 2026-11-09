import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CodexStaleGatewayProbeStatus: Equatable, Sendable {
    case alive
    case dead
    case unknown
}

public enum CodexStaleGatewayMigrationOutcome: Equatable, Sendable {
    /// No gateway configured or config file does not exist.
    case clean
    /// Stale CodexBar gateway was detected, verified dead, and safely removed from root config.
    case staleGatewayCleaned(previousURL: String)
    /// CodexBar gateway configuration exists and was probed alive; preserved.
    case activeGatewayPreserved(url: String)
    /// Preserved because URL is unrelated custom service, no CodexBar attribution, multiline strings, unclosed quote, or probe status was indeterminate.
    case preserved(reason: String)
    /// File was modified concurrently during check; aborted to prevent data loss.
    case concurrentModificationDetected
    /// Error during reading or writing.
    case error(String)
}

public struct CodexStaleGatewayMigrationResult: Equatable, Sendable {
    public let outcome: CodexStaleGatewayMigrationOutcome
    public let configPath: String

    public init(outcome: CodexStaleGatewayMigrationOutcome, configPath: String) {
        self.outcome = outcome
        self.configPath = configPath
    }
}

public enum CodexStaleGatewayMigration {
    public static let knownGatewayURLs: Set<String> = [
        "http://127.0.0.1:1456/v1",
        "http://127.0.0.1:1456/v1/",
        "http://localhost:1456/v1",
        "http://localhost:1456/v1/",
        "http://[::1]:1456/v1",
        "http://[::1]:1456/v1/",
    ]

    public static let exactLegacyProviders: Set<String> = [
        "codexbar.openai-oauth",
        "codexbar.openai-oauth.reserve"
    ]

    public static let exactLegacyTableHeaders: Set<String> = [
        "[model_providers.\"codexbar.openai-oauth\"]",
        "[model_providers.\"codexbar.openai-oauth.reserve\"]",
        "[model_providers.'codexbar.openai-oauth']",
        "[model_providers.'codexbar.openai-oauth.reserve']"
    ]

    /// Resolves the default config.toml URL, honoring CODEX_HOME environment variable when present.
    public static func defaultConfigFileURL() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            let expanded = (codexHome as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).appendingPathComponent("config.toml")
        }
        let defaultPath = ("~/.codex/config.toml" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: defaultPath)
    }

    /// Strips trailing comments from a line in a quote-aware manner.
    /// Returns the uncommented text and a flag indicating whether an unclosed quote was encountered.
    public static func stripComment(from line: String) -> (uncommented: String, isUnclosedQuote: Bool) {
        var inQuote = false
        var quoteChar: Character? = nil
        var isEscaped = false
        var result = ""

        for ch in line {
            if isEscaped {
                result.append(ch)
                isEscaped = false
                continue
            }
            if ch == "\\" && inQuote {
                isEscaped = true
                result.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" {
                if inQuote {
                    if ch == quoteChar {
                        inQuote = false
                        quoteChar = nil
                    }
                } else {
                    inQuote = true
                    quoteChar = ch
                }
                result.append(ch)
                continue
            }
            if ch == "#" && !inQuote {
                break
            }
            result.append(ch)
        }
        return (result.trimmingCharacters(in: .whitespaces), inQuote)
    }

    /// Probes the endpoint using Foundation URLSession asynchronously.
    public static func probeEndpoint(url: URL, timeoutSeconds: TimeInterval = 0.5) async -> CodexStaleGatewayProbeStatus {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)

        do {
            let (_, response) = try await session.data(for: request)
            if response is HTTPURLResponse {
                return .alive
            }
            return .unknown
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
                return .dead
            }
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ECONNREFUSED) {
                return .dead
            }
            #endif
            return .unknown
        }
    }

    /// Pure transformation of TOML content without disk I/O.
    public static func sanitizeConfigText(
        _ text: String,
        probe: ((URL) async -> CodexStaleGatewayProbeStatus)? = nil
    ) async -> (sanitized: String, outcome: CodexStaleGatewayMigrationOutcome) {
        // Fail-closed: refuse complex multiline string literals anywhere in the candidate file
        if text.contains("\"\"\"") || text.contains("'''") {
            return (text, .preserved(reason: "multiline_strings_detected"))
        }

        let lines = text.components(separatedBy: "\n")
        var firstTableLineIndex: Int? = nil
        var hasExactLegacyTable = false

        for (idx, line) in lines.enumerated() {
            let (uncommented, isUnclosed) = self.stripComment(from: line)
            if isUnclosed {
                return (text, .preserved(reason: "unclosed_quote_detected"))
            }

            if uncommented.hasPrefix("[") && uncommented.hasSuffix("]") {
                if firstTableLineIndex == nil {
                    firstTableLineIndex = idx
                }
                if exactLegacyTableHeaders.contains(uncommented) {
                    hasExactLegacyTable = true
                }
            }
        }

        let rootEndIndex = firstTableLineIndex ?? lines.count
        var targetURLIndex: Int? = nil
        var targetURLValue: String? = nil
        var targetModelProviderIndex: Int? = nil
        var hasExactLegacyProviderInRoot = false

        for idx in 0..<rootEndIndex {
            let line = lines[idx]
            let (uncommented, isUnclosed) = self.stripComment(from: line)
            if isUnclosed {
                return (text, .preserved(reason: "unclosed_quote_detected"))
            }
            guard !uncommented.isEmpty else { continue }

            guard let eqIdx = uncommented.firstIndex(of: "=") else { continue }
            let key = uncommented[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let val = uncommented[uncommented.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

            if key == "openai_base_url" {
                if targetURLIndex != nil {
                    return (text, .preserved(reason: "ambiguous_multiple_base_urls"))
                }
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    targetURLIndex = idx
                    targetURLValue = String(val.dropFirst().dropLast())
                } else {
                    return (text, .preserved(reason: "malformed_base_url"))
                }
            } else if key == "model_provider" {
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    let provider = String(val.dropFirst().dropLast())
                    if exactLegacyProviders.contains(provider) {
                        targetModelProviderIndex = idx
                        hasExactLegacyProviderInRoot = true
                    }
                }
            }
        }

        guard let urlIndex = targetURLIndex, let baseURL = targetURLValue else {
            return (text, .clean)
        }

        let normalizedURL = baseURL.lowercased()
        guard knownGatewayURLs.contains(normalizedURL) else {
            return (text, .preserved(reason: "unrelated_custom_url"))
        }

        // Attribution: require exact legacy table header or exact legacy root provider
        guard hasExactLegacyTable || hasExactLegacyProviderInRoot else {
            return (text, .preserved(reason: "missing_codexbar_attribution"))
        }

        guard let probeURL = URL(string: baseURL) else {
            return (text, .preserved(reason: "invalid_url"))
        }

        let status: CodexStaleGatewayProbeStatus
        if let probe {
            status = await probe(probeURL)
        } else {
            status = await self.probeEndpoint(url: probeURL)
        }

        switch status {
        case .alive:
            return (text, .activeGatewayPreserved(url: baseURL))
        case .unknown:
            return (text, .preserved(reason: "probe_indeterminate"))
        case .dead:
            break
        }

        // Apply changes strictly at verified target line indices
        var newLines = lines
        if let mpIdx = targetModelProviderIndex {
            newLines[mpIdx] = "model_provider = \"openai\""
        }
        newLines.remove(at: urlIndex)

        let sanitizedText = newLines.joined(separator: "\n")
        return (sanitizedText, .staleGatewayCleaned(previousURL: baseURL))
    }

    /// Migrates the config file safely on disk.
    @discardableResult
    public static func migrate(
        configURL: URL = CodexStaleGatewayMigration.defaultConfigFileURL(),
        probe: ((URL) async -> CodexStaleGatewayProbeStatus)? = nil
    ) async -> CodexStaleGatewayMigrationResult {
        let realURL = configURL.resolvingSymlinksInPath()
        let path = realURL.path

        guard FileManager.default.fileExists(atPath: path) else {
            return CodexStaleGatewayMigrationResult(outcome: .clean, configPath: path)
        }

        guard let originalData = try? Data(contentsOf: realURL),
              let originalText = String(data: originalData, encoding: .utf8) else {
            return CodexStaleGatewayMigrationResult(outcome: .error("Cannot read config file"), configPath: path)
        }

        let (sanitizedText, outcome) = await self.sanitizeConfigText(originalText, probe: probe)

        guard case .staleGatewayCleaned = outcome else {
            return CodexStaleGatewayMigrationResult(outcome: outcome, configPath: path)
        }

        // Re-read disk bytes immediately prior to write to ensure no concurrent modification occurred
        guard let currentData = try? Data(contentsOf: realURL),
              currentData == originalData else {
            return CodexStaleGatewayMigrationResult(outcome: .concurrentModificationDetected, configPath: path)
        }

        guard let sanitizedData = sanitizedText.data(using: .utf8) else {
            return CodexStaleGatewayMigrationResult(outcome: .error("Failed to encode sanitized text"), configPath: path)
        }

        let dir = realURL.deletingLastPathComponent()
        var backupURL = dir.appendingPathComponent("." + realURL.lastPathComponent + ".codexbar-migration-bak")

        // Safely preserve any existing rollback backup sentinel without overwriting it
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let uniqueSuffix = UUID().uuidString.prefix(8)
            backupURL = dir.appendingPathComponent("." + realURL.lastPathComponent + ".codexbar-migration-\(uniqueSuffix).bak")
        }

        let tempURL = dir.appendingPathComponent("." + realURL.lastPathComponent + ".tmp-\(UUID().uuidString)")

        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let perms = attrs[.posixPermissions] as? NSNumber ?? 0o600

        // Create backup atomically with 0o600 permissions at creation time; retained as rollback copy
        let backupCreated = FileManager.default.createFile(
            atPath: backupURL.path,
            contents: originalData,
            attributes: [.posixPermissions: 0o600]
        )
        guard backupCreated else {
            return CodexStaleGatewayMigrationResult(
                outcome: .error("Failed to securely create backup file with 0600 permissions at \(backupURL.path)"),
                configPath: path
            )
        }

        // Create temp file atomically with target permissions at creation time
        let tempCreated = FileManager.default.createFile(
            atPath: tempURL.path,
            contents: sanitizedData,
            attributes: [.posixPermissions: perms]
        )
        guard tempCreated else {
            return CodexStaleGatewayMigrationResult(
                outcome: .error("Failed to securely create temporary file at \(tempURL.path)"),
                configPath: path
            )
        }

        do {
            _ = try FileManager.default.replaceItemAt(realURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return CodexStaleGatewayMigrationResult(
                outcome: .error("Failed to replace config: \(error.localizedDescription)"),
                configPath: path
            )
        }

        return CodexStaleGatewayMigrationResult(outcome: outcome, configPath: path)
    }
}
