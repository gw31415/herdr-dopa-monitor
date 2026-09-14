import Darwin
import Foundation

@main
enum HerdrDopaMonitorMain {
    static func main() {
        exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
    }
}
