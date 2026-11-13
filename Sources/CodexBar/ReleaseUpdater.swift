import AppKit
import CodexBarCore
import Foundation
import Sparkle

/// Updates manual GitHub-release installs from the fork's releases, without Sparkle.
@MainActor
@Observable
final class GitHubReleaseUpdaterController: UpdaterProviding {
    enum CheckSource {
        case manual
        case automatic
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing
        case failed(String)
    }

    struct Dependencies {
        var installedVersion: () -> String
        var fetchLatestRelease: @Sendable () async throws -> ReleaseInfo
        var installRelease: @Sendable (ReleaseInfo) async throws -> Void
        var relaunch: @MainActor () -> Void
    }

    private static let checkInterval: Duration = .seconds(24 * 60 * 60)
    private static let log = CodexBarLog.logger(LogCategories.app)

    let isAvailable = false
    let updateStatus = UpdateStatus()
    var automaticallyDownloadsUpdates = false
    private(set) var phase: Phase = .idle
    private(set) var pendingRelease: ReleaseInfo?

    var manualUpdateCommand: String? {
        "open https://github.com/m1mc/CodexBar/releases/latest"
    }

    var unavailableReason: String? {
        nil
    }

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard oldValue != self.automaticallyChecksForUpdates else { return }
            if !self.automaticallyChecksForUpdates {
                self.notifier?.update(availableVersion: nil, notify: false)
            }
            self.rescheduleChecks()
        }
    }

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let notifier: HomebrewUpdateNotifier?
    @ObservationIgnored private var scheduledChecks: Task<Void, Never>?
    @ObservationIgnored private var activeCheck: Task<Void, Never>?

    init(
        savedAutoCheck: Bool,
        dependencies: Dependencies = .live,
        notifier: HomebrewUpdateNotifier? = nil,
        startScheduledChecks: Bool = true)
    {
        self.automaticallyChecksForUpdates = savedAutoCheck
        self.dependencies = dependencies
        self.notifier = notifier
        if !savedAutoCheck {
            self.notifier?.update(availableVersion: nil, notify: false)
        }
        if startScheduledChecks {
            self.rescheduleChecks()
        }
    }

    deinit {
        self.scheduledChecks?.cancel()
        self.activeCheck?.cancel()
    }

    func checkForUpdates(_ sender: Any?) {
        self.startCheck(source: .manual)
    }

    private func startCheck(source: CheckSource) {
        guard self.activeCheck == nil, self.phase != .installing else { return }
        self.activeCheck = Task { [weak self] in
            await self?.performCheck(source: source)
            self?.activeCheck = nil
        }
    }

    func installUpdate() {
        guard self.phase != .installing else { return }
        Task { [weak self] in
            await self?.performInstall()
        }
    }

    func performCheck(source: CheckSource = .manual) async {
        guard source == .manual || self.automaticallyChecksForUpdates,
              self.phase != .installing, self.phase != .checking else { return }
        self.phase = .checking
        do {
            let release = try await self.dependencies.fetchLatestRelease()
            if ReleaseVersion.isNewer(release.version, than: self.dependencies.installedVersion()) {
                self.pendingRelease = release
                self.updateStatus.availableVersion = release.version
                self.phase = .available(release.version)
            } else {
                self.pendingRelease = nil
                self.updateStatus.availableVersion = nil
                self.phase = .upToDate
            }
            self.notifier?.update(
                availableVersion: self.updateStatus.availableVersion,
                notify: source == .automatic && self.automaticallyChecksForUpdates)
        } catch {
            Self.log.warning("GitHub release update check failed", metadata: ["error": error.localizedDescription])
            self.phase = .failed(error.localizedDescription)
        }
    }

    func performInstall() async {
        guard self.phase != .installing, self.phase != .checking,
              let release = self.pendingRelease else { return }
        self.phase = .installing
        self.updateStatus.isInstalling = true
        self.notifier?.update(availableVersion: nil, notify: false)
        defer { self.updateStatus.isInstalling = false }
        do {
            try await self.dependencies.installRelease(release)
            self.updateStatus.availableVersion = nil
            self.pendingRelease = nil
            self.phase = .upToDate
            self.dependencies.relaunch()
        } catch {
            Self.log.error("GitHub release install failed", metadata: ["error": error.localizedDescription])
            self.phase = .failed(error.localizedDescription)
        }
    }

    private func rescheduleChecks() {
        self.scheduledChecks?.cancel()
        self.scheduledChecks = nil
        guard self.automaticallyChecksForUpdates else { return }
        self.scheduledChecks = Task { [weak self] in
            while !Task.isCancelled {
                self?.startCheck(source: .automatic)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }
}

extension GitHubReleaseUpdaterController.Dependencies {
    static var live: Self {
        let bundleURL = Bundle.main.bundleURL
        return Self(
            installedVersion: { ReleaseAppInstaller.bundleVersion(at: bundleURL) ?? AppVersion.shortVersion },
            fetchLatestRelease: { try await ReleaseUpdateClient.latestRelease() },
            installRelease: { release in
                try await ReleaseAppInstaller.install(release: release, appBundleURL: bundleURL)
            },
            relaunch: { NSApp.terminate(nil) })
    }
}
