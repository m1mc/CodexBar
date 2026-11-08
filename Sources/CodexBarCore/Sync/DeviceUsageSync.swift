import Foundation

/// Aggregate daily usage counters for multi-device synchronization via iCloud Drive / shared directories.
public struct DeviceUsageDailyStat: Codable, Equatable, Sendable {
    public let date: Date
    public let toolID: String
    public let totalTokens: Int
    public let knownCostUSD: Double
    public let costIsComplete: Bool

    public init(date: Date, toolID: String, totalTokens: Int, knownCostUSD: Double = 0, costIsComplete: Bool = false) {
        self.date = date
        self.toolID = toolID
        self.totalTokens = totalTokens
        self.knownCostUSD = knownCostUSD
        self.costIsComplete = costIsComplete
    }
}

/// A snapshot of a device's local daily usage statistics.
public struct DeviceUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let deviceID: String
    public let deviceName: String
    public let generatedAt: Date
    public let timeZoneIdentifier: String
    public let dailyEntries: [DeviceUsageDailyStat]

    public var id: String { self.deviceID }

    public var totalTokens: Int {
        self.dailyEntries.reduce(0) { value, entry in
            let result = value.addingReportingOverflow(entry.totalTokens)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(self.generatedAt) > 24 * 60 * 60
    }

    public init(
        deviceID: String,
        deviceName: String,
        generatedAt: Date = Date(),
        timeZoneIdentifier: String = TimeZone.current.identifier,
        dailyEntries: [DeviceUsageDailyStat]
    ) {
        self.schemaVersion = 1
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.generatedAt = generatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dailyEntries = dailyEntries
    }

    public func validate(now: Date = Date()) throws {
        guard self.schemaVersion == 1,
              UUID(uuidString: self.deviceID) != nil,
              self.deviceName.count <= 80,
              !self.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.generatedAt.timeIntervalSince1970.isFinite,
              self.generatedAt <= now.addingTimeInterval(300),
              TimeZone(identifier: self.timeZoneIdentifier) != nil,
              self.dailyEntries.count <= 20_000
        else {
            throw DeviceUsageSyncError.invalidSnapshot
        }
        var keys = Set<String>()
        for entry in self.dailyEntries {
            guard entry.date.timeIntervalSince1970.isFinite,
                  entry.date <= now.addingTimeInterval(24 * 60 * 60),
                  entry.date.timeIntervalSince1970 >= 0,
                  !entry.toolID.isEmpty,
                  entry.totalTokens >= 0,
                  entry.knownCostUSD.isFinite,
                  entry.knownCostUSD >= 0,
                  keys.insert("\(entry.toolID):\(entry.date.timeIntervalSince1970)").inserted
            else {
                throw DeviceUsageSyncError.invalidSnapshot
            }
        }
    }

    public static func latestDevices(_ snapshots: [Self], excluding deviceID: String? = nil) -> [Self] {
        var devices: [String: Self] = [:]
        for snapshot in snapshots where snapshot.deviceID.caseInsensitiveCompare(deviceID ?? "") != .orderedSame {
            let key = snapshot.deviceID.lowercased()
            if devices[key].map({ $0.generatedAt >= snapshot.generatedAt }) == true { continue }
            devices[key] = snapshot
        }
        return devices.values.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }
}

public enum DeviceUsageSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case sharedFolder
    case iCloudDrive
    case client
    case host

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .local: "仅本机"
        case .sharedFolder: "共享文件夹"
        case .iCloudDrive: "iCloud Drive"
        case .client: "连接 Hub"
        case .host: "本机作为 Hub"
        }
    }
}

public struct DeviceUsageSyncConfiguration: Codable, Equatable, Sendable {
    public var mode: DeviceUsageSyncMode = .local
    public var deviceName: String = Host.current().localizedName ?? "Mac"
    public var folderPath: String = ""
    public var hubURL: String = ""
    public var listenPort: UInt16 = 23948
    public var allowLANConnections = false
    public var syncIntervalSeconds: Int = 60

    public init() {}
}

public enum DeviceUsageSyncError: Error, LocalizedError, Sendable {
    case invalidSnapshot
    case oversized
    case unsafePath
    case invalidConfiguration
    case unauthorized
    case connectionFailed
    case tooManyDevices

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "同步数据格式无效。"
        case .oversized: "同步数据超过大小限制。"
        case .unsafePath: "同步目录或文件无效，请重新选择普通文件夹。"
        case .invalidConfiguration: "请检查设备名、同步目录、Hub 地址和配对密钥。"
        case .unauthorized: "Hub 配对密钥不匹配。"
        case .connectionFailed: "无法连接 Hub，请检查地址、端口及网络。"
        case .tooManyDevices: "同步设备超过 32 台上限。"
        }
    }
}

/// Directory-based snapshot transport supporting iCloud Drive folders.
public struct DeviceUsageSnapshotDirectory: Sendable {
    public static let maximumSnapshotBytes = 2 * 1024 * 1024
    public static let maximumDevices = 32
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public func write(_ snapshot: DeviceUsageSnapshot) throws {
        try snapshot.validate()
        try self.prepare()
        let existing = try self.read()
        guard existing.contains(where: { $0.deviceID.lowercased() == snapshot.deviceID.lowercased() })
            || existing.count < Self.maximumDevices
        else {
            throw DeviceUsageSyncError.tooManyDevices
        }
        if let previous = existing.first(where: { $0.deviceID.lowercased() == snapshot.deviceID.lowercased() }),
           previous.generatedAt > snapshot.generatedAt
        {
            return
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else { throw DeviceUsageSyncError.oversized }
        let destination = self.url.appendingPathComponent(snapshot.deviceID.lowercased() + ".json")
        try data.write(to: destination, options: .atomic)
        #if os(macOS) || os(Linux)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #endif
    }

    public func read() throws -> [DeviceUsageSnapshot] {
        try self.prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: self.url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= Self.maximumDevices else { throw DeviceUsageSyncError.tooManyDevices }
        var records: [DeviceUsageSnapshot] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  data.count <= Self.maximumSnapshotBytes,
                  let record = try? JSONDecoder().decode(DeviceUsageSnapshot.self, from: data),
                  (try? record.validate()) != nil,
                  record.deviceID.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased()
            else {
                continue
            }
            records.append(record)
        }
        return DeviceUsageSnapshot.latestDevices(records)
    }

    private func prepare() throws {
        guard self.url.isFileURL, self.url.path != "/" else { throw DeviceUsageSyncError.unsafePath }
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
    }
}
