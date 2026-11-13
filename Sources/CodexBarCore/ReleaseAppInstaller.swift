#if os(macOS)
import Foundation

/// Downloads a verified release DMG, stages the app, and schedules replacement after CodexBar exits.
public enum ReleaseAppInstaller {
    public static func install(
        release: ReleaseInfo,
        appBundleURL: URL,
        expectedBundleID: String = "com.steipete.codexbar") async throws
    {
        let target = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard target.pathExtension == "app" else {
            throw ReleaseUpdateError.installFailed("CodexBar is not running from an app bundle")
        }

        guard let dmgAsset = release.asset(named: "CodexBar-macOS.dmg") else {
            throw ReleaseUpdateError.missingAsset("CodexBar-macOS.dmg")
        }
        guard let checksumsAsset = release.asset(named: "SHA256SUMS.txt") else {
            throw ReleaseUpdateError.missingAsset("SHA256SUMS.txt")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let dmgURL = try await ReleaseUpdateClient.download(dmgAsset, to: work)
        let checksums = try await ReleaseUpdateClient.downloadText(checksumsAsset)
        let expected = try ReleaseUpdateClient.checksum(named: dmgAsset.name, in: checksums)
        try ReleaseUpdateClient.verifySHA256(dmgURL, expected: expected)

        let mountPoint = work.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try await SubprocessRunner.runToCompletion(
            binary: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmgURL.path],
            environment: [:],
            label: "codexbar-release-mount")

        do {
            let candidate = mountPoint.appendingPathComponent("CodexBar.app")
            try self.verifyBundle(candidate, expectedBundleID: expectedBundleID, expectedVersion: release.version)

            let staged = work.appendingPathComponent("CodexBar.app")
            _ = try await SubprocessRunner.runToCompletion(
                binary: "/usr/bin/ditto",
                arguments: [candidate.path, staged.path],
                environment: [:],
                label: "codexbar-release-stage")

            try self.verifyBundle(staged, expectedBundleID: expectedBundleID, expectedVersion: release.version)
            try await self.scheduleReplacement(target: target, staged: staged, work: work)
        } catch {
            try? await SubprocessRunner.runToCompletion(
                binary: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-quiet"],
                environment: [:],
                acceptsNonZeroExit: true,
                label: "codexbar-release-unmount")
            try? FileManager.default.removeItem(at: work)
            throw error
        }

        _ = try? await SubprocessRunner.runToCompletion(
            binary: "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path, "-quiet"],
            environment: [:],
            acceptsNonZeroExit: true,
            label: "codexbar-release-unmount")
    }

    public static func bundleVersion(at appBundleURL: URL) -> String? {
        let plistURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    private static func verifyBundle(
        _ bundleURL: URL,
        expectedBundleID: String,
        expectedVersion: String) throws
    {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ReleaseUpdateError.installFailed("the release does not contain CodexBar.app")
        }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) else {
            throw ReleaseUpdateError.installFailed("CodexBar.app has an unreadable Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == expectedBundleID else {
            throw ReleaseUpdateError.installFailed("CodexBar.app has an unexpected bundle identifier")
        }
        guard let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion.normalized(version) == ReleaseVersion.normalized(expectedVersion)
        else {
            throw ReleaseUpdateError.installFailed("CodexBar.app version does not match the release tag")
        }
    }

    private static func scheduleReplacement(target: URL, staged: URL, work: URL) async throws {
        let scriptURL = work.appendingPathComponent("install.sh")
        let script = """
        #!/bin/sh
        set -eu
        TARGET=\(self.shellQuote(target.path))
        STAGED=\(self.shellQuote(staged.path))
        WORK=\(self.shellQuote(work.path))
        index=0
        while [ "$index" -lt 120 ]; do
          if ! pgrep -f "$TARGET/Contents/MacOS/CodexBar" >/dev/null 2>&1; then
            break
          fi
          sleep 0.5
          index=$((index + 1))
        done
        rm -rf "$TARGET"
        /usr/bin/ditto "$STAGED" "$TARGET"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        /usr/bin/open -a "$TARGET"
        rm -rf "$WORK"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw ReleaseUpdateError.installFailed(error.localizedDescription)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
