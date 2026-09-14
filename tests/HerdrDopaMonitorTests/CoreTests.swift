import XCTest
@testable import HerdrDopaMonitor

final class CoreTests: XCTestCase {
    func testSemanticVersionRequiresThreeNumericComponents() {
        XCTAssertEqual(SemanticVersion("0.3.3"), SemanticVersion(0, 3, 3))
        XCTAssertGreaterThan(SemanticVersion("0.10.0")!, SemanticVersion("0.3.3")!)
        XCTAssertNil(SemanticVersion("0.3.3-beta"))
        XCTAssertNil(SemanticVersion("0.3"))
    }

    func testDopaAPIVersionAcceptsIntegralNSNumberOnlyByValue() {
        XCTAssertTrue(DopaClient.numberIsOne(NSNumber(value: 1)))
        XCTAssertTrue(DopaClient.numberIsOne(NSNumber(value: 1.0)))
        XCTAssertFalse(DopaClient.numberIsOne(NSNumber(value: 2)))
        XCTAssertFalse(DopaClient.numberIsOne(NSNumber(value: true)))
    }

    func testLegacyConfigMigrationReader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(
            configDirectory: root.appendingPathComponent("config").path,
            stateDirectory: root.appendingPathComponent("state").path,
            pluginRegistry: root.appendingPathComponent("plugins.json").path
        )
        try Store.ensureDirectory(paths.configDirectory)
        try "KEEP_DISPLAY_ON='true'\nSTOP_ON_LID_CLOSE='false'\nDOPA_SOCK='/tmp/dopa.sock'\n"
            .write(toFile: paths.legacyConfigFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            Store.loadConfig(paths: paths, environment: [:]),
            GuardConfig(keepDisplayOn: true, stopOnLidClose: false, dopaSocket: "/tmp/dopa.sock")
        )
    }
}
