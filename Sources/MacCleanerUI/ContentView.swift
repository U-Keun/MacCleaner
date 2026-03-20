import MacCleanerCore
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CleanerViewModel()
    @State private var showingCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            controls
            categoryList
            if viewModel.shouldShowDeviceBackupSection {
                deviceBackupSection
            }
            if viewModel.shouldShowDevCacheSection {
                devCacheSection
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            viewModel.performInitialScanIfNeeded()
        }
        .confirmationDialog(
            "Clean selected data?",
            isPresented: $showingCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean", role: .destructive) {
                viewModel.cleanSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.cleanupConfirmationMessage)
        }
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.30, blue: 0.52),
                            Color(red: 0.09, green: 0.52, blue: 0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 8) {
                Text("MacCleaner")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Safe cleanup for cache, logs, simulator data, protected Library folders, and project build caches.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(viewModel.lastScanLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(22)
        }
        .frame(height: 138)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Scan Again") {
                viewModel.scan()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Select All") {
                viewModel.selectAll()
            }

            Button("Clear Selection") {
                viewModel.clearSelection()
            }

            Spacer()

            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 2)
            }

            Button("Clean Selected") {
                showingCleanupConfirmation = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canCleanSelection || viewModel.isRunning)
        }
    }

    private var categoryList: some View {
        List {
            ForEach($viewModel.rows) { row in
                CategoryRowView(row: row.wrappedValue, isSelected: row.isSelected)
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
        .listStyle(.inset)
    }

    private var deviceBackupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device Backups")
                            .font(.headline)
                        Text(viewModel.deviceBackupHelperText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !viewModel.deviceBackupRows.isEmpty {
                        HStack(spacing: 8) {
                            Button("Select All Backups") {
                                viewModel.selectAllDeviceBackups()
                            }

                            Button("Clear Backup Selection") {
                                viewModel.clearDeviceBackupSelection()
                            }
                        }
                    }
                }

                if viewModel.deviceBackupRows.isEmpty {
                    Text("No backup entries to show.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach($viewModel.deviceBackupRows) { row in
                                DeviceBackupRowView(row: row.wrappedValue, isSelected: row.isSelected)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Selected categories: \(viewModel.selectedCategoryCount)")
                    .font(.headline)
                Text("Selected backups: \(viewModel.selectedDeviceBackupCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Ready to clean: \(OutputFormatter.sizeString(for: viewModel.selectedCleanableBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Scanned total: \(OutputFormatter.sizeString(for: viewModel.totalReclaimableBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 340, alignment: .trailing)
        }
        .padding(.top, 4)
    }

    private var devCacheSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Old Dev Caches")
                    .font(.headline)
                Text(viewModel.devCacheHelperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.devCacheRows.isEmpty {
                    Text("No stale dev cache entries to show.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.devCacheRows) { row in
                                DevCacheRowView(row: row)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                }
            }
        }
    }
}

private struct CategoryRowView: View {
    let row: CategoryRow
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name)
                        .font(.headline)
                    Spacer()
                    Text(OutputFormatter.sizeString(for: row.sizeInBytes))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Text(row.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let noteText = row.noteText {
                    Text(noteText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                }

                HStack {
                    Text(row.pathSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(row.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.warningCount > 0 ? .orange : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .toggleStyle(.checkbox)
    }
}

private struct DeviceBackupRowView: View {
    let row: DeviceBackupRow
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.headline)
                    Spacer()
                    Text(OutputFormatter.sizeString(for: row.entry.sizeInBytes))
                        .font(.system(.body, design: .monospaced))
                }

                Text(row.metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(row.entry.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .toggleStyle(.checkbox)
    }
}

private struct DevCacheRowView: View {
    let row: DevCacheRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.headline)
                Spacer()
                Text(OutputFormatter.sizeString(for: row.entry.sizeInBytes))
                    .font(.system(.body, design: .monospaced))
            }

            Text(row.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(row.entry.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
