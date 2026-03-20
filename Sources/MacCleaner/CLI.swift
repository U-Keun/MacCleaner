import Foundation
import MacCleanerCore

struct CLIEnvironment {
    let fileManager: FileManager
    let output: (String) -> Void
    let errorOutput: (String) -> Void
    let promptInput: () -> String?

    static var live: CLIEnvironment {
        CLIEnvironment(
            fileManager: .default,
            output: { message in
                Swift.print(message)
            },
            errorOutput: { message in
                guard let data = (message + "\n").data(using: .utf8) else {
                    return
                }

                FileHandle.standardError.write(data)
            },
            promptInput: {
                readLine(strippingNewline: true)
            }
        )
    }
}

enum CLICommand: String {
    case scan
    case clean
    case list
    case help
}

struct ParsedCommand {
    let command: CLICommand
    let categoryTokens: [String]
    let force: Bool
    let json: Bool
}

enum CLIError: Error {
    case unknownOption(String)
    case unknownCategory(String)
    case invalidCombination(String)

    var message: String {
        switch self {
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .unknownCategory(let category):
            return "Unknown category: \(category). Run `MacCleaner list` to see the supported categories."
        case .invalidCombination(let description):
            return description
        }
    }

    var exitCode: Int32 {
        64
    }
}

enum CommandParser {
    static func parse(arguments: [String]) throws -> ParsedCommand {
        var index = 0
        var command: CLICommand = .scan

        if let first = arguments.first,
           !first.hasPrefix("-"),
           let parsedCommand = CLICommand(rawValue: first.lowercased()) {
            command = parsedCommand
            index = 1
        }

        var categoryTokens: [String] = []
        var force = false
        var json = false

        for token in arguments.dropFirst(index) {
            switch token {
            case "--force", "-y":
                force = true
            case "--json":
                json = true
            case "--help", "-h":
                return ParsedCommand(command: .help, categoryTokens: [], force: false, json: false)
            default:
                if token.hasPrefix("-") {
                    throw CLIError.unknownOption(token)
                }

                categoryTokens.append(token)
            }
        }

        if command == .clean && json {
            throw CLIError.invalidCombination("`--json` is only supported with the `scan` command.")
        }

        return ParsedCommand(
            command: command,
            categoryTokens: categoryTokens,
            force: force,
            json: json
        )
    }
}

struct MacCleanerCLI {
    let environment: CLIEnvironment

    func run(arguments: [String]) throws {
        let parsedCommand = try CommandParser.parse(arguments: arguments)

        switch parsedCommand.command {
        case .help:
            environment.output(Self.helpText)
        case .list:
            environment.output(renderCategoryList())
        case .scan:
            let categories = try resolveCategories(parsedCommand.categoryTokens)
            let report = FileScanner(fileManager: environment.fileManager).scan(categories: categories)

            if parsedCommand.json {
                environment.output(try OutputFormatter.makeJSON(report))
            } else {
                environment.output(renderScanReport(report))
            }
        case .clean:
            let categories = try resolveCategories(parsedCommand.categoryTokens)
            let scanner = FileScanner(fileManager: environment.fileManager)
            let report = scanner.scan(categories: categories)
            let estimatedBytes = report.totalSizeInBytes

            environment.output(renderCleanupPreview(report))

            if estimatedBytes == 0 && warningLines(from: report.categories).isEmpty {
                environment.output("Nothing to clean in the selected categories.")
                return
            }

            if !parsedCommand.force && !confirmCleanup() {
                environment.output("Cleanup cancelled.")
                return
            }

            let executor = CleanupExecutor(fileManager: environment.fileManager)
            let results = categories.map(executor.clean(category:))
            environment.output(renderCleanupResults(results: results, estimatedBytes: estimatedBytes))
        }
    }

    private func resolveCategories(_ tokens: [String]) throws -> [CleanupCategory] {
        do {
            return try CleanupCatalog.resolve(tokens)
        } catch let error as CleanupCatalogError {
            switch error {
            case .unknownCategory(let token):
                throw CLIError.unknownCategory(token)
            }
        }
    }

    private func confirmCleanup() -> Bool {
        environment.output("Proceed with cleanup? [y/N]")
        guard let answer = environment.promptInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return answer == "y" || answer == "yes"
    }

    private func renderCategoryList() -> String {
        let categories = CleanupCatalog.categories
        let width = max(categories.map(\.id.count).max() ?? 0, 3)

        var lines = [
            "Available categories",
            "--------------------",
            "all".padding(toLength: width, withPad: " ", startingAt: 0) + "  Every supported cleanup target",
        ]

        for category in categories {
            let paths = category.paths.map(\.displayPath).joined(separator: ", ")
            let label = category.id.padding(toLength: width, withPad: " ", startingAt: 0)
            var notes: [String] = []
            if category.requiresFullDiskAccess {
                notes.append("Full Disk Access")
            }
            if category.cleanupAvailability == .scanOnly {
                notes.append("scan only")
            } else if category.cleanupAvailability == .itemized {
                notes.append("itemized cleanup")
            }
            let suffix = notes.isEmpty ? "" : " {" + notes.joined(separator: ", ") + "}"
            lines.append("\(label)  \(category.description) [\(paths)]\(suffix)")
        }

        return lines.joined(separator: "\n")
    }

    private func renderScanReport(_ report: ScanReport) -> String {
        let width = max(report.categories.map(\.id.count).max() ?? 0, 3)
        var lines = [
            "MacCleaner scan summary",
            "-----------------------",
        ]

        for category in report.categories {
            let label = category.id.padding(toLength: width, withPad: " ", startingAt: 0)
            let size = OutputFormatter.sizeString(for: category.sizeInBytes)
            let pathSummary = category.paths.map(\.displayPath).joined(separator: ", ")
            let suffix = category.paths.allSatisfy(\.exists) ? "" : " (not found)"
            lines.append("\(label)  \(size)  \(pathSummary)\(suffix)")
        }

        lines.append("")
        lines.append("Estimated reclaimable space: \(OutputFormatter.sizeString(for: report.totalSizeInBytes))")

        let warnings = warningLines(from: report.categories)
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            lines.append("--------")
            lines.append(contentsOf: warnings.map { "- \($0)" })
        }

        lines.append("")
        lines.append("Run `MacCleaner clean all` to delete all supported categories.")

        return lines.joined(separator: "\n")
    }

    private func renderCleanupPreview(_ report: ScanReport) -> String {
        let width = max(report.categories.map(\.id.count).max() ?? 0, 3)
        var lines = [
            "Cleanup preview",
            "---------------",
        ]

        for category in report.categories {
            let label = category.id.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("\(label)  \(OutputFormatter.sizeString(for: category.sizeInBytes))")
        }

        lines.append("")
        lines.append("Estimated reclaimable space: \(OutputFormatter.sizeString(for: report.totalSizeInBytes))")

        let warnings = warningLines(from: report.categories)
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            lines.append("--------")
            lines.append(contentsOf: warnings.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private func renderCleanupResults(results: [CategoryCleanupResult], estimatedBytes: Int64) -> String {
        let width = max(results.map(\.id.count).max() ?? 0, 3)
        var lines = [
            "Cleanup completed",
            "-----------------",
        ]

        for result in results {
            let label = result.id.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("\(label)  cleaned \(result.removedItems) top-level item(s)")
        }

        lines.append("")
        lines.append("Estimated reclaimed space: \(OutputFormatter.sizeString(for: estimatedBytes))")

        let warnings = results.flatMap { result in
            result.errors.map { "[\(result.id)] \($0)" }
        }

        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            lines.append("--------")
            lines.append(contentsOf: warnings.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private func warningLines(from categories: [CategoryScan]) -> [String] {
        categories.flatMap { category in
            category.paths.flatMap { path in
                path.errors.map { "[\(category.id)] \($0)" }
            }
        }
    }

    static var helpText: String {
        """
        MacCleaner
        Safe cleanup for reclaimable macOS user cache and developer data.

        Usage:
          MacCleaner [scan] [category ...] [--json]
          MacCleaner clean [category ...] [--force]
          MacCleaner list
          MacCleaner help

        Commands:
          scan   Measure reclaimable data. This is the default command.
          clean  Remove files from the selected categories.
          list   Show the available cleanup categories.
          help   Show this message.

        Options:
          --json   Emit scan output as JSON.
          --force  Skip the cleanup confirmation prompt.
          -y       Alias for --force.

        Examples:
          MacCleaner
          MacCleaner scan caches logs
          MacCleaner scan mobile-backups
          MacCleaner clean all
          MacCleaner clean simulator-devices xcode-derived-data --force
        """
    }
}
