import Darwin
import Foundation
import MacCleanerCore

@main
struct MacCleaner {
    static func main() {
        let cli = MacCleanerCLI(environment: .live)

        do {
            try cli.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            CLIEnvironment.live.errorOutput("Error: \(error.message)")
            exit(error.exitCode)
        } catch {
            CLIEnvironment.live.errorOutput("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
