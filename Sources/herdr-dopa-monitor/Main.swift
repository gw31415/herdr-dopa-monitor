import Foundation

@main
enum HerdrDopaMonitorMain {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        exit(GuardCLI.main(argv))
    }
}
