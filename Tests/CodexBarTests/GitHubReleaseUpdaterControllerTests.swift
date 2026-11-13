import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GitHubReleaseUpdaterControllerTests {
    private static let release = ReleaseInfo(
        tag: "v2.2.2",
        version: "2.2.2",
        htmlURL: URL(string: "https://github.com/m1mc/CodexBar/releases/tag/v2.2.2")!,
        assets: [
            ReleaseAsset(
                name: "CodexBar-macOS.dmg",
                downloadURL: URL(string: "https://example.invalid/CodexBar-macOS.dmg")!),
        ])

    @Test
    func `check offers a release newer than the bundle`() async {
        let updater = self.makeUpdater(installed: "0.84.1")
        await updater.performCheck()
        #expect(updater.phase == .available("2.2.2"))
        #expect(updater.updateStatus.availableVersion == "2.2.2")
    }

    @Test
    func `check reports up to date for an equal or newer bundle`() async {
        let updater = self.makeUpdater(installed: "2.2.2")
        await updater.performCheck()
        #expect(updater.phase == .upToDate)
        #expect(updater.updateStatus.availableVersion == nil)
    }

    @Test
    func `install verifies the staged release and terminates the app`() async {
        let installed = FlagBox()
        let relaunched = FlagBox()
        let updater = self.makeUpdater(
            installed: "0.84.1",
            install: { _ in installed.set() },
            relaunch: { relaunched.set() })
        await updater.performCheck()
        await updater.performInstall()
        #expect(installed.value)
        #expect(relaunched.value)
        #expect(updater.phase == .upToDate)
        #expect(updater.updateStatus.availableVersion == nil)
    }

    @Test
    func `install failure keeps the update available for retry`() async {
        let updater = self.makeUpdater(
            installed: "0.84.1",
            install: { _ in throw ReleaseUpdateError.installFailed("disk full") })
        await updater.performCheck()
        await updater.performInstall()
        guard case let .failed(message) = updater.phase else {
            Issue.record("expected failed phase")
            return
        }
        #expect(message.contains("disk full"))
        #expect(updater.updateStatus.availableVersion == "2.2.2")
    }

    @Test
    func `fetch failure is reported without claiming an update`() async {
        let updater = self.makeUpdater(
            installed: "0.84.1",
            fetch: { throw ReleaseUpdateError.requestFailed("offline") })
        await updater.performCheck()
        guard case let .failed(message) = updater.phase else {
            Issue.record("expected failed phase")
            return
        }
        #expect(message.contains("offline"))
        #expect(updater.updateStatus.availableVersion == nil)
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        var value: Bool {
            self.lock.withLock { self.stored }
        }

        func set() {
            self.lock.withLock { self.stored = true }
        }
    }

    private func makeUpdater(
        installed: String,
        fetch: @escaping @Sendable () async throws -> ReleaseInfo = { GitHubReleaseUpdaterControllerTests.release },
        install: @escaping @Sendable (ReleaseInfo) async throws -> Void = { _ in },
        relaunch: @escaping @MainActor () -> Void = {}) -> GitHubReleaseUpdaterController
    {
        GitHubReleaseUpdaterController(
            savedAutoCheck: false,
            dependencies: GitHubReleaseUpdaterController.Dependencies(
                installedVersion: { installed },
                fetchLatestRelease: fetch,
                installRelease: install,
                relaunch: relaunch),
            notifier: nil,
            startScheduledChecks: false)
    }
}
