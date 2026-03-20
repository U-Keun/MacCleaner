import Foundation

public struct DevCacheEntry: Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let path: String
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let newestModificationDate: Date?
    public let errors: [String]

    public init(
        id: String,
        kind: String,
        path: String,
        sizeInBytes: Int64,
        fileCount: Int,
        newestModificationDate: Date?,
        errors: [String]
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.newestModificationDate = newestModificationDate
        self.errors = errors
    }
}

public struct DevCacheInventory: Sendable {
    public let rootPath: String
    public let exists: Bool
    public let entries: [DevCacheEntry]
    public let errors: [String]

    public init(rootPath: String, exists: Bool, entries: [DevCacheEntry], errors: [String]) {
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

public struct DevCacheCleanupResult: Sendable {
    public let removedItems: Int
    public let errors: [String]

    public init(removedItems: Int, errors: [String]) {
        self.removedItems = removedItems
        self.errors = errors
    }
}

private struct DevCacheMeasurement {
    let sizeInBytes: Int64
    let fileCount: Int
    let newestModificationDate: Date?
    let errors: [String]
}

public final class DevCacheScanner {
    public static let defaultRootPath = "~/Desktop"
    public static let defaultStaleDays = 30

    private let fileManager: FileManager
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
    ]
    private let exactMatchNames: Set<String> = [
        "target",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        ".svelte-kit",
        "DerivedData",
        "coverage",
    ]
    private let outputDirectoryNames: Set<String> = [
        "build",
        "dist",
        "out",
    ]
    private let excludedDirectoryNames: Set<String> = [
        ".git",
        ".build",
        ".venv",
        "venv",
        "site-packages",
        "Pods",
    ]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        rootPath: String = DevCacheScanner.defaultRootPath,
        staleAfterDays: Int = DevCacheScanner.defaultStaleDays
    ) -> DevCacheInventory {
        let expandedRootPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedRootPath).resolvingSymlinksInPath()
        let normalizedRootPath = rootURL.path
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: normalizedRootPath, isDirectory: &isDirectory) else {
            return DevCacheInventory(rootPath: normalizedRootPath, exists: false, entries: [], errors: [])
        }

        guard isDirectory.boolValue else {
            return DevCacheInventory(
                rootPath: normalizedRootPath,
                exists: true,
                entries: [],
                errors: ["\(normalizedRootPath): expected a directory."]
            )
        }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -staleAfterDays, to: Date()) ?? Date()
        var stack = [rootURL]
        var entries: [DevCacheEntry] = []
        var errors: [String] = []

        while let currentURL = stack.popLast() {
            do {
                let children = try fileManager.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                )

                for childURL in children {
                    guard shouldConsiderForTraversal(childURL, rootURL: rootURL) else {
                        continue
                    }

                    if isCandidateDirectory(childURL, rootURL: rootURL) {
                        let measurement = measureDirectory(at: childURL)
                        let newestDate = measurement.newestModificationDate
                            ?? (try? childURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

                        if let newestDate, newestDate <= cutoffDate {
                            entries.append(
                                DevCacheEntry(
                                    id: childURL.resolvingSymlinksInPath().path,
                                    kind: childURL.lastPathComponent,
                                    path: childURL.resolvingSymlinksInPath().path,
                                    sizeInBytes: measurement.sizeInBytes,
                                    fileCount: measurement.fileCount,
                                    newestModificationDate: newestDate,
                                    errors: measurement.errors
                                )
                            )
                        }
                        continue
                    }

                    stack.append(childURL)
                }
            } catch {
                errors.append("\(currentURL.path): \(error.localizedDescription)")
            }
        }

        entries.sort(by: sortEntries(_:_:))
        return DevCacheInventory(rootPath: normalizedRootPath, exists: true, entries: entries, errors: errors)
    }

    private func shouldConsiderForTraversal(_ url: URL, rootURL: URL) -> Bool {
        guard isDirectory(url) else {
            return false
        }

        let name = url.lastPathComponent
        if excludedDirectoryNames.contains(name) {
            return false
        }

        if name == "node_modules" {
            return true
        }

        let relativeParts = relativeParts(of: url, rootURL: rootURL)
        if relativeParts.contains("node_modules") {
            return name == ".cache" && relativeParts.last == ".cache"
        }

        return true
    }

    private func isCandidateDirectory(_ url: URL, rootURL: URL) -> Bool {
        let name = url.lastPathComponent
        if exactMatchNames.contains(name) {
            return true
        }

        if name == ".cache" {
            return true
        }

        guard outputDirectoryNames.contains(name) else {
            return false
        }

        let relativeParts = relativeParts(of: url, rootURL: rootURL)
        return !relativeParts.contains("node_modules")
    }

    private func measureDirectory(at url: URL) -> DevCacheMeasurement {
        var totalSize: Int64 = 0
        var fileCount = 0
        var newestModificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var errors: [String] = []

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { failedURL, error in
                errors.append("\(failedURL.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            return DevCacheMeasurement(sizeInBytes: 0, fileCount: 0, newestModificationDate: newestModificationDate, errors: [])
        }

        for case let childURL as URL in enumerator {
            let values = try? childURL.resourceValues(forKeys: resourceKeys)

            if let modificationDate = values?.contentModificationDate {
                if newestModificationDate == nil || modificationDate > newestModificationDate! {
                    newestModificationDate = modificationDate
                }
            }

            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values?.isRegularFile == true {
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
                totalSize += size
                fileCount += 1
            }
        }

        return DevCacheMeasurement(
            sizeInBytes: totalSize,
            fileCount: fileCount,
            newestModificationDate: newestModificationDate,
            errors: errors
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func relativeParts(of url: URL, rootURL: URL) -> [String] {
        let normalizedURL = url.resolvingSymlinksInPath()
        guard let relativePath = normalizedURL.path.removingPrefix(rootURL.path)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !relativePath.isEmpty else {
            return []
        }

        return relativePath.split(separator: "/").map(String.init)
    }

    private func sortEntries(_ lhs: DevCacheEntry, _ rhs: DevCacheEntry) -> Bool {
        if lhs.sizeInBytes != rhs.sizeInBytes {
            return lhs.sizeInBytes > rhs.sizeInBytes
        }

        switch (lhs.newestModificationDate, rhs.newestModificationDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }
}

public final class DevCacheCleaner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func clean(entries: [DevCacheEntry]) -> DevCacheCleanupResult {
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
                errors.append("\(entry.path): \(error.localizedDescription)")
            }
        }

        return DevCacheCleanupResult(removedItems: removedItems, errors: errors)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }

        return String(dropFirst(prefix.count))
    }
}
