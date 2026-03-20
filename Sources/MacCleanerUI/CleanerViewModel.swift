import Combine
import Foundation
import MacCleanerCore

struct CategoryRow: Identifiable {
    let category: CleanupCategory
    var isSelected: Bool
    var sizeInBytes: Int64
    var fileCount: Int
    var pathScans: [PathScan]
    var warningCount: Int
    var itemCountOverride: String?

    var id: String { category.id }
    var name: String { category.name }
    var description: String { category.description }
    var pathSummary: String { category.paths.map(\.displayPath).joined(separator: ", ") }
    var isTopLevelCleanable: Bool { category.cleanupAvailability == .cleanable }
    var supportsItemizedCleanup: Bool { category.cleanupAvailability == .itemized }
    var requiresFullDiskAccess: Bool { category.requiresFullDiskAccess }

    var noteText: String? {
        var notes: [String] = []
        if requiresFullDiskAccess {
            notes.append("Full Disk Access")
        }
        switch category.cleanupAvailability {
        case .itemized:
            notes.append("Select items below")
        case .scanOnly:
            notes.append("Scan only")
        case .cleanable:
            break
        }
        return notes.isEmpty ? nil : notes.joined(separator: " • ")
    }

    var statusText: String {
        if let itemCountOverride {
            return itemCountOverride
        }

        if warningCount > 0 {
            return "\(warningCount) warning(s)"
        }

        if pathScans.isEmpty {
            return "Not scanned"
        }

        if pathScans.allSatisfy({ !$0.exists }) {
            return "Not found"
        }

        if fileCount == 0 {
            return "Empty"
        }

        return "\(fileCount) file(s)"
    }
}

struct DeviceBackupRow: Identifiable {
    let entry: DeviceBackupEntry
    var isSelected: Bool

    var id: String { entry.id }
    var title: String { entry.displayName }

    var metadataText: String {
        var parts: [String] = []

        if let productName = entry.productName {
            if let productVersion = entry.productVersion {
                parts.append("\(productName) \(productVersion)")
            } else {
                parts.append(productName)
            }
        }

        if let lastBackupDate = entry.lastBackupDate {
            parts.append(lastBackupDate.formatted(date: .abbreviated, time: .shortened))
        }

        return parts.isEmpty ? entry.id : parts.joined(separator: " • ")
    }
}

struct DevCacheRow: Identifiable {
    let entry: DevCacheEntry

    var id: String { entry.id }
    var title: String { entry.kind }

    var subtitle: String {
        var parts: [String] = []

        if let newestModificationDate = entry.newestModificationDate {
            parts.append("Last touched \(newestModificationDate.formatted(date: .abbreviated, time: .shortened))")
        }

        parts.append("\(entry.fileCount) file(s)")
        return parts.joined(separator: " • ")
    }
}

@MainActor
final class CleanerViewModel: ObservableObject {
    @Published var rows: [CategoryRow]
    @Published var deviceBackupRows: [DeviceBackupRow] = []
    @Published var deviceBackupErrors: [String] = []
    @Published var deviceBackupRootExists = false
    @Published var devCacheRows: [DevCacheRow] = []
    @Published var devCacheErrors: [String] = []
    @Published var devCacheRootExists = false
    @Published var isRunning = false
    @Published var statusMessage = "Ready to scan."
    @Published var lastScanLabel = "Not scanned yet"

    private var hasPerformedInitialScan = false

    init(categories: [CleanupCategory] = CleanupCatalog.categories) {
        self.rows = categories.map {
            CategoryRow(
                category: $0,
                isSelected: true,
                sizeInBytes: 0,
                fileCount: 0,
                pathScans: [],
                warningCount: 0,
                itemCountOverride: nil
            )
        }
    }

    var selectedCategoryCount: Int {
        rows.filter(\.isSelected).count
    }

    var totalReclaimableBytes: Int64 {
        rows.reduce(into: Int64(0)) { partialResult, row in
            partialResult += row.sizeInBytes
        }
    }

    var selectedCleanableCategoryCount: Int {
        rows.filter { $0.isSelected && $0.isTopLevelCleanable }.count
    }

    var selectedCleanableCategoryBytes: Int64 {
        rows.filter { $0.isSelected && $0.isTopLevelCleanable }.reduce(into: Int64(0)) { partialResult, row in
            partialResult += row.sizeInBytes
        }
    }

    var selectedDeviceBackupCount: Int {
        deviceBackupRows.filter(\.isSelected).count
    }

    var selectedDeviceBackupBytes: Int64 {
        deviceBackupRows.filter(\.isSelected).reduce(into: Int64(0)) { partialResult, row in
            partialResult += row.entry.sizeInBytes
        }
    }

    var hasSelectedSimulatorDevices: Bool {
        rows.contains { $0.isSelected && $0.id == "simulator-devices" }
    }

    var hasSelectedScanOnlyCategories: Bool {
        rows.contains { $0.isSelected && $0.category.cleanupAvailability == .scanOnly }
    }

    var hasSelectedFullDiskAccessTargets: Bool {
        if selectedDeviceBackupCount > 0 {
            return true
        }

        return rows.contains { $0.isSelected && $0.requiresFullDiskAccess }
    }

    var selectedCleanableBytes: Int64 {
        selectedCleanableCategoryBytes + selectedDeviceBackupBytes
    }

    var canCleanSelection: Bool {
        selectedCleanableCategoryCount > 0 || selectedDeviceBackupCount > 0
    }

    var shouldShowDeviceBackupSection: Bool {
        rows.contains { $0.id == "mobile-backups" && ($0.isSelected || $0.warningCount > 0 || $0.sizeInBytes > 0) } ||
        !deviceBackupRows.isEmpty ||
        !deviceBackupErrors.isEmpty
    }

    var shouldShowDevCacheSection: Bool {
        rows.contains { $0.id == "desktop-dev-caches" && ($0.isSelected || $0.warningCount > 0 || $0.sizeInBytes > 0) } ||
        !devCacheRows.isEmpty ||
        !devCacheErrors.isEmpty
    }

    var deviceBackupHelperText: String {
        if !deviceBackupErrors.isEmpty {
            return "Grant Full Disk Access to inspect Finder backups and remove them individually."
        }

        if !deviceBackupRows.isEmpty {
            return "Check specific Finder backups below. Only the checked backups will be deleted."
        }

        if deviceBackupRootExists {
            return "No local Finder backups were found."
        }

        return "No Finder backup folder was found on this Mac."
    }

    var devCacheHelperText: String {
        if !devCacheErrors.isEmpty {
            return "Some desktop folders could not be scanned. The cleanup still targets stale dev caches only."
        }

        if !devCacheRows.isEmpty {
            return "These Desktop build caches look stale and will be removed when the category is cleaned."
        }

        if devCacheRootExists {
            return "No stale dev caches matched the 30-day rule under Desktop."
        }

        return "Desktop was not found."
    }

    var cleanupConfirmationMessage: String {
        var parts: [String] = []

        if selectedDeviceBackupCount > 0 {
            parts.append("\(selectedDeviceBackupCount) selected Finder backup(s) will be permanently deleted.")
        }

        if hasSelectedSimulatorDevices {
            parts.append("Simulator Devices resets installed apps, files, and media inside the selected simulators.")
        }

        if rows.contains(where: { $0.isSelected && $0.id == "desktop-dev-caches" }) {
            parts.append("Old Dev Caches removes stale build artifacts under Desktop that match the 30-day rule.")
        }

        if hasSelectedScanOnlyCategories {
            parts.append("Scan-only categories are excluded from cleanup and stay available only for inspection.")
        }

        if hasSelectedFullDiskAccessTargets {
            parts.append("Protected categories may need Full Disk Access in System Settings to scan or clean successfully.")
        }

        if parts.isEmpty {
            parts.append("This removes files inside the selected cache, log, Xcode, simulator, and Trash locations.")
        }

        return parts.joined(separator: " ")
    }

    func performInitialScanIfNeeded() {
        guard !hasPerformedInitialScan else {
            return
        }

        hasPerformedInitialScan = true
        scan()
    }

    func selectAll() {
        for index in rows.indices {
            rows[index].isSelected = true
        }
    }

    func clearSelection() {
        for index in rows.indices {
            rows[index].isSelected = false
        }
        for index in deviceBackupRows.indices {
            deviceBackupRows[index].isSelected = false
        }
    }

    func selectAllDeviceBackups() {
        for index in deviceBackupRows.indices {
            deviceBackupRows[index].isSelected = true
        }
    }

    func clearDeviceBackupSelection() {
        for index in deviceBackupRows.indices {
            deviceBackupRows[index].isSelected = false
        }
    }

    func scan() {
        guard !isRunning else {
            return
        }

        let categories = rows.map(\.category)
        let standardCategories = categories.filter { $0.id != "desktop-dev-caches" }
        isRunning = true
        statusMessage = "Scanning selected locations..."

        Task {
            let reportTask = Task.detached(priority: .userInitiated) {
                FileScanner().scan(categories: standardCategories)
            }
            let deviceBackupTask = Task.detached(priority: .userInitiated) {
                DeviceBackupScanner().scan()
            }
            let devCacheTask = Task.detached(priority: .userInitiated) {
                DevCacheScanner().scan()
            }

            let report = await reportTask.value
            let deviceBackupInventory = await deviceBackupTask.value
            let devCacheInventory = await devCacheTask.value

            apply(report: report)
            apply(deviceBackupInventory: deviceBackupInventory)
            apply(devCacheInventory: devCacheInventory)
            isRunning = false
            let totalSize = report.totalSizeInBytes + devCacheInventory.totalSizeInBytes
            statusMessage = totalSize == 0
                ? "Scan complete. No reclaimable data found."
                : "Scan complete. \(OutputFormatter.sizeString(for: totalSize)) can be reclaimed."
            lastScanLabel = Self.timestampLabel(from: report.generatedAt)
        }
    }

    func cleanSelected() {
        guard !isRunning else {
            return
        }

        let selectedCategories = rows.filter(\.isSelected).map(\.category)
        if selectedCategories.isEmpty && selectedDeviceBackupCount == 0 {
            statusMessage = "Select at least one category or backup first."
            return
        }

        let cleanableCategories = rows
            .filter { $0.isSelected && $0.isTopLevelCleanable }
            .map(\.category)
        let selectedDeviceBackups = deviceBackupRows
            .filter(\.isSelected)
            .map(\.entry)

        guard !cleanableCategories.isEmpty || !selectedDeviceBackups.isEmpty else {
            let onlyItemizedCategoriesSelected = rows.contains { $0.isSelected && $0.supportsItemizedCleanup }
            if onlyItemizedCategoriesSelected {
                statusMessage = "Select individual device backups below to remove them."
            } else {
                statusMessage = "Only scan-only categories are selected. Scan them, then review those files manually."
            }
            return
        }

        let allCategories = rows.map(\.category)
        let standardCategories = allCategories.filter { $0.id != "desktop-dev-caches" }
        let estimatedBytes = selectedCleanableBytes
        isRunning = true
        statusMessage = "Removing selected data..."

        Task {
            let categoryResults = await Task.detached(priority: .userInitiated) {
                let executor = CleanupExecutor()
                return cleanableCategories.map(executor.clean(category:))
            }.value
            let backupResult = await Task.detached(priority: .userInitiated) {
                DeviceBackupCleaner().clean(entries: selectedDeviceBackups)
            }.value

            let reportTask = Task.detached(priority: .userInitiated) {
                FileScanner().scan(categories: standardCategories)
            }
            let deviceBackupTask = Task.detached(priority: .userInitiated) {
                DeviceBackupScanner().scan()
            }
            let devCacheTask = Task.detached(priority: .userInitiated) {
                DevCacheScanner().scan()
            }

            let report = await reportTask.value
            let deviceBackupInventory = await deviceBackupTask.value
            let devCacheInventory = await devCacheTask.value

            apply(report: report)
            apply(deviceBackupInventory: deviceBackupInventory)
            apply(devCacheInventory: devCacheInventory)
            isRunning = false

            let removedItems = categoryResults.reduce(into: 0) { partialResult, result in
                partialResult += result.removedItems
            }
            + backupResult.removedItems

            let warningCount = categoryResults.reduce(into: 0) { partialResult, result in
                partialResult += result.errors.count
            }
            + backupResult.errors.count

            let baseMessage = "Cleanup complete. Cleaned \(removedItems) item(s). Estimated reclaimed space: \(OutputFormatter.sizeString(for: estimatedBytes))."
            let suffix: String
            if warningCount > 0 {
                suffix = " \(warningCount) warning(s) occurred."
            } else if hasSelectedScanOnlyCategories {
                suffix = " Scan-only categories were skipped."
            } else {
                suffix = ""
            }
            statusMessage = baseMessage + suffix
            lastScanLabel = Self.timestampLabel(from: report.generatedAt)
        }
    }

    private func apply(report: ScanReport) {
        let scansByID = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.id, $0) })

        rows = rows.map { row in
            guard let scan = scansByID[row.id] else {
                return row
            }

            var updated = row
            updated.sizeInBytes = scan.sizeInBytes
            updated.fileCount = scan.fileCount
            updated.pathScans = scan.paths
            updated.warningCount = scan.paths.reduce(into: 0) { partialResult, path in
                partialResult += path.errors.count
            }
            if updated.id == "mobile-backups" {
                updated.itemCountOverride = itemCountLabel(for: deviceBackupRows.count, warnings: updated.warningCount)
            } else {
                updated.itemCountOverride = nil
            }
            return updated
        }
    }

    private func apply(deviceBackupInventory: DeviceBackupInventory) {
        let selectionByPath = Dictionary(uniqueKeysWithValues: deviceBackupRows.map { ($0.entry.path, $0.isSelected) })

        deviceBackupRows = deviceBackupInventory.entries.map { entry in
            DeviceBackupRow(
                entry: entry,
                isSelected: selectionByPath[entry.path] ?? false
            )
        }
        deviceBackupErrors = deviceBackupInventory.errors
        deviceBackupRootExists = deviceBackupInventory.exists

        if let index = rows.firstIndex(where: { $0.id == "mobile-backups" }) {
            rows[index].itemCountOverride = itemCountLabel(for: deviceBackupRows.count, warnings: rows[index].warningCount)
        }
    }

    private func apply(devCacheInventory: DevCacheInventory) {
        devCacheRows = devCacheInventory.entries.map(DevCacheRow.init(entry:))
        devCacheErrors = devCacheInventory.errors
        devCacheRootExists = devCacheInventory.exists

        if let index = rows.firstIndex(where: { $0.id == "desktop-dev-caches" }) {
            rows[index].sizeInBytes = devCacheInventory.totalSizeInBytes
            rows[index].fileCount = devCacheInventory.entries.count
            rows[index].warningCount = devCacheInventory.errors.count
            rows[index].pathScans = []
            rows[index].itemCountOverride = "\(devCacheInventory.entries.count) stale cache(s)"
        }
    }

    private func itemCountLabel(for backupCount: Int, warnings: Int) -> String? {
        if warnings > 0 {
            return "\(warnings) warning(s)"
        }

        return "\(backupCount) backup(s)"
    }

    private static func timestampLabel(from generatedAt: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: generatedAt) else {
            return "Last scan updated"
        }

        return "Last scan: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
