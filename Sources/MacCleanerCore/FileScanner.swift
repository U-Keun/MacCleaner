import Foundation

public struct PathScan: Encodable, Sendable {
    public let displayPath: String
    public let expandedPath: String
    public let exists: Bool
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let errors: [String]

    public init(
        displayPath: String,
        expandedPath: String,
        exists: Bool,
        sizeInBytes: Int64,
        fileCount: Int,
        errors: [String]
    ) {
        self.displayPath = displayPath
        self.expandedPath = expandedPath
        self.exists = exists
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.errors = errors
    }
}

public struct CategoryScan: Encodable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let paths: [PathScan]

    public init(
        id: String,
        name: String,
        description: String,
        sizeInBytes: Int64,
        fileCount: Int,
        paths: [PathScan]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.paths = paths
    }
}

public struct ScanReport: Encodable, Sendable {
    public let generatedAt: String
    public let totalSizeInBytes: Int64
    public let categories: [CategoryScan]

    public init(generatedAt: String, totalSizeInBytes: Int64, categories: [CategoryScan]) {
        self.generatedAt = generatedAt
        self.totalSizeInBytes = totalSizeInBytes
        self.categories = categories
    }
}

public struct Measurement: Sendable {
    public let sizeInBytes: Int64
    public let fileCount: Int

    public init(sizeInBytes: Int64, fileCount: Int) {
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
    }

    public static let zero = Measurement(sizeInBytes: 0, fileCount: 0)
}

public final class FileScanner {
    private let fileManager: FileManager
    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(categories: [CleanupCategory]) -> ScanReport {
        let categoryScans = categories.map(scan(category:))
        let totalSize = categoryScans.reduce(into: Int64(0)) { partialResult, scan in
            partialResult += scan.sizeInBytes
        }

        return ScanReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            totalSizeInBytes: totalSize,
            categories: categoryScans
        )
    }

    public func scan(category: CleanupCategory) -> CategoryScan {
        let pathScans = category.paths.map(scan(path:))
        let totalSize = pathScans.reduce(into: Int64(0)) { partialResult, pathScan in
            partialResult += pathScan.sizeInBytes
        }
        let fileCount = pathScans.reduce(into: 0) { partialResult, pathScan in
            partialResult += pathScan.fileCount
        }

        return CategoryScan(
            id: category.id,
            name: category.name,
            description: category.description,
            sizeInBytes: totalSize,
            fileCount: fileCount,
            paths: pathScans
        )
    }

    public func scan(path: CleanupPath) -> PathScan {
        let expandedPath = path.expandedPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return PathScan(
                displayPath: path.displayPath,
                expandedPath: expandedPath,
                exists: false,
                sizeInBytes: 0,
                fileCount: 0,
                errors: []
            )
        }

        do {
            let result: (Measurement, [String])
            switch path.removeStrategy {
            case .contents where isDirectory.boolValue:
                result = try measureContents(of: url)
            case .contents, .item, .scanOnlyContents:
                result = try measureItem(at: url)
            case .simulatorData where isDirectory.boolValue:
                result = try measureSimulatorData(in: url)
            case .simulatorData:
                result = (.zero, [])
            case .desktopDevCaches where isDirectory.boolValue:
                let inventory = DevCacheScanner(fileManager: fileManager).scan(rootPath: path.rawValue)
                result = (
                    Measurement(
                        sizeInBytes: inventory.totalSizeInBytes,
                        fileCount: inventory.entries.count
                    ),
                    inventory.errors
                )
            case .desktopDevCaches:
                result = (.zero, [])
            }

            return PathScan(
                displayPath: path.displayPath,
                expandedPath: expandedPath,
                exists: true,
                sizeInBytes: result.0.sizeInBytes,
                fileCount: result.0.fileCount,
                errors: result.1
            )
        } catch {
            return PathScan(
                displayPath: path.displayPath,
                expandedPath: expandedPath,
                exists: true,
                sizeInBytes: 0,
                fileCount: 0,
                errors: [error.localizedDescription]
            )
        }
    }

    private func measureContents(of directoryURL: URL) throws -> (Measurement, [String]) {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var totalMeasurement = Measurement.zero
        var allErrors: [String] = []

        for child in children {
            let (measurement, errors) = try measureItem(at: child)
            totalMeasurement = Measurement(
                sizeInBytes: totalMeasurement.sizeInBytes + measurement.sizeInBytes,
                fileCount: totalMeasurement.fileCount + measurement.fileCount
            )
            allErrors.append(contentsOf: errors)
        }

        return (totalMeasurement, allErrors)
    }

    private func measureSimulatorData(in devicesDirectoryURL: URL) throws -> (Measurement, [String]) {
        let children = try fileManager.contentsOfDirectory(
            at: devicesDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var totalMeasurement = Measurement.zero
        var allErrors: [String] = []

        for child in children where isSimulatorDeviceDirectory(child) {
            let dataURL = child.appendingPathComponent("data", isDirectory: true)
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: dataURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let (measurement, errors) = try measureItem(at: dataURL)
            totalMeasurement = Measurement(
                sizeInBytes: totalMeasurement.sizeInBytes + measurement.sizeInBytes,
                fileCount: totalMeasurement.fileCount + measurement.fileCount
            )
            allErrors.append(contentsOf: errors)
        }

        return (totalMeasurement, allErrors)
    }

    private func measureItem(at url: URL) throws -> (Measurement, [String]) {
        let values = try url.resourceValues(forKeys: resourceKeys)

        if values.isSymbolicLink == true {
            return (.zero, [])
        }

        if values.isRegularFile == true {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            return (Measurement(sizeInBytes: size, fileCount: 1), [])
        }

        if values.isDirectory == true {
            var errors: [String] = []
            var totalSize: Int64 = 0
            var fileCount = 0

            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [],
                errorHandler: { failedURL, error in
                    errors.append("\(failedURL.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                return (.zero, [])
            }

            for case let childURL as URL in enumerator {
                let childValues = try? childURL.resourceValues(forKeys: resourceKeys)

                if childValues?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }

                if childValues?.isRegularFile == true {
                    let size = Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? childValues?.fileSize ?? 0)
                    totalSize += size
                    fileCount += 1
                }
            }

            return (Measurement(sizeInBytes: totalSize, fileCount: fileCount), errors)
        }

        return (.zero, [])
    }

    private func isSimulatorDeviceDirectory(_ url: URL) -> Bool {
        guard UUID(uuidString: url.lastPathComponent) != nil else {
            return false
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
}
