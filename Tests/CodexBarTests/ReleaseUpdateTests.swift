import CodexBarCore
import Foundation
import Testing

struct ReleaseUpdateTests {
    @Test
    func `release tags compare numerically without the v prefix`() {
        #expect(ReleaseVersion.isNewer("v2.2.2", than: "2.2.1"))
        #expect(ReleaseVersion.isNewer("2.2.10", than: "2.2.9"))
        #expect(!ReleaseVersion.isNewer("2.2.1", than: "2.2.2"))
        #expect(!ReleaseVersion.isNewer("0.84.1", than: "2.2.1"))
        #expect(ReleaseVersion.normalized("v2.2.2") == "2.2.2")
        #expect(ReleaseVersion.compare("2.2.2-beta.1", "2.2.2") == 0)
    }

    @Test
    func `release payload maps assets and checksum entries`() throws {
        let payload = """
        {
          "tag_name": "v2.2.2",
          "html_url": "https://github.com/m1mc/CodexBar/releases/tag/v2.2.2",
          "assets": [
            {"name": "CodexBar-macOS.dmg", "browser_download_url": "https://example.invalid/dmg"},
            {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.invalid/sums"}
          ]
        }
        """
        let release = try ReleaseUpdateClient.decodeRelease(Data(payload.utf8))
        #expect(release.tag == "v2.2.2")
        #expect(release.version == "2.2.2")
        #expect(release.asset(named: "CodexBar-macOS.dmg")?.downloadURL.absoluteString
            == "https://example.invalid/dmg")

        let checksums = """
        \(String(repeating: "a", count: 64))  CodexBar-macOS.dmg
        \(String(repeating: "b", count: 64))  SHA256SUMS.txt
        """
        #expect(try ReleaseUpdateClient.checksum(named: "CodexBar-macOS.dmg", in: checksums)
            == String(repeating: "a", count: 64))
        #expect(throws: ReleaseUpdateError.checksumMissing("missing.dmg")) {
            try ReleaseUpdateClient.checksum(named: "missing.dmg", in: checksums)
        }
    }

    @Test
    func `sha256 verification accepts matching bytes and rejects a mismatch`() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-release-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let digest = try ReleaseUpdateClient.sha256(file)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(throws: Never.self) {
            try ReleaseUpdateClient.verifySHA256(file, expected: digest)
        }
        #expect(throws: ReleaseUpdateError.checksumMismatch(file.lastPathComponent)) {
            try ReleaseUpdateClient.verifySHA256(file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test
    func `state throttles checks for 24 hours`() {
        let now = Date()
        let due = ReleaseUpdateState(lastCheckAt: now.addingTimeInterval(-25 * 60 * 60))
        let fresh = ReleaseUpdateState(lastCheckAt: now.addingTimeInterval(-60))
        #expect(ReleaseUpdateStateStore.isDue(due, now: now))
        #expect(!ReleaseUpdateStateStore.isDue(fresh, now: now))
        #expect(ReleaseUpdateStateStore.isDue(ReleaseUpdateState(), now: now))
    }

    @Test
    func `state round-trips through the override file`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-update-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = ReleaseUpdateState(
            lastCheckAt: Date(timeIntervalSince1970: 1_700_000_000),
            availableVersion: "2.2.2",
            checkedTag: "v2.2.2")
        try ReleaseUpdateStateStore.save(state, to: url)
        let loaded = ReleaseUpdateStateStore.load(from: url)
        #expect(loaded.availableVersion == "2.2.2")
        #expect(loaded.checkedTag == "v2.2.2")
        #expect(loaded.lastCheckAt?.timeIntervalSince1970 == 1_700_000_000)
    }
}
