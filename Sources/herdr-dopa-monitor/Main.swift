import Foundation

@main
enum HerdrDopaMain {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        exit(GuardCLI.main(argv))
    }
}
