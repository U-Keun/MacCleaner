import Foundation

public struct DeviceBackupEntry: Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let productName: String?
    public let productVersion: String?
    public let lastBackupDate: Date?
    public let path: String
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let errors: [String]

    public init(
        id: String,
        displayName: String,
        productName: String?,
        productVersion: String?,
        lastBackupDate: Date?,
        path: String,
        sizeInBytes: Int64,
        fileCount: Int,
        errors: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.productName = productName
        self.productVersion = productVersion
        self.lastBackupDate = lastBackupDate
        self.path = path
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.errors = errors
    }
}

public struct DeviceBackupInventory: Sendable {
    public let rootPath: String
    public let exists: Bool
    public let entries: [DeviceBackupEntry]
    public let errors: [String]

    public init(rootPath: String, exists: Bool, entries: [DeviceBackupEntry], errors: [String]) {
        self.rootPath = rootPath
        self.exists = exists
        self.entries = entries
        self.errors = errors
    }

    public var totalSizeInBytes: Int64 {
        entries.reduce(into: Int64(0)) { partialResult, entry in
            partialResult += entry.sizeInBytes
        }
    }
}

public struct DeviceBackupCleanupResult: Sendable {
    public let removedItems: Int
    public let errors: [String]

    public init(removedItems: Int, errors: [String]) {
        self.removedItems = removedItems
        self.errors = errors
    }
}

public final class DeviceBackupScanner {
    public static let defaultRootPath = "~/Library/Application Support/MobileSync/Backup"

    private let fileManager: FileManager
    private let fileScanner: FileScanner

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileScanner = FileScanner(fileManager: fileManager)
    }

    public func scan(rootPath: String = DeviceBackupScanner.defaultRootPath) -> DeviceBackupInventory {
        let expandedRootPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedRootPath)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: expandedRootPath, isDirectory: &isDirectory) else {
            return DeviceBackupInventory(rootPath: expandedRootPath, exists: false, entries: [], errors: [])
        }

        guard isDirectory.boolValue else {
            return DeviceBackupInventory(
                rootPath: expandedRootPath,
                exists: true,
                entries: [],
                errors: ["\(expandedRootPath): expected a directory."]
            )
        }

        do {
            let children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            let entries = children
                .filter(isBackupDirectory(_:))
                .map(makeEntry(from:))
                .sorted(by: sortEntries(_:_:))

            return DeviceBackupInventory(rootPath: expandedRootPath, exists: true, entries: entries, errors: [])
        } catch {
            return DeviceBackupInventory(
                rootPath: expandedRootPath,
                exists: true,
                entries: [],
                errors: [error.localizedDescription]
            )
        }
    }

    private func makeEntry(from backupURL: URL) -> DeviceBackupEntry {
        let scan = fileScanner.scan(path: CleanupPath(rawValue: backupURL.path, removeStrategy: .item))
        let infoMetadata = readPropertyList(at: backupURL.appendingPathComponent("Info.plist"))
        let statusMetadata = readPropertyList(at: backupURL.appendingPathComponent("Status.plist"))

        let displayName =
            infoMetadata["Device Name"] as? String ??
            infoMetadata["Display Name"] as? String ??
            backupURL.lastPathComponent

        let lastBackupDate =
            statusMetadata["Date"] as? Date ??
            infoMetadata["Last Backup Date"] as? Date

        return DeviceBackupEntry(
            id: backupURL.lastPathComponent,
            displayName: displayName,
            productName: infoMetadata["Product Name"] as? String,
            productVersion: infoMetadata["Product Version"] as? String,
            lastBackupDate: lastBackupDate,
            path: backupURL.path,
            sizeInBytes: scan.sizeInBytes,
            fileCount: scan.fileCount,
            errors: scan.errors
        )
    }

    private func isBackupDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func readPropertyList(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return [:]
        }

        return dictionary
    }

    private func sortEntries(_ lhs: DeviceBackupEntry, _ rhs: DeviceBackupEntry) -> Bool {
        switch (lhs.lastBackupDate, rhs.lastBackupDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate > rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.sizeInBytes != rhs.sizeInBytes {
                return lhs.sizeInBytes > rhs.sizeInBytes
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

public final class DeviceBackupCleaner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func clean(entries: [DeviceBackupEntry]) -> DeviceBackupCleanupResult {
        var removedItems = 0
        var errors: [String] = []

        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)

            guard fileManager.fileExists(atPath: entry.path) else {
                continue
            }

            do {
                try fileManager.removeItem(at: url)
                removedItems += 1
            } catch {
                errors.append("\(entry.displayName): \(error.localizedDescription)")
            }
        }

        return DeviceBackupCleanupResult(removedItems: removedItems, errors: errors)
    }
}
