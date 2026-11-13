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

    private static func installRelease(_ release: ReleaseInfo) async throws -> String {
        if let appBundle = self.containingAppBundle(self.runningExecutablePath(bundle: .main)) {
            #if os(macOS)
            try await ReleaseAppInstaller.install(release: release, appBundleURL: appBundle)
            return appBundle.path
            #else
            throw ReleaseUpdateError.installFailed("The GUI app can only be updated on macOS.")
            #endif
        }

        guard let executablePath = Self.runningExecutablePath(bundle: .main) else {
            throw ReleaseUpdateError.installFailed("Could not locate the running codexbar binary.")
        }
        let target = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        guard let assetName = Self.cliArchiveName() else {
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
        _ = try await SubprocessRunner.runToCompletion(
            binary: "/usr/bin/tar",
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
