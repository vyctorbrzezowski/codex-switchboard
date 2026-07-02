import CodexSwitchboardCore
import Darwin
import Foundation

@main
enum Main {
    static func main() {
        let exitCode = CodexSwitchboardCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(exitCode)
    }
}
