import Foundation
import Testing
@testable import MacCleaner
@testable import MacCleanerCore

private final class CommandCapture: @unchecked Sendable {
    var commands: [[String]] = []
}

@Test
func resolveAllCategories() throws {
    let categories = try CleanupCatalog.resolve(["all"])
    #expect(categories.count == CleanupCatalog.categories.count)
}

@Test
func resolveSimulatorAlias() throws {
    let categories = try CleanupCatalog.resolve(["simulator"])
    #expect(categories.count == 1)
    #expect(categories[0].id == "simulator-devices")
}

@Test
func resolveProtectedAliases() throws {
    let categories = try CleanupCatalog.resolve(["mail", "backup"])
    #expect(categories.count == 2)
    #expect(categories[0].id == "mail-downloads")
    #expect(categories[1].id == "mobile-backups")
    #expect(categories[1].cleanupAvailability == .itemized)
}

@Test
func resolveTauriAlias() throws {
    let categories = try CleanupCatalog.resolve(["tauri-target"])
    #expect(categories.count == 1)
    #expect(categories[0].id == "desktop-dev-caches")
}

@Test
func devCacheScannerFindsOnlyStaleCandidatesOutsideNodeModules() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let oldTarget = root.appendingPathComponent("app/src-tauri/target", isDirectory: true)
    let oldNodeCache = root.appendingPathComponent("web/node_modules/.cache", isDirectory: true)
    let freshBuild = root.appendingPathComponent("fresh-app/build", isDirectory: true)
    let ignoredNodeDist = root.appendingPathComponent("web/node_modules/pkg/dist", isDirectory: true)

    try fileManager.createDirectory(at: oldTarget, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: oldNodeCache, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: freshBuild, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: ignoredNodeDist, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let oldDate = Date(timeIntervalSinceNow: -(60 * 60 * 24 * 45))
    let newDate = Date()
    let oldTargetPath = oldTarget.resolvingSymlinksInPath().path
    let oldNodeCachePath = oldNodeCache.resolvingSymlinksInPath().path
    let freshBuildPath = freshBuild.resolvingSymlinksInPath().path
    let ignoredNodeDistPath = ignoredNodeDist.resolvingSymlinksInPath().path

    let oldTargetFile = oldTarget.appendingPathComponent("artifact.bin")
    try Data(repeating: 1, count: 2048).write(to: oldTargetFile)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldTarget.path)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldTargetFile.path)

    let oldNodeCacheFile = oldNodeCache.appendingPathComponent("cache.bin")
    try Data(repeating: 2, count: 1024).write(to: oldNodeCacheFile)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldNodeCache.path)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldNodeCacheFile.path)

    let freshBuildFile = freshBuild.appendingPathComponent("bundle.js")
    try Data(repeating: 3, count: 1024).write(to: freshBuildFile)
    try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: freshBuild.path)
    try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: freshBuildFile.path)

    let ignoredNodeDistFile = ignoredNodeDist.appendingPathComponent("index.js")
    try Data(repeating: 4, count: 1024).write(to: ignoredNodeDistFile)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: ignoredNodeDist.path)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: ignoredNodeDistFile.path)

    let inventory = DevCacheScanner(fileManager: fileManager).scan(rootPath: root.path, staleAfterDays: 30)

    #expect(inventory.exists)
    #expect(inventory.entries.count == 2)
    #expect(inventory.entries.contains(where: { $0.path == oldTargetPath }))
    #expect(inventory.entries.contains(where: { $0.path == oldNodeCachePath }))
    #expect(!inventory.entries.contains(where: { $0.path == freshBuildPath }))
    #expect(!inventory.entries.contains(where: { $0.path == ignoredNodeDistPath }))
}

@Test
func devCacheCleanerDeletesSelectedDirectories() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let one = root.appendingPathComponent("one/target", isDirectory: true)
    let two = root.appendingPathComponent("two/build", isDirectory: true)
    try fileManager.createDirectory(at: one, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: two, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let entries = [
        DevCacheEntry(
            id: one.path,
            kind: "target",
            path: one.path,
            sizeInBytes: 1,
            fileCount: 1,
            newestModificationDate: nil,
            errors: []
        ),
        DevCacheEntry(
            id: two.path,
            kind: "build",
            path: two.path,
            sizeInBytes: 1,
            fileCount: 1,
            newestModificationDate: nil,
            errors: []
        ),
    ]

    let result = DevCacheCleaner(fileManager: fileManager).clean(entries: [entries[0]])

    #expect(result.removedItems == 1)
    #expect(!fileManager.fileExists(atPath: one.path))
    #expect(fileManager.fileExists(atPath: two.path))
}

@Test
func parseCleanCommandWithForce() throws {
    let command = try CommandParser.parse(arguments: ["clean", "trash", "--force"])
    #expect(command.command == .clean)
    #expect(command.categoryTokens == ["trash"])
    #expect(command.force)
    #expect(!command.json)
}

@Test
func scannerMeasuresTemporaryDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let fileURL = root.appendingPathComponent("sample.bin")
    let data = Data(repeating: 7, count: 4096)
    try data.write(to: fileURL)

    let category = CleanupCategory(
        id: "fixture",
        name: "Fixture",
        description: "Fixture data",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .contents)]
    )

    let scan = FileScanner(fileManager: fileManager).scan(category: category)
    #expect(scan.sizeInBytes >= 4096)
    #expect(scan.fileCount == 1)
}

@Test
func cleanupRemovesDirectoryContentsButKeepsRoot() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    try Data(repeating: 1, count: 1024).write(to: root.appendingPathComponent("one.cache"))
    let nested = root.appendingPathComponent("nested")
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 1024).write(to: nested.appendingPathComponent("two.cache"))

    let category = CleanupCategory(
        id: "fixture",
        name: "Fixture",
        description: "Fixture data",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .contents)]
    )

    let result = CleanupExecutor(fileManager: fileManager).clean(category: category)
    let remaining = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

    #expect(result.removedItems == 2)
    #expect(remaining.isEmpty)
    #expect(fileManager.fileExists(atPath: root.path))
}

@Test
func scannerMeasuresSimulatorDeviceDataOnly() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let deviceRoot = root.appendingPathComponent(UUID().uuidString)
    let dataRoot = deviceRoot.appendingPathComponent("data/Documents", isDirectory: true)
    try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    try Data(repeating: 3, count: 4096).write(to: dataRoot.appendingPathComponent("persisted.db"))
    try Data(repeating: 4, count: 4096).write(to: deviceRoot.appendingPathComponent("metadata.bin"))

    let category = CleanupCategory(
        id: "simulator-devices",
        name: "Simulator Devices",
        description: "Simulator data",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .simulatorData)]
    )

    let scan = FileScanner(fileManager: fileManager).scan(category: category)
    #expect(scan.fileCount == 1)
    #expect(scan.sizeInBytes >= 4096)
    #expect(scan.sizeInBytes < 8192 * 2)
}

@Test
func scannerMeasuresScanOnlyContents() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    try Data(repeating: 9, count: 2048).write(to: root.appendingPathComponent("backup.dat"))

    let category = CleanupCategory(
        id: "mobile-backups",
        name: "Device Backups",
        description: "Backups",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .scanOnlyContents)],
        requiresFullDiskAccess: true,
        cleanupAvailability: .scanOnly
    )

    let scan = FileScanner(fileManager: fileManager).scan(category: category)
    #expect(scan.sizeInBytes >= 2048)
    #expect(scan.fileCount == 1)
}

@Test
func deviceBackupScannerEnumeratesBackupEntries() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup = root.appendingPathComponent("backup-one")
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let infoPlist: [String: Any] = [
        "Device Name": "Keunsong's iPhone",
        "Product Name": "iPhone 16 Pro",
        "Product Version": "18.2",
    ]
    let statusPlist: [String: Any] = [
        "Date": Date(timeIntervalSince1970: 1_700_000_000),
    ]
    let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
    let statusData = try PropertyListSerialization.data(fromPropertyList: statusPlist, format: .xml, options: 0)
    try infoData.write(to: backup.appendingPathComponent("Info.plist"))
    try statusData.write(to: backup.appendingPathComponent("Status.plist"))
    try Data(repeating: 7, count: 4096).write(to: backup.appendingPathComponent("Manifest.db"))

    let inventory = DeviceBackupScanner(fileManager: fileManager).scan(rootPath: root.path)

    #expect(inventory.exists)
    #expect(inventory.entries.count == 1)
    #expect(inventory.entries[0].displayName == "Keunsong's iPhone")
    #expect(inventory.entries[0].productName == "iPhone 16 Pro")
    #expect(inventory.entries[0].productVersion == "18.2")
    #expect(inventory.entries[0].lastBackupDate != nil)
    #expect(inventory.entries[0].sizeInBytes >= 4096)
}

@Test
func cleanupErasesSimulatorDevicesUsingSimctl() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let firstDevice = root.appendingPathComponent(UUID().uuidString)
    let secondDevice = root.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: firstDevice.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secondDevice.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let commandCapture = CommandCapture()
    let executor = CleanupExecutor(fileManager: fileManager) { executableURL, arguments in
        #expect(executableURL.path == "/usr/bin/xcrun")
        commandCapture.commands.append(arguments)

        if arguments.count >= 3, arguments[0] == "simctl", arguments[1] == "erase" {
            let deviceURL = root.appendingPathComponent(arguments[2]).appendingPathComponent("data", isDirectory: true)
            try? FileManager.default.removeItem(at: deviceURL)
        }

        return CommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
    }

    let category = CleanupCategory(
        id: "simulator-devices",
        name: "Simulator Devices",
        description: "Simulator data",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .simulatorData)]
    )

    let result = executor.clean(category: category)

    #expect(result.removedItems == 2)
    #expect(commandCapture.commands.contains(["simctl", "shutdown", "all"]))
    #expect(commandCapture.commands.contains(["simctl", "erase", firstDevice.lastPathComponent]))
    #expect(commandCapture.commands.contains(["simctl", "erase", secondDevice.lastPathComponent]))
    #expect(!fileManager.fileExists(atPath: firstDevice.appendingPathComponent("data").path))
    #expect(!fileManager.fileExists(atPath: secondDevice.appendingPathComponent("data").path))
}

@Test
func cleanupSkipsScanOnlyCategory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let category = CleanupCategory(
        id: "mobile-backups",
        name: "Device Backups",
        description: "Backups",
        paths: [CleanupPath(rawValue: root.path, removeStrategy: .scanOnlyContents)],
        requiresFullDiskAccess: true,
        cleanupAvailability: .scanOnly
    )

    let result = CleanupExecutor(fileManager: fileManager).clean(category: category)
    #expect(result.removedItems == 0)
    #expect(result.errors.count == 1)
}

@Test
func deviceBackupCleanerDeletesSelectedEntries() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backupOne = root.appendingPathComponent("backup-one")
    let backupTwo = root.appendingPathComponent("backup-two")
    try fileManager.createDirectory(at: backupOne, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: backupTwo, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let entries = [
        DeviceBackupEntry(
            id: "backup-one",
            displayName: "Backup One",
            productName: nil,
            productVersion: nil,
            lastBackupDate: nil,
            path: backupOne.path,
            sizeInBytes: 10,
            fileCount: 1,
            errors: []
        ),
        DeviceBackupEntry(
            id: "backup-two",
            displayName: "Backup Two",
            productName: nil,
            productVersion: nil,
            lastBackupDate: nil,
            path: backupTwo.path,
            sizeInBytes: 10,
            fileCount: 1,
            errors: []
        ),
    ]

    let result = DeviceBackupCleaner(fileManager: fileManager).clean(entries: [entries[0]])

    #expect(result.removedItems == 1)
    #expect(fileManager.fileExists(atPath: backupTwo.path))
    #expect(!fileManager.fileExists(atPath: backupOne.path))
}
