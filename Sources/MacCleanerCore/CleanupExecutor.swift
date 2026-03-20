import Foundation

public struct CategoryCleanupResult: Sendable {
    public let id: String
    public let removedItems: Int
    public let errors: [String]

    public init(id: String, removedItems: Int, errors: [String]) {
        self.id = id
        self.removedItems = removedItems
        self.errors = errors
    }
}

struct CommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

typealias CommandRunner = @Sendable (URL, [String]) throws -> CommandResult

public final class CleanupExecutor {
    private let fileManager: FileManager
    private let commandRunner: CommandRunner

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.commandRunner = Self.runCommand(executableURL:arguments:)
    }

    init(fileManager: FileManager = .default, commandRunner: @escaping CommandRunner) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    public func clean(category: CleanupCategory) -> CategoryCleanupResult {
        var removedItems = 0
        var errors: [String] = []

        for path in category.paths {
            let expandedPath = path.expandedPath
            let url = URL(fileURLWithPath: expandedPath)

            guard fileManager.fileExists(atPath: expandedPath) else {
                continue
            }

            switch path.removeStrategy {
            case .contents:
                do {
                    let children = try fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: []
                    )

                    for child in children {
                        do {
                            try fileManager.removeItem(at: child)
                            removedItems += 1
                        } catch {
                            errors.append("\(child.path): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    errors.append("\(url.path): \(error.localizedDescription)")
                }
            case .simulatorData:
                let result = cleanSimulatorData(at: url)
                removedItems += result.removedItems
                errors.append(contentsOf: result.errors)
            case .desktopDevCaches:
                let inventory = DevCacheScanner(fileManager: fileManager).scan(rootPath: path.rawValue)
                let result = DevCacheCleaner(fileManager: fileManager).clean(entries: inventory.entries)
                removedItems += result.removedItems
                errors.append(contentsOf: inventory.errors)
                errors.append(contentsOf: result.errors)
            case .scanOnlyContents:
                if category.cleanupAvailability == .itemized {
                    errors.append("\(url.path): itemized cleanup only. Select individual backups in the app.")
                } else {
                    errors.append("\(url.path): scan-only category. Review and delete individual backups manually.")
                }
            case .item:
                do {
                    try fileManager.removeItem(at: url)
                    removedItems += 1
                } catch {
                    errors.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }

        return CategoryCleanupResult(id: category.id, removedItems: removedItems, errors: errors)
    }

    private func cleanSimulatorData(at devicesDirectoryURL: URL) -> CategoryCleanupResult {
        var removedItems = 0
        var errors: [String] = []

        do {
            let children = try fileManager.contentsOfDirectory(
                at: devicesDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            let deviceIdentifiers = children
                .filter(isSimulatorDeviceDirectory(_:))
                .map(\.lastPathComponent)

            guard !deviceIdentifiers.isEmpty else {
                return CategoryCleanupResult(id: devicesDirectoryURL.lastPathComponent, removedItems: 0, errors: [])
            }

            let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            let shutdownResult = try commandRunner(xcrunURL, ["simctl", "shutdown", "all"])
            if shutdownResult.terminationStatus != 0 {
                errors.append(commandFailureMessage(for: "simctl shutdown all", result: shutdownResult))
            }

            for deviceIdentifier in deviceIdentifiers {
                let eraseResult = try commandRunner(xcrunURL, ["simctl", "erase", deviceIdentifier])
                if eraseResult.terminationStatus == 0 {
                    removedItems += 1
                } else {
                    errors.append(commandFailureMessage(for: "simctl erase \(deviceIdentifier)", result: eraseResult))
                }
            }
        } catch {
            errors.append("\(devicesDirectoryURL.path): \(error.localizedDescription)")
        }

        return CategoryCleanupResult(id: devicesDirectoryURL.lastPathComponent, removedItems: removedItems, errors: errors)
    }

    private func isSimulatorDeviceDirectory(_ url: URL) -> Bool {
        guard UUID(uuidString: url.lastPathComponent) != nil else {
            return false
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func commandFailureMessage(for commandDescription: String, result: CommandResult) -> String {
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty {
            return "\(commandDescription): exited with status \(result.terminationStatus)"
        }

        return "\(commandDescription): \(stderr)"
    }

    private static func runCommand(executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        process.waitUntilExit()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: standardOutputData, as: UTF8.self),
            standardError: String(decoding: standardErrorData, as: UTF8.self)
        )
    }
}
