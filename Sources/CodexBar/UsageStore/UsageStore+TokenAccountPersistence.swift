import CodexBarCore
import Foundation

extension UsageStore {
    private struct PersistedTokenAccountRecord: Codable {
        let providerID: String
        let accountID: UUID
        let account: ProviderTokenAccount
        let snapshot: UsageSnapshot?
        let error: String?
        let sourceLabel: String?
        let cacheKey: String
    }

    private static func tokenAccountSnapshotsFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("token-account-snapshots.json", isDirectory: false)
    }

    static func loadTokenAccountSnapshotsFromDisk() -> [ProviderInstanceID: [TokenAccountUsageSnapshot]] {
        let url = self.tokenAccountSnapshotsFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PersistedTokenAccountRecord].self, from: data)
        else {
            return [:]
        }
        var result: [ProviderInstanceID: [TokenAccountUsageSnapshot]] = [:]
        for record in records {
            guard let instanceID = ProviderInstanceID(rawValue: record.providerID) else { continue }
            let snapshot = TokenAccountUsageSnapshot(
                account: record.account,
                snapshot: record.snapshot,
                error: record.error,
                sourceLabel: record.sourceLabel,
                cacheKey: record.cacheKey)
            result[instanceID, default: []].append(snapshot)
        }
        return result
    }

    func saveTokenAccountSnapshotsToDisk() {
        let url = Self.tokenAccountSnapshotsFileURL()
        let directory = url.deletingLastPathComponent()
        var records: [PersistedTokenAccountRecord] = []
        for (providerID, snapshots) in self.accountSnapshots {
            for snapshot in snapshots {
                records.append(PersistedTokenAccountRecord(
                    providerID: providerID.rawValue,
                    accountID: snapshot.account.id,
                    account: snapshot.account,
                    snapshot: snapshot.snapshot,
                    error: snapshot.error,
                    sourceLabel: snapshot.sourceLabel,
                    cacheKey: snapshot.cacheKey))
            }
        }
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: [.atomic])
            #if os(macOS)
            try FileManager.default.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: url.path)
            #endif
        } catch {
            // Snapshot persistence is best-effort
        }
    }
}
