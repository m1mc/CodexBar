import CodexBarCore
import Commander
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CodexBarCLI {
    private struct UpdatePayload: Encodable {
        let currentVersion: String?
        let availableVersion: String
        let tag: String
        let status: String
        let installedPath: String?
        let releaseURL: String
    }

    static func runUpdate(_ values: ParsedValues) async {
        let install = values.flags.contains("install")
        let json = values.flags.contains("json")
        let pretty = values.flags.contains("pretty")
        let output = CLIOutputPreferences(
            format: json ? .json : .text,
            jsonOnly: false,
            pretty: pretty)
        let current = Self.currentVersion()

        do {
            let release = try await ReleaseUpdateClient.latestRelease()
            let isNewer = current.map { ReleaseVersion.isNewer(release.version, than: $0) } ?? true
            if !isNewer {
                self.printUpdatePayload(
                    UpdatePayload(
                        currentVersion: current,
                        availableVersion: release.version,
                        tag: release.tag,
                        status: "up-to-date",
                        installedPath: nil,
                        releaseURL: release.htmlURL.absoluteString),
                    output: output)
                return
            }

            if !install {
                self.printUpdatePayload(
                    UpdatePayload(
                        currentVersion: current,
                        availableVersion: release.version,
                        tag: release.tag,
                        status: "available",
                        installedPath: nil,
                        releaseURL: release.htmlURL.absoluteString),
                    output: output)
                return
            }

            let installedPath = try await self.installRelease(release)
            self.printUpdatePayload(
                UpdatePayload(
                    currentVersion: current,
                    availableVersion: release.version,
                    tag: release.tag,
                    status: "installed",
                    installedPath: installedPath,
                    releaseURL: release.htmlURL.absoluteString),
                output: output)
        } catch {
            Self.exit(
                code: .failure,
                message: error.localizedDescription,
                output: output,
                kind: .runtime)
        }
    }

    static func maybeNotifyUpdate(_ output: CLIOutputPreferences) async {
        guard !output.usesJSONOutput, !output.toonRequested, self.stdoutIsTTY() else { return }
        guard ProcessInfo.processInfo.environment["CODEXBAR_UPDATE_CHECK"] != "0" else { return }
        guard let current = self.currentVersion(), !current.isEmpty else { return }

        let stateURL = ReleaseUpdateStateStore.defaultURL()
        var state = ReleaseUpdateStateStore.load(from: stateURL)
        let now = Date()
        guard ReleaseUpdateStateStore.isDue(state, now: now) else { return }

        do {
            let release = try await ReleaseUpdateClient.latestRelease(timeout: 8)
            state.lastCheckAt = now
            state.checkedTag = release.tag
            if ReleaseVersion.isNewer(release.version, than: current) {
                state.availableVersion = release.version
                let noticeIsDue = state.lastNotifiedVersion != release.version
                    || state.lastNoticeAt == nil
                    || now.timeIntervalSince(state.lastNoticeAt!) >= ReleaseUpdateStateStore.checkInterval
                try? ReleaseUpdateStateStore.save(state, to: stateURL)
                if noticeIsDue {
                    Self.writeStderr(
                        "Update available: v\(release.version) (current \(current)). " +
                            "Run \"codexbar update --install\" or visit \(release.htmlURL.absoluteString)\n")
                    state.lastNoticeAt = now
                    state.lastNotifiedVersion = release.version
                    try? ReleaseUpdateStateStore.save(state, to: stateURL)
                }
            } else {
                state.availableVersion = nil
                state.lastNotifiedVersion = nil
                try? ReleaseUpdateStateStore.save(state, to: stateURL)
            }
        } catch {
            state.lastCheckAt = now
            try? ReleaseUpdateStateStore.save(state, to: stateURL)
        }
    }

    private static func printUpdatePayload(_ payload: UpdatePayload, output: CLIOutputPreferences) {
        if output.usesJSONOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = output.pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            if let data = try? encoder.encode(payload),
               let text = String(data: data, encoding: .utf8)
            {
                print(text)
            }
            return
        }

        switch payload.status {
        case "up-to-date":
            if let current = payload.currentVersion {
                print("CodexBar \(current) is up to date (latest release: v\(payload.availableVersion)).")
            } else {
                print("Latest CodexBar release: v\(payload.availableVersion).")
            }
        case "available":
            let currentText = payload.currentVersion.map { " (current \($0))" } ?? ""
            print("Update available: v\(payload.availableVersion)\(currentText).")
            print("Run \"codexbar update --install\" or visit \(payload.releaseURL)")
        case "installed":
            print("Installed CodexBar \(payload.availableVersion) at \(payload.installedPath ?? "the current path").")
            print("The GUI app relaunches after the update; a standalone CLI keeps its current process.")
        default:
            break
        }
    }

    private enum UpdateInstallOrigin {
        case brewCask(prefix: String)
        case brewFormula(prefix: String)
        case mise(tool: String)
        case appBundle(URL)
        case standalone(URL)
    }

    private static func installRelease(_ release: ReleaseInfo) async throws -> String {
        let executablePath = self.runningExecutablePath(bundle: .main)
        let origin = self.updateInstallOrigin(executablePath: executablePath)

        switch origin {
        case let .brewCask(prefix):
            try await self.runBrewUpgrade(prefix: prefix, cask: true)
            return self.containingAppBundle(executablePath)?.path ?? executablePath ?? "brew"
        case let .brewFormula(prefix):
            try await self.runBrewUpgrade(prefix: prefix, cask: false)
            return executablePath ?? "brew"
        case let .mise(tool):
            try await self.runMiseUpgrade(tool: tool)
            return executablePath ?? "mise"
        case let .appBundle(appBundle):
            #if os(macOS)
            try await ReleaseAppInstaller.install(release: release, appBundleURL: appBundle)
            return appBundle.path
            #else
            throw ReleaseUpdateError.installFailed("The GUI app can only be updated on macOS.")
            #endif
        case let .standalone(target):
            return try await self.installStandaloneCLI(release: release, target: target)
        }
    }

    private static func updateInstallOrigin(executablePath: String?) -> UpdateInstallOrigin {
        let appBundle = self.containingAppBundle(executablePath)
        if let appBundle {
            if let prefix = self.homebrewPrefix(),
               self.homebrewReceiptTap(prefix: prefix) == "m1mc/codexbar"
            {
                return .brewCask(prefix: prefix)
            }
            return .appBundle(appBundle)
        }

        guard let executablePath else {
            return .standalone(URL(fileURLWithPath: "/usr/bin/codexbar"))
        }
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        if resolvedPath.contains("/Cellar/codexbar/"),
           let prefix = self.homebrewPrefix()
        {
            return .brewFormula(prefix: prefix)
        }
        if resolvedPath.contains("/mise/installs/") {
            let components = resolved.pathComponents
            let tool = components.firstIndex(of: "installs").flatMap { index in
                index + 1 < components.count ? components[index + 1] : nil
            }
            let spec = if let tool, tool.hasPrefix("github-") {
                "github:m1mc/CodexBar"
            } else {
                "ubi:m1mc/CodexBar"
            }
            return .mise(tool: spec)
        }
        return .standalone(resolved)
    }

    private static func installStandaloneCLI(
        release: ReleaseInfo,
        target: URL) async throws -> String
    {
        guard let assetName = self.cliArchiveName() else {
            throw ReleaseUpdateError.installFailed("No CLI archive is published for this platform.")
        }
        guard let archiveAsset = release.asset(named: assetName) else {
            throw ReleaseUpdateError.missingAsset(assetName)
        }
        guard let checksumsAsset = release.asset(named: "SHA256SUMS.txt") else {
            throw ReleaseUpdateError.missingAsset("SHA256SUMS.txt")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archiveURL = try await ReleaseUpdateClient.download(archiveAsset, to: work)
        let checksums = try await ReleaseUpdateClient.downloadText(checksumsAsset)
        let expected = try ReleaseUpdateClient.checksum(named: archiveAsset.name, in: checksums)
        try ReleaseUpdateClient.verifySHA256(archiveURL, expected: expected)

        let extracted = work.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tarBinary = FileManager.default.isExecutableFile(atPath: "/usr/bin/tar")
            ? "/usr/bin/tar"
            : "/bin/tar"
        _ = try await SubprocessRunner.runToCompletion(
            binary: tarBinary,
            arguments: ["-xzf", archiveURL.path, "-C", extracted.path],
            environment: [:],
            label: "codexbar-cli-extract")

        let binary = extracted.appendingPathComponent("CodexBarCLI")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ReleaseUpdateError.installFailed("The CLI archive does not contain CodexBarCLI.")
        }

        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".codexbar-update-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: binary, to: staged)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: staged.path)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw ReleaseUpdateError.installFailed(error.localizedDescription)
        }

        let versionURL = target.deletingLastPathComponent().appendingPathComponent("VERSION")
        try? release.version.write(to: versionURL, atomically: true, encoding: .utf8)
        return target.path
    }

    private static func homebrewPrefix() -> String? {
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
           FileManager.default.isExecutableFile(atPath: prefix + "/bin/brew")
        {
            return prefix
        }
        for prefix in ["/opt/homebrew", "/usr/local"]
            where FileManager.default.isExecutableFile(atPath: prefix + "/bin/brew")
        {
            return prefix
        }
        return nil
    }

    private static func homebrewReceiptTap(prefix: String) -> String? {
        let receipt = URL(fileURLWithPath: prefix)
            .appendingPathComponent("Caskroom/codexbar/.metadata/INSTALL_RECEIPT.json")
        guard let data = try? Data(contentsOf: receipt),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? [String: Any]
        else { return nil }
        return source["tap"] as? String
    }

    private static func runBrewUpgrade(prefix: String, cask: Bool) async throws {
        let brew = prefix + "/bin/brew"
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] = "1"
        _ = try await SubprocessRunner.runToCompletion(
            binary: brew,
            arguments: ["update"],
            environment: environment,
            acceptsNonZeroExit: true,
            label: "codexbar-brew-update")
        _ = try await SubprocessRunner.runToCompletion(
            binary: brew,
            arguments: ["upgrade", cask ? "--cask" : "--formula", "m1mc/codexbar/codexbar"],
            environment: environment,
            label: "codexbar-brew-upgrade")
    }

    private static func runMiseUpgrade(tool: String) async throws {
        guard let mise = self.executable(named: "mise") else {
            throw ReleaseUpdateError.installFailed("mise is not on PATH; run `mise upgrade \(tool)` manually.")
        }
        _ = try await SubprocessRunner.runToCompletion(
            binary: mise,
            arguments: ["upgrade", tool, "--yes"],
            environment: ProcessInfo.processInfo.environment,
            label: "codexbar-mise-upgrade")
    }

    private static func executable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = path.split(separator: ":").map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func cliArchiveName() -> String? {
        #if os(macOS)
        #if arch(arm64)
        return "CodexBarCLI-macos-arm64.tar.gz"
        #else
        return "CodexBarCLI-macos-x86_64.tar.gz"
        #endif
        #elseif os(Linux)
        #if arch(x86_64)
        return "CodexBarCLI-linux-x86_64.tar.gz"
        #elseif arch(aarch64)
        return "CodexBarCLI-linux-aarch64.tar.gz"
        #else
        return nil
        #endif
        #else
        return nil
        #endif
    }

    private static func containingAppBundle(_ executablePath: String?) -> URL? {
        guard let executablePath else { return nil }
        var url = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private static func stdoutIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDOUT_FILENO) != 0
        #else
        return false
        #endif
    }
}
